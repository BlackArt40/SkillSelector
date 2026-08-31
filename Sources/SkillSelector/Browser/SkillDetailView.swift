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
    /// Drives `.translationTask` — set to kick off a translation.
    @State private var descriptionTranslationRequest: TranslationSession.Configuration?
    /// Cached translation of the current description text.
    @State private var translatedDescription: String?
    /// True while a description translation request is in flight.
    @State private var isDescriptionTranslating = false

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
        .translationTask(descriptionTranslationRequest) { session in
            // The @MainActor parameter annotation is required under Swift 6
            // (the translationTask closure itself is nonisolated; the
            // session is main-actor-isolated). Inline is the canonical
            // Translation framework usage.
            //
            // The task runs once when the view appears even without a
            // request — bail out unless the user actually tapped 翻译简介,
            // otherwise every selection would kick off a hidden translation.
            guard descriptionTranslationRequest != nil else {
                isDescriptionTranslating = false
                return
            }
            guard let skill else {
                isDescriptionTranslating = false
                return
            }
            let text = descriptionText(skill)
            // Shared cache on AppModel: translations survive selection
            // changes, so revisiting a skill is instant.
            if let cached = model.descriptionTranslations[text] {
                translatedDescription = cached
                isDescriptionTranslated = true
                isDescriptionTranslating = false
                return
            }
            // Watchdog: never leave the user on an eternal spinner. If the
            // system translation stalls (long descriptions are the usual
            // trigger), fall back to the original text after 30 seconds.
            let watchdog = Task { @MainActor in
                try? await Task.sleep(for: .seconds(30))
                if isDescriptionTranslating {
                    isDescriptionTranslating = false
                    isDescriptionTranslated = false
                }
            }
            defer { watchdog.cancel() }
            do {
                // Split long descriptions into sentence-sized segments and
                // translate them in one batch — a single translate() call
                // with a long string stalls (the spinner never clears).
                // translations(from:) keeps the response order.
                let translated = try await translateDescriptionSegments(
                    text,
                    using: session
                )
                model.descriptionTranslations[text] = translated
                translatedDescription = translated
                isDescriptionTranslated = true
            } catch {
                // Keep the original visible.
                translatedDescription = nil
                isDescriptionTranslated = false
            }
            isDescriptionTranslating = false
            descriptionTranslationRequest = nil
        }
        // Warm the en → zh-Hans language pair in the background when the
        // detail column appears, so the first real translation is fast
        // (model download/load is the slow part). prepareTranslation is a
        // no-op when the models are already installed. Most SKILL.md
        // descriptions are English, so en → zh-Hans covers the common
        // case; auto-detected sessions reuse the downloaded target model.
        .translationTask(
            source: Locale.Language(identifier: "en"),
            target: Locale.Language(identifier: "zh-Hans")
        ) { session in
            try? await session.prepareTranslation()
        }
        .onChange(of: skill?.path) { _, _ in
            // Per-skill translation state — reset when the selection moves.
            // The shared descriptionTranslations cache is intentionally kept.
            isDescriptionTranslated = false
            translatedDescription = nil
            isDescriptionTranslating = false
            descriptionTranslationRequest = nil
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
            .background(
                isDescriptionTranslated ? AppTheme.accentTint : Color.clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
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
        let text = descriptionText(skill)
        if isDescriptionTranslated {
            // Toggling back is instant — the original is always at hand.
            isDescriptionTranslated = false
        } else {
            // Prefer the shared cache; otherwise kick off the system
            // Translation session for this description.
            if let cached = model.descriptionTranslations[text] {
                translatedDescription = cached
                isDescriptionTranslated = true
            } else {
                isDescriptionTranslating = true
                translatedDescription = nil
                descriptionTranslationRequest = TranslationSession.Configuration(
                    source: nil, // auto-detect
                    target: .init(identifier: "zh-Hans")
                )
            }
        }
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
    private func translateDescriptionSegments(
        _ text: String,
        using session: TranslationSession
    ) async throws -> String {
        let segments = descriptionSegments(text)
        var result = segments
        for (index, segment) in segments.enumerated() {
            guard !segment.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let translated = try await session.translate(segment)
            result[index] = translated.targetText
        }
        return result.joined(separator: "\n")
    }

    /// Splits a description into translatable segments: paragraphs
    /// first, then paragraphs longer than 200 characters broken at
    /// sentence boundaries so no single request carries too much text.
    /// Blank lines are preserved as structure and skipped by the
    /// translator (empty requests would throw).
    private func descriptionSegments(_ text: String) -> [String] {
        let paragraphs = text.components(separatedBy: "\n")
        var segments: [String] = []
        for paragraph in paragraphs {
            if paragraph.trimmingCharacters(in: .whitespaces).isEmpty {
                segments.append(paragraph)
            } else if paragraph.count > 200 {
                segments.append(contentsOf: sentenceSegments(paragraph))
            } else {
                segments.append(paragraph)
            }
        }
        return segments
    }

    /// Breaks a long paragraph at sentence-ending punctuation, keeping
    /// the punctuation attached; any still-huge sentence is hard-split.
    private func sentenceSegments(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if "!.?".contains(character) {
                sentences.append(current)
                current = ""
            }
        }
        if !current.isEmpty {
            sentences.append(current)
        }
        return sentences.flatMap { $0.count > 200 ? lengthSegments($0) : [$0] }
    }

    /// Hard-splits a still-overlong string into ≤200-character chunks.
    private func lengthSegments(_ text: String) -> [String] {
        var chunks: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: 200, limitedBy: text.endIndex) ?? text.endIndex
            chunks.append(String(text[start..<end]))
            start = end
        }
        return chunks
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
