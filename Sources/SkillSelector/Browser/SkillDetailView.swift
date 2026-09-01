import AppKit
import SkillSelectorCore
import SwiftUI
@preconcurrency import Translation

/// The right `.detail` column from the design: hero, action bar, and the
/// 核心作用 / Skill 文档 / 关联 Agents / 位置 sections, capped at 720 pt.
struct SkillDetailView: View {
    @Environment(AppModel.self) private var model
    let skill: SkillSnapshot?
    let rootsByID: [String: AuthorizedRootSnapshot]
    let agentNamesByID: [String: String]
    var onRevealInFinder: ((SkillSnapshot) -> Void)?
    var onOpenInEditor: ((SkillSnapshot) -> Void)?

    /// Dynamic Type scaling for the hero title (28 → ~34) and the core /
    /// document section bodies (14 → ~17 at the largest supported size).
    @ScaledMetric(relativeTo: .largeTitle) private var heroTitleSize: CGFloat = 28
    @ScaledMetric(relativeTo: .body) private var bodySize: CGFloat = 14

    // MARK: Description translation (system Translation → zh-Hans)

    /// `true` shows the translated description instead of the original.
    @State private var isDescriptionTranslated = false
    /// Translation session configuration. Kept non-nil with an explicit
    /// en → zh-Hans pairing so `prepareTranslation()` can preload the
    /// models on warm-up and `translate()` never has to auto-detect the
    /// source language (auto-detection is a common failure/stall path).
    /// Call `invalidate()` to re-run the task on the *same* session.
    @State private var translationConfiguration = TranslationSession.Configuration(
        source: Locale.Language(identifier: "en"),
        target: Locale.Language(identifier: "zh-Hans")
    )
    /// Text queued for translation; nil means "warm-up only, nothing to do".
    @State private var pendingDescription: String?
    /// Cached translation of the current description text.
    @State private var translatedDescription: String?
    /// True while a description translation request is in flight.
    @State private var isDescriptionTranslating = false
    /// Last translation failure, shown under the description so a failed
    /// or stalled translation is never silent.
    @State private var descriptionTranslationError: String?
    /// Path of the skill that queued the current translation request. The
    /// translation task commits its result to the view only while the
    /// selection still points at this skill — an in-flight translation
    /// must never paint its text onto a different skill's detail view.
    @State private var pendingTranslationSkillPath: String?

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
            } else {
                emptyState
                    .background(AppTheme.background)
            }
        }
        .translationTask(translationConfiguration) { session in
            // The @MainActor parameter annotation is required under Swift 6
            // (the translationTask closure itself is nonisolated; the
            // session is main-actor-isolated). Inline is the canonical
            // Translation framework usage.
            //
            // One task for both jobs so warm-up and translation share the
            // same session (and its loaded language models):
            //  • view appearance (no pending text) → prepareTranslation()
            //    preloads the models; a no-op once they're installed;
            //  • user tap (pending text set + configuration invalidated)
            //    → translate the description here, on the same session.
            if let text = pendingDescription {
                // The task re-runs on invalidation; capture the requesting
                // skill so a slow translation can't overwrite the view if
                // the user switches skills while it's in flight.
                let requestedPath = pendingTranslationSkillPath
                pendingDescription = nil
                pendingTranslationSkillPath = nil
                isDescriptionTranslating = true
                descriptionTranslationError = nil
                // Defensive cache check: toggleDescriptionTranslation
                // already serves cache hits, so this is normally
                // unreachable — but the task stays idempotent if other
                // paths ever queue text.
                if let cached = model.descriptionTranslations[text] {
                    if skill?.path == requestedPath {
                        translatedDescription = cached
                        isDescriptionTranslated = true
                    }
                    isDescriptionTranslating = false
                    return
                }
                // Watchdog: never leave the user on an eternal spinner. If
                // the system translation stalls, fall back to the original
                // text after 12 seconds and surface the timeout.
                let watchdog = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(12))
                    if isDescriptionTranslating, skill?.path == requestedPath {
                        isDescriptionTranslating = false
                        descriptionTranslationError = L10n.string("Description Translation Timeout")
                    }
                }
                defer { watchdog.cancel() }
                do {
                    // Split long descriptions into sentence-sized segments
                    // and translate each individually — a single
                    // translate() call with a long string stalls.
                    let translated = try await translateDescriptionSegments(
                        text,
                        using: session
                    )
                    // Always worth caching for later visits — but commit
                    // to the view only while the selection is still the
                    // skill that asked for it. Committing also clears a
                    // timeout message when the translate call wins the
                    // race against the watchdog.
                    model.descriptionTranslations[text] = translated
                    if skill?.path == requestedPath {
                        translatedDescription = translated
                        isDescriptionTranslated = true
                        isDescriptionTranslating = false
                        descriptionTranslationError = nil
                    }
                } catch {
                    // Keep the original visible and say why — only for
                    // the requesting skill, so a stale failure never
                    // surfaces over a newer selection.
                    if skill?.path == requestedPath {
                        translatedDescription = nil
                        isDescriptionTranslated = false
                        descriptionTranslationError = localizedTranslationError()
                    }
                    isDescriptionTranslating = false
                }
            } else {
                // Warm-up: preload the language models in the background
                // (no-op when already installed).
                try? await session.prepareTranslation()
            }
        }
        .onChange(of: skill?.path) { _, _ in
            // Per-skill translation state — reset when the selection moves.
            // translationConfiguration and the shared descriptionTranslations
            // cache are intentionally kept, so the session and its loaded
            // models are reused across selections.
            isDescriptionTranslated = false
            translatedDescription = nil
            isDescriptionTranslating = false
            pendingDescription = nil
            pendingTranslationSkillPath = nil
            descriptionTranslationError = nil
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
                descriptionTranslateButton(skill)
            }
            Text(verbatim: displayedDescription(skill))
                .font(AppTheme.body(bodySize))
                .foregroundStyle(AppTheme.foregroundSecondary)
                .lineSpacing(4)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let descriptionTranslationError {
                VStack(alignment: .leading, spacing: 6) {
                    Label(descriptionTranslationError, systemImage: "exclamationmark.triangle")
                        .font(AppTheme.body(11.5))
                        .foregroundStyle(Color.orange)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    // First use needs Apple's on-device model, which the
                    // system downloads outside the app — offer a shortcut
                    // that lands on the Translation Languages pane so the
                    // user only has to click Download once.
                    Button {
                        model.openTranslationLanguageSettings()
                    } label: {
                        Label(
                            L10n.string("Download Translation Model"),
                            systemImage: "arrow.down.circle"
                        )
                        .font(AppTheme.mono(11))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .help(L10n.string("Download Translation Model Help"))
                }
            }
        }
    }

    /// The original description, or its translation once one is available.
    private func displayedDescription(_ skill: SkillSnapshot) -> String {
        if isDescriptionTranslated, let translatedDescription {
            return translatedDescription
        }
        return descriptionText(skill)
    }

    /// 翻译/原文 toggle for the description (system Translation → zh-Hans).
    /// Highlights while translated; shows a leading spinner while running.
    private func descriptionTranslateButton(_ skill: SkillSnapshot) -> some View {
        Button {
            toggleDescriptionTranslation()
        } label: {
            HStack(spacing: 4) {
                // Leading spinner while the translation runs; a clear
                // placeholder keeps the button width stable.
                if isDescriptionTranslating {
                    ProgressView()
                        .controlSize(.mini)
                        .transition(.opacity)
                } else {
                    Color.clear
                        .frame(width: 10, height: 10)
                }
                Image(systemName: isDescriptionTranslated ? "character.bubble.fill" : "character.bubble")
                Text(verbatim: isDescriptionTranslated
                    ? L10n.string("Show Original")
                    : L10n.string("Translate Description"))
            }
            .font(AppTheme.mono(11))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .animation(.smooth(duration: 0.15), value: isDescriptionTranslating)
        .help(L10n.string(isDescriptionTranslated ? "Show Original" : "Translate Description"))
        .accessibilityLabel(L10n.string(isDescriptionTranslated ? "Show Original" : "Translate Description"))
        .disabled(isDescriptionTranslating)
    }

    private func toggleDescriptionTranslation() {
        guard let skill else { return }
        let text = translationSourceText(skill)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if isDescriptionTranslated {
            // Toggling back is instant — the original is always at hand.
            isDescriptionTranslated = false
        } else {
            // Prefer the shared cache; otherwise queue the text and re-run
            // the translation task on the existing session (invalidate()
            // keeps the session and its loaded models — never rebuilds it).
            if let cached = model.descriptionTranslations[text] {
                translatedDescription = cached
                isDescriptionTranslated = true
            } else {
                pendingDescription = text
                pendingTranslationSkillPath = skill.path
                translatedDescription = nil
                descriptionTranslationError = nil
                isDescriptionTranslating = true
                translationConfiguration.invalidate()
            }
        }
    }

    /// The text sent to the translator: the raw description with common
    /// Markdown markers stripped, so the translation comes back as clean
    /// plain text (raw markers like `**` and `[..](..)` would otherwise
    /// survive the translation and show up in the result).
    private func translationSourceText(_ skill: SkillSnapshot) -> String {
        DescriptionSplitter.plainText(fromMarkdown: descriptionText(skill))
    }

    private func localizedTranslationError() -> String {
        // System error descriptions are English and unlocalized; surface
        // one generic message instead of leaking raw error text.
        L10n.string("Description Translation Failed")
    }

    /// Translates a description segment by segment: split into
    /// sentence-sized segments (paragraphs first, then long paragraphs at
    /// sentence boundaries), translate each non-empty segment with
    /// `translate(String)`, and rejoin preserving the original blank-line
    /// structure. A single `translate()` call on a long string stalls the
    /// system session — the spinner never clears. Segments stay short so
    /// each call returns quickly; the translate call stays directly in
    /// this loop (no nested async closure) so release-mode isolation
    /// checks accept it (a batch `translations(from:)` call is rejected
    /// because `[Request]` isn't Sendable under Swift 6).
    ///
    /// Rejoining: blank lines stay newlines, but sentence segments of the
    /// same paragraph are joined with a single space — the original had
    /// no line break there, so the translation must not introduce one
    /// (the split point is invisible in the output).
    private func translateDescriptionSegments(
        _ text: String,
        using session: TranslationSession
    ) async throws -> String {
        let paragraphs = text.components(separatedBy: "\n")
        var translatedParagraphs: [String] = []
        for paragraph in paragraphs {
            if paragraph.trimmingCharacters(in: .whitespaces).isEmpty {
                translatedParagraphs.append(paragraph)
            } else if paragraph.count > 200 {
                let sentences = DescriptionSplitter.sentenceSegments(paragraph)
                var translatedSentences: [String] = []
                for sentence in sentences {
                    guard !sentence.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                    let translated = try await session.translate(sentence)
                    translatedSentences.append(translated.targetText)
                }
                translatedParagraphs.append(translatedSentences.joined(separator: " "))
            } else {
                let translated = try await session.translate(paragraph)
                translatedParagraphs.append(translated.targetText)
            }
        }
        return translatedParagraphs.joined(separator: "\n")
    }

    private func descriptionText(_ skill: SkillSnapshot) -> String {
        skill.localDescription ?? skill.name
    }

    private func srcBadge(_ skill: SkillSnapshot) -> Text? {
        Text(verbatim: L10n.string("Source Badge", skill.entryFilename))
    }

    // MARK: Skill document

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
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
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
