import SkillSelectorCore
import SwiftUI
@preconcurrency import Translation

/// The `.doc-card` from the design: warm surface card with a mono header
/// row, the frontmatter block, and the rendered markdown body. The body
/// can optionally be translated in place (macOS 15 system Translation)
/// via a 翻译/原文 toggle in the header — the raw document is never
/// modified, only the rendered copy.
struct MarkdownDocumentView: View {
    private enum LoadState {
        case loading
        case rendered(String)
        case raw(String)
        case tooLarge
        case failed(String)
    }

    @Environment(AppModel.self) private var model
    let skill: SkillSnapshot

    @State private var state: LoadState = .loading
    @State private var actionErrorDetail: String?
    @State private var loadedSource: String?
    /// 翻译/原文 toggle state. `true` shows the translated body.
    @State private var isTranslated = false
    /// Drives `.translationTask` — set to kick off a translation.
    @State private var translationRequest: TranslationSession.Configuration?
    /// Cached translation of the current body text.
    @State private var translatedText: String?
    /// Per-document cache: body text → translation (cleared on skill change).
    @State private var translationCache: [String: String] = [:]
    /// True while a translation request is in flight.
    @State private var isTranslating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            cardHead
            if let actionErrorDetail {
                DetailViewSupport.errorShell(
                    title: L10n.string("Unable to Open Skill Document"),
                    detail: actionErrorDetail
                )
                .padding(20)
            }
            content
        }
        .background(AppTheme.surfaceWarm, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(AppTheme.borderSoft, lineWidth: 1)
        }
        .task(id: DocumentLoadIdentity(snapshot: skill)) {
            await load()
        }
        .translationTask(translationRequest) { session in
            // The @MainActor parameter annotation is required under Swift 6
            // (the translationTask closure itself is nonisolated; the
            // session is main-actor-isolated). Inline is the canonical
            // Translation framework usage.
            guard case .rendered(let text) = state else {
                isTranslating = false
                return
            }
            if let cached = translationCache[text] {
                translatedText = cached
                isTranslated = true
                isTranslating = false
                return
            }
            do {
                // Body only — frontmatter is intentionally excluded. The
                // async translate hops off the main thread itself.
                //
                // Markdown-aware translation: fenced code blocks (``` / ~~~)
                // keep their content untouched — code is not prose — while
                // everything outside fences is translated. The result is
                // recombined with the fences intact and rendered as markdown
                // by MarkdownBodyView.
                let translated = try await translateMarkdownPreservingFences(
                    text,
                    using: session
                )
                translationCache[text] = translated
                translatedText = translated
                isTranslated = true
            } catch {
                // Keep the original visible; the toggle falls back to 原文.
                translatedText = nil
                isTranslated = false
            }
            isTranslating = false
            translationRequest = nil
        }
    }

    /// Translates markdown body text while leaving fenced code blocks
    /// verbatim. Each non-fence chunk is translated as a unit so headings,
    /// emphasis and inline code markers survive the round trip and the
    /// translated body still renders as markdown.
    ///
    /// Two passes: split into code/prose segments, then translate each
    /// prose segment. The translate call stays directly in this function's
    /// body — a nested async closure (or helper) trips the Swift 6 strict
    /// sendability check under release optimizations, even though debug
    /// builds accept it.
    private func translateMarkdownPreservingFences(
        _ text: String,
        using session: TranslationSession
    ) async throws -> String {
        // Pass 1: split into segments tagged code vs prose. Fence markers
        // and their contents are code; everything else is prose.
        var segments: [(isCode: Bool, content: String)] = []
        var inFence = false
        var currentCode: [String] = []
        var currentProse: [String] = []

        func appendCode() {
            if !currentCode.isEmpty {
                segments.append((isCode: true, content: currentCode.joined(separator: "\n")))
                currentCode = []
            }
        }

        func appendProse() {
            if !currentProse.isEmpty {
                segments.append((isCode: false, content: currentProse.joined(separator: "\n")))
                currentProse = []
            }
        }

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                // A fence marker always sits in its own code segment.
                appendProse()
                appendCode()
                segments.append((isCode: true, content: line))
                inFence.toggle()
            } else if inFence {
                currentCode.append(line)
            } else {
                currentProse.append(line)
            }
        }
        appendCode()
        appendProse()

        // Pass 2: translate prose segments in place. The call is inline in
        // this loop (no nested async closure) so release-mode isolation
        // checks accept it.
        var result: [String] = []
        for segment in segments {
            if segment.isCode {
                result.append(segment.content)
            } else {
                let translated = try await session.translate(segment.content)
                result.append(translated.targetText)
            }
        }
        return result.joined(separator: "\n")
    }

    private var cardHead: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc")
                .font(.system(size: 12))
            Text(verbatim: L10n.string("Doc Card Title", skill.entryFilename))
                .lineLimit(1)
            Spacer(minLength: 8)
            // 翻译/原文 toggle (body only). Highlights while the translated
            // body is shown; disabled while loading / before the body loads.
            if canTranslate {
                Button {
                    toggleTranslation()
                } label: {
                    HStack(spacing: 4) {
                        // Leading spinner while the translation runs; a
                        // clear placeholder keeps the button width stable
                        // when the spinner appears/disappears.
                        if isTranslating {
                            ProgressView()
                                .controlSize(.mini)
                                .transition(.opacity)
                        } else {
                            Color.clear
                                .frame(width: 10, height: 10)
                        }
                        Image(systemName: isTranslated ? "character.bubble.fill" : "character.bubble")
                        Text(verbatim: isTranslated
                            ? L10n.string("Show Original")
                            : L10n.string("Translate Body"))
                    }
                    .font(AppTheme.mono(11.5))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        isTranslated ? AppTheme.accentTint : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .animation(.smooth(duration: 0.15), value: isTranslating)
                .help(L10n.string(isTranslated ? "Show Original" : "Translate Body"))
                .accessibilityLabel(L10n.string(isTranslated ? "Show Original" : "Translate Body"))
                .disabled(isTranslating || !bodyTextAvailable)
            }
            iconButton(
                systemName: "folder",
                label: L10n.string("Reveal Skill Document in Finder"),
                action: reveal
            )
            iconButton(
                systemName: "arrow.up.forward.app",
                label: L10n.string("Open Skill Document in Default Editor"),
                action: open
            )
        }
        .font(AppTheme.mono(11.5))
        .foregroundStyle(AppTheme.muted)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(AppTheme.borderSoft)
                .frame(height: 1)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(verbatim: L10n.string("Loading Skill document"))
                    .foregroundStyle(AppTheme.muted)
            }
            .padding(20)
        case .rendered(let text):
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let frontmatter {
                        frontmatterBlock(frontmatter)
                    }
                    if isTranslated {
                        translatedBodyView(text)
                    } else {
                        MarkdownBodyView(text: text)
                            .padding(20)
                    }
                }
            }
        case .raw(let source):
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let frontmatter {
                        frontmatterBlock(frontmatter)
                    }
                    Text(verbatim: source)
                        .font(AppTheme.mono(12))
                        .foregroundStyle(AppTheme.foregroundSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(20)
                }
            }
        case .tooLarge:
            DetailViewSupport.messageShell(
                title: L10n.string("Document Too Large to Render"),
                detail: L10n.string("Documents larger than 1 MiB can be opened in the default editor.")
            )
            .padding(20)
        case .failed(let detail):
            DetailViewSupport.errorShell(title: L10n.string("Unable to Load Skill Document"), detail: detail)
                .padding(20)
        }
    }

    /// `.fm` — the raw frontmatter block on a surface strip.
    private func frontmatterBlock(_ text: String) -> some View {
        Text(verbatim: text)
            .font(AppTheme.mono(11.5))
            .foregroundStyle(AppTheme.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(AppTheme.surface)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(AppTheme.borderSoft)
                    .frame(height: 1)
            }
            .textSelection(.enabled)
    }

    /// The `---` delimited frontmatter block of the loaded source, or nil
    /// when the document has none.
    private var frontmatter: String? {
        frontmatterSource
    }

    private var frontmatterSource: String? {
        guard let loadedSource else { return nil }
        let lines = loadedSource.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        guard let boundary = lines.dropFirst().firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "---"
        }) else { return nil }
        return (lines[0...boundary]).joined(separator: "\n")
    }

    /// The document is loaded and rendered — only then is translating
    /// meaningful (raw/tooLarge/failed states have no body to translate).
    private var canTranslate: Bool {
        if case .rendered = state { return true }
        return false
    }

    /// Non-empty rendered body text to translate.
    private var bodyTextAvailable: Bool {
        if case .rendered(let text) = state {
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return false
    }

    private func toggleTranslation() {
        guard case .rendered(let text) = state else { return }
        if isTranslated {
            // Toggling back is instant — the original is always at hand.
            isTranslated = false
        } else {
            // Prefer the cache; otherwise kick off the system Translation
            // session for this body.
            if let cached = translationCache[text] {
                translatedText = cached
                isTranslated = true
            } else {
                isTranslating = true
                translatedText = nil
                translationRequest = TranslationSession.Configuration(
                    source: nil, // auto-detect
                    target: .init(identifier: "zh-Hans")
                )
            }
        }
    }


    /// The translated body: a small "中文" label above the translation
    /// (rendered through the markdown pipeline). The source text is not
    /// shown alongside — only the translation.
    @ViewBuilder
    private func translatedBodyView(_ original: String) -> some View {
        Group {
            if let translatedText {
                VStack(alignment: .leading, spacing: 16) {
                    bilingualLanguageTag(L10n.string("Chinese"))
                    MarkdownBodyView(text: translatedText)
                }
            } else if isTranslating {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(verbatim: L10n.string("Translating"))
                        .foregroundStyle(AppTheme.muted)
                }
            } else {
                // Translation failed — show the original.
                MarkdownBodyView(text: original)
            }
        }
        .padding(20)
    }

    /// Small muted language label above the translated pane ("中文").
    private func bilingualLanguageTag(_ label: String) -> some View {
        Text(verbatim: label)
            .font(AppTheme.body(11, weight: .semibold))
            .foregroundStyle(AppTheme.meta)
            .textCase(.uppercase)
    }

    @MainActor
    private func load() async {
        actionErrorDetail = nil
        state = .loading
        loadedSource = nil
        // Reset translation UI for the new document (per-skill state).
        isTranslated = false
        translatedText = nil
        isTranslating = false
        translationRequest = nil
        translationCache = [:]
        do {
            let document = try await model.loadDocument(for: skill)
            try Task.checkCancellation()
            let source = document.source
            loadedSource = source
            let text = MarkdownBody.hardenedText(from: FrontmatterParser.bodyLines(from: source))
            try Task.checkCancellation()
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                state = .rendered(text)
            } else {
                state = .raw(source)
            }
        } catch SkillDocumentReaderError.tooLarge {
            guard !Task.isCancelled else { return }
            state = .tooLarge
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            state = .failed(localizedDocumentError(error))
        }
    }

    private func reveal() {
        performAction { try model.revealDocumentInFinder(for: skill) }
    }

    private func open() {
        performAction { try model.openDocumentInDefaultEditor(for: skill) }
    }

    private func performAction(_ action: () throws -> Void) {
        do {
            try action()
            actionErrorDetail = nil
        } catch {
            actionErrorDetail = localizedDocumentError(error)
        }
    }

    private func iconButton(
        systemName: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(label)
        .accessibilityLabel(label)
    }

    private func localizedDocumentError(_ error: Error) -> String {
        if let error = error as? SkillDocumentReaderError {
            return L10n.string(error.localizationKey)
        }
        return (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}
