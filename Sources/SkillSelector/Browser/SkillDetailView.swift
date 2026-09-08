import AppKit
import SkillSelectorCore
import SwiftUI

/// The right `.detail` column from the design: hero, action bar, and the
/// 核心作用 / Skill 文档 / 关联 Agents / 位置 sections, capped at 720 pt.
struct SkillDetailView: View {
    let skill: SkillSnapshot?
    let rootsByID: [String: AuthorizedRootSnapshot]
    let agentNamesByID: [String: String]
    var onRevealInFinder: ((SkillSnapshot) -> Void)?
    var onOpenInEditor: ((SkillSnapshot) -> Void)?

    @EnvironmentObject private var model: AppModel
    /// Per-selection description-translation state (see
    /// `DescriptionTranslationState`); resets together when the
    /// selection moves.
    @State private var translation = DescriptionTranslationState()

    /// Dynamic Type scaling for the hero title (28 → ~34) and the core /
    /// document section bodies (14 → ~17 at the largest supported size).
    @ScaledMetric(relativeTo: .largeTitle) private var heroTitleSize: CGFloat = 28
    @ScaledMetric(relativeTo: .body) private var bodySize: CGFloat = 14

    var body: some View {
        Group {
            if let skill {
                ScrollView {
                    VStack(alignment: .leading, spacing: 32) {
                        hero(skill)
                        actionBar(skill)
                        coreSection(skill)
                        documentSection(skill)
                        agentsSection(skill)
                        locationsSection(skill)
                    }
                    .padding(.horizontal, 32)
                    .padding(.top, 32)
                    .padding(.bottom, 48)
                    .frame(maxWidth: 720, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .background(AppTheme.background)
                .navigationTitle(skill.name)
                .onChange(of: skill.path) { _ in
                    // Per-skill translation state — reset when the
                    // selection moves.
                    translation.resetForSkillChange()
                }
            } else {
                emptyState
                    .background(AppTheme.background)
            }
        }
    }

    // MARK: Hero

    private func hero(_ skill: SkillSnapshot) -> some View {
        HStack(alignment: .top, spacing: 20) {
            SkillTileView(
                title: skillTileLetter(for: skill.name),
                size: 72,
                cornerRadius: 18,
                active: false
            )
            .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: skill.name)
                    .font(AppTheme.display(heroTitleSize, weight: .semibold))
                    .foregroundStyle(AppTheme.foreground)
                    .lineLimit(1)
                    .textSelection(.enabled)
                Text(verbatim: skill.path)
                    .font(AppTheme.mono(12))
                    .foregroundStyle(AppTheme.muted)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .padding(.top, 3)
                if heroBadges(skill) {
                    HStack(spacing: 8) {
                        if skill.resolvedTarget != nil {
                            PillBadge(text: L10n.string("Symbolic Link Pill"), style: .link)
                        }
                        if !skill.parseDiagnostics.isEmpty {
                            PillBadge(text: L10n.string("Frontmatter Warning Pill"), style: .warn)
                        }
                    }
                    .padding(.top, 12)
                }
            }
        }
    }

    private func heroBadges(_ skill: SkillSnapshot) -> Bool {
        skill.resolvedTarget != nil || !skill.parseDiagnostics.isEmpty
    }

    // MARK: Action bar

    private func actionBar(_ skill: SkillSnapshot) -> some View {
        HStack(spacing: 8) {
            actionButton(
                icon: Image(systemName: "folder"),
                title: L10n.string("Reveal in Finder"),
                role: .secondary
            ) {
                onRevealInFinder?(skill)
            }
            actionButton(
                icon: nil,
                title: L10n.string("Open in Default Editor"),
                role: .secondary
            ) {
                onOpenInEditor?(skill)
            }
            Spacer(minLength: 8)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Core role

    private func coreSection(_ skill: SkillSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 8) {
                DetailViewSupport.sectionHeading(
                    L10n.string("Core Role"),
                    badge: srcBadge(skill)
                )
                Spacer(minLength: 8)
                if model.isTranslationConfigured, isDescriptionTranslatable(skill) {
                    descriptionTranslateButton
                }
            }
            Text(verbatim: displayedDescription(skill))
                .font(AppTheme.body(bodySize))
                .foregroundStyle(AppTheme.foregroundSecondary)
                .lineSpacing(4)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let descriptionTranslationError = translation.error {
                Label(descriptionTranslationError, systemImage: "exclamationmark.triangle")
                    .font(AppTheme.body(11.5))
                    .foregroundStyle(Color.orange)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func descriptionText(_ skill: SkillSnapshot) -> String {
        skill.localDescription ?? skill.name
    }

    // MARK: Description translation (opt-in cloud provider → zh-Hans)

    /// The original description, or its translation once one is available.
    private func displayedDescription(_ skill: SkillSnapshot) -> String {
        if translation.isTranslated, let translated = translation.translatedText {
            return translated
        }
        return descriptionText(skill)
    }

    /// Whether the translate button is offered: a key must be configured
    /// (strict opt-in) and the description must carry a recognizable
    /// non-Chinese language — a simplified-Chinese description is already
    /// in the target language, so there is nothing to translate.
    private func isDescriptionTranslatable(_ skill: SkillSnapshot) -> Bool {
        DescriptionTranslationSource.preferredSource(in: descriptionText(skill)) != nil
    }

    /// 翻译/原文 toggle for the description. Highlights while translated;
    /// shows a leading spinner while running.
    private var descriptionTranslateButton: some View {
        Button {
            toggleDescriptionTranslation()
        } label: {
            HStack(spacing: 4) {
                // Leading spinner while the translation runs; a clear
                // placeholder keeps the button width stable.
                if translation.isTranslating {
                    ProgressView()
                        .controlSize(.mini)
                        .transition(.opacity)
                } else {
                    Color.clear
                        .frame(width: 10, height: 10)
                }
                Image(systemName: translation.isTranslated ? "character.bubble.fill" : "character.bubble")
                Text(verbatim: translation.isTranslated
                    ? L10n.string("Show Original")
                    : L10n.string("Translate Description"))
            }
            .font(AppTheme.mono(11))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .animation(.easeInOut(duration: 0.15), value: translation.isTranslating)
        .help(L10n.string(translation.isTranslated ? "Show Original" : "Translate Description"))
        .accessibilityLabel(L10n.string(translation.isTranslated ? "Show Original" : "Translate Description"))
        .disabled(translation.isTranslating)
    }

    private func toggleDescriptionTranslation() {
        guard let skill else { return }
        let text = descriptionText(skill)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if translation.isTranslated {
            // Toggling back is instant — the original is always at hand.
            translation.isTranslated = false
            return
        }
        if serveCachedTranslation(for: text, requestedPath: skill.path) {
            // Cache hit — nothing to translate.
            return
        }
        guard let apiKey = APIKeychain.load() else {
            translation.error = L10n.string("Translation Error Missing Key")
            return
        }
        // Pin the source from the description's own language; the button
        // is hidden for Chinese descriptions, so a source is always found
        // here. Languages outside the provider's set translate with
        // server-side auto-detection (nil source).
        guard let source = DescriptionTranslationSource.preferredSource(in: text) else { return }
        translation.translatedText = nil
        translation.error = nil
        translation.isTranslating = true
        translation.pendingSkillPath = skill.path
        let requestedPath = skill.path
        let deeplSource = DescriptionTranslationSource.deeplSourceCode(for: source)
        Task {
            do {
                let client = DeepLTranslationClient(apiKey: apiKey)
                let translated = try await client.translate(
                    text, sourceLanguage: deeplSource, targetLanguage: "ZH"
                )
                // Commit only while the selection still points at the
                // requesting skill.
                guard skill.path == requestedPath else { return }
                translation.translatedText = translated
                translation.isTranslated = true
                translation.isTranslating = false
                model.storeDescriptionTranslation(translated, for: text)
            } catch {
                guard skill.path == requestedPath else { return }
                translation.isTranslating = false
                translation.error = Self.localizedTranslationError(error)
            }
        }
    }

    /// Commits a cached translation to the view, if one exists. Returns
    /// true when a cached translation was served (committed only when the
    /// selection still points at the requesting skill).
    private func serveCachedTranslation(for text: String, requestedPath: String?) -> Bool {
        guard let cached = model.cachedDescriptionTranslation(for: text) else { return false }
        if skill?.path == requestedPath {
            translation.translatedText = cached
            translation.isTranslated = true
        }
        return true
    }

    /// Maps backend errors to localized copy (Core errors carry no text).
    private static func localizedTranslationError(_ error: Error) -> String {
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

    private func srcBadge(_ skill: SkillSnapshot) -> Text? {
        Text(verbatim: L10n.string("Source Badge", skill.entryFilename))
    }

    // MARK: Skill document

    @MainActor
    private func documentSection(_ skill: SkillSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            DetailViewSupport.sectionHeading(L10n.string("Skill Document"))
            MarkdownDocumentView(skill: skill)
                .id(skill.path)
        }
    }

    // MARK: Agents

    private func agentsSection(_ skill: SkillSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            DetailViewSupport.sectionHeading(L10n.string("Associated Agents"))
            let names = skill.agentDisplayNames(by: agentNamesByID)
            if names.isEmpty {
                Text(verbatim: L10n.string("None"))
                    .font(AppTheme.body(13))
                    .foregroundStyle(AppTheme.muted)
            } else {
                FlowChips(names: names)
            }
        }
    }

    // MARK: Locations

    private func locationsSection(_ skill: SkillSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            DetailViewSupport.sectionHeading(L10n.string("Locations"))
            VStack(alignment: .leading, spacing: 10) {
                DetailViewSupport.keyValueRow(L10n.string("Level"), value: scopeLabel(skill), monospaced: false)
                DetailViewSupport.keyValueRow(L10n.string("Root"), value: rootLabel(skill), monospaced: true)
                DetailViewSupport.keyValueRow(L10n.string("Installation Path"), value: skill.path, monospaced: true)
                if let target = skill.resolvedTarget {
                    DetailViewSupport.keyValueRow(L10n.string("Link Target"), value: target, monospaced: true)
                }
                DetailViewSupport.keyValueRow(L10n.string("Entry File"), value: skill.entryFilename, monospaced: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func scopeLabel(_ skill: SkillSnapshot) -> String {
        let kinds = skill.rootIDs.compactMap { rootsByID[$0]?.kind }
        let isProjectLevel = kinds.contains { $0 == .project || $0 == .custom }
        return isProjectLevel
            ? L10n.string("Project Scope")
            : L10n.string("Global User Scope")
    }

    private func rootLabel(_ skill: SkillSnapshot) -> String {
        guard let rootID = skill.rootIDs.first, let root = rootsByID[rootID] else {
            return skill.rootIDs.joined(separator: ", ")
        }
        return root.url.path
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 16) {
            AppIconView(size: 96)
                .opacity(0.9)
            Text(verbatim: L10n.string("Select a Skill"))
                .font(AppTheme.display(heroTitleSize, weight: .semibold))
                .foregroundStyle(AppTheme.foreground)
            Text(verbatim: L10n.string("Select a Skill Description"))
                .font(AppTheme.body(bodySize))
                .foregroundStyle(AppTheme.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}
