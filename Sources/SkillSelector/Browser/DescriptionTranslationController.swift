import Foundation
import SkillSelectorCore
import SwiftUI

/// Shared per-selection description-translation driver for both detail
/// views (the local `SkillDetailView` and the marketplace
/// `CatalogDetailView`): cache-first toggle, local-store-keyed DeepL
/// request, in-flight commits gated on the owning path. Views render
/// `translation` (via `displayedText`) and delegate their buttons here;
/// the model is passed per call so this type never holds a strong cycle.
@MainActor
final class DescriptionTranslationController: ObservableObject {
    @Published private(set) var translation = DescriptionTranslationState()

    /// Per-owner reset — called when either view switches selection.
    func resetForSkillChange() {
        translation.resetForSkillChange()
    }

    /// The original description, or its translation once one is available.
    func displayedText(original: String) -> String {
        if translation.isTranslated, let translated = translation.translatedText {
            return translated
        }
        return original
    }

    /// Whether the translate entry is offered: a key must be configured
    /// (checked by the view against the model) and the text must carry a
    /// recognizable non-Chinese language.
    func isTranslatable(_ text: String) -> Bool {
        DescriptionTranslationSource.preferredSource(in: text) != nil
    }

    /// Toggle-or-translate: serves the memory cache first, then issues one
    /// DeepL request with the source pinned from the text's own language.
    /// Commits only while the owner path is unchanged — a slow request
    /// must never paint its text onto a different skill.
    func toggle(originalText text: String, ownerPath: String, model: AppModel) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if translation.isTranslated {
            // Toggling back is instant — the original is always at hand.
            translation.isTranslated = false
            return
        }
        if let cached = model.cachedDescriptionTranslation(for: text) {
            translation.translatedText = cached
            translation.isTranslated = true
            return
        }
        guard let apiKey = TranslationKeyStore.load() else {
            translation.error = L10n.string("Translation Error Missing Key")
            return
        }
        // Pin the source from the text's own language (the entry is hidden
        // for Chinese descriptions, so a source is always found here);
        // languages outside the provider's set translate with server-side
        // auto-detection (nil source).
        guard let source = DescriptionTranslationSource.preferredSource(in: text) else { return }
        translation.translatedText = nil
        translation.error = nil
        translation.isTranslating = true
        translation.pendingSkillPath = ownerPath
        let deeplSource = DescriptionTranslationSource.deeplSourceCode(for: source)
        Task {
            do {
                let client = DeepLTranslationClient(apiKey: apiKey)
                let translated = try await client.translate(
                    text, sourceLanguage: deeplSource, targetLanguage: "ZH"
                )
                // Commit only while the owner is unchanged (a reset cleared
                // `pendingSkillPath` when the user moved on mid-flight).
                guard translation.pendingSkillPath == ownerPath else { return }
                translation.translatedText = translated
                translation.isTranslated = true
                translation.isTranslating = false
                model.storeDescriptionTranslation(translated, for: text)
            } catch {
                guard translation.pendingSkillPath == ownerPath else { return }
                translation.isTranslating = false
                translation.error = Self.localizedTranslationError(error)
            }
        }
    }

    /// Maps backend errors to localized copy (Core errors carry no text).
    static func localizedTranslationError(_ error: Error) -> String {
        switch error as? TranslationClientError {
        case .missingAPIKey:
            return L10n.string("Translation Error Missing Key")
        case .invalidAPIKey:
            return L10n.string("Translation Error Invalid Key")
        case .quotaExceeded:
            return L10n.string("Translation Error Quota")
        case .rateLimited:
            return L10n.string("Translation Error Rate Limited")
        case .network(let message):
            return L10n.string("Translation Error Network") + " " + message
        case .unexpectedResponse, .none:
            return L10n.string("Translation Error Unexpected")
        }
    }
}

/// 翻译/原文 toggle shared by the detail views. Highlights while
/// translated; shows a leading spinner while running.
struct DescriptionTranslateButton: View {
    @ObservedObject var controller: DescriptionTranslationController
    let action: () -> Void

    var body: some View {
        Button {
            action()
        } label: {
            HStack(spacing: 4) {
                // Leading spinner while the translation runs; a clear
                // placeholder keeps the button width stable.
                if controller.translation.isTranslating {
                    ProgressView()
                        .controlSize(.mini)
                        .transition(.opacity)
                } else {
                    Color.clear
                        .frame(width: 10, height: 10)
                }
                Image(systemName: controller.translation.isTranslated
                    ? "character.bubble.fill" : "character.bubble")
                Text(verbatim: controller.translation.isTranslated
                    ? L10n.string("Show Original")
                    : L10n.string("Translate Description"))
            }
            .font(AppTheme.mono(11))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .animation(.easeInOut(duration: 0.15), value: controller.translation.isTranslating)
        .disabled(controller.translation.isTranslating)
        .help(L10n.string(controller.translation.isTranslated ? "Show Original" : "Translate Description"))
        .accessibilityLabel(L10n.string(controller.translation.isTranslated ? "Show Original" : "Translate Description"))
    }
}

/// The error row under a translated description — a failed or stalled
/// translation is never silent.
struct DescriptionTranslationErrorRow: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(AppTheme.body(11.5))
            .foregroundStyle(AppTheme.warn)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}
