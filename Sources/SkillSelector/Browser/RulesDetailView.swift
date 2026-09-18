import AppKit
import SkillSelectorCore
import SwiftUI

/// The right `.detail` column for one rules file, laid out like
/// `SkillDetailView` / `McpDetailView`: hero (tile + filename + path +
/// agent badge), an action bar, the rendered markdown content, and a
/// metadata grid. Read-only — rules files are only revealed or opened.
struct RulesDetailView: View {
    @EnvironmentObject private var model: AppModel
    let file: RulesFileDescriptor?
    var agentNamesByID: [String: String] = [:]
    var onReveal: ((RulesFileDescriptor) -> Void)?
    var onOpen: ((RulesFileDescriptor) -> Void)?

    private enum ContentState {
        case loading
        case rendered(String)
        case raw(String)
        case tooLarge
        case failed(String)
    }

    @State private var contentState: ContentState = .loading
    @State private var actionError: String?

    var body: some View {
        if let file {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    hero(file)
                    actionBar(file)
                    contentSection(file)
                    comparisonSection(file)
                    metadataSection(file)
                }
                .padding(16)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            // rules.html's detail pane carries the card fill — its content
            // blocks sit on the page tone for the inverted contrast.
            .background(AppTheme.surface)
            .navigationTitle(file.filename)
            .task(id: file.id) {
                await load(file)
            }
        } else {
            emptyState
                .background(AppTheme.surface)
        }
    }

    // MARK: Hero

    private func hero(_ file: RulesFileDescriptor) -> some View {
        HStack(alignment: .top, spacing: 12) {
            SkillTileView(
                title: skillTileLetter(for: file.filename),
                size: 40,
                inkBorder: true
            )
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: file.filename)
                    .font(AppTheme.mono(16, weight: .bold))
                    .foregroundStyle(AppTheme.foreground)
                    .lineLimit(1)
                    .textSelection(.enabled)
                Text(verbatim: file.path)
                    .font(AppTheme.mono(12))
                    .foregroundStyle(AppTheme.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
    }

    private var agentNames: [String] {
        file?.agentIDs.compactMap { agentNamesByID[$0] } ?? []
    }

    private func scopeLabel(_ file: RulesFileDescriptor) -> String {
        file.projectRootID != nil
            ? L10n.string("Project")
            : L10n.string("Global")
    }

    // MARK: Action bar

    private func actionBar(_ file: RulesFileDescriptor) -> some View {
        HStack(spacing: 8) {
            Button {
                onReveal?(file)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .font(.system(size: 12))
                    Text(verbatim: L10n.string("Reveal in Finder"))
                }
            }
            .buttonStyle(CompactInkButtonStyle())
            .help(L10n.string("Reveal in Finder"))
            .accessibilityLabel(L10n.string("Reveal in Finder"))
            Button {
                onOpen?(file)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "pencil")
                        .font(.system(size: 12))
                    Text(verbatim: L10n.string("Open in Default Editor"))
                }
            }
            .buttonStyle(CompactInkButtonStyle())
            .help(L10n.string("Open in Default Editor"))
            .accessibilityLabel(L10n.string("Open in Default Editor"))
            Spacer(minLength: 8)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Content

    @ViewBuilder
    private func contentSection(_ file: RulesFileDescriptor) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            DetailViewSupport.sectionHeading(L10n.string("Rules Content"))
            if let actionError {
                DetailViewSupport.errorShell(title: L10n.string("Unable to Open Skill Document"), detail: actionError)
            }
            switch contentState {
            case .loading:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(verbatim: L10n.string("Loading Skill document"))
                        .foregroundStyle(AppTheme.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .inkContentBlock
            case .rendered(let text):
                MarkdownBodyView(text: text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .inkContentBlock
            case .raw(let source):
                Text(verbatim: source)
                    .font(AppTheme.mono(11))
                    .foregroundStyle(AppTheme.foreground)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .inkContentBlock
            case .tooLarge:
                DetailViewSupport.messageShell(
                    title: L10n.string("Document Too Large to Render"),
                    detail: L10n.string("Documents larger than 1 MiB can be opened in the default editor.")
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .inkContentBlock
            case .failed(let detail):
                DetailViewSupport.errorShell(title: L10n.string("Unable to Load Skill Document"), detail: detail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .inkContentBlock
            }
        }
    }

    // MARK: Metadata

    /// rules.html's `#config-table`: a 2 px ink-bordered definition list on
    /// the page tone, muted key left, mono value right.
    private func metadataSection(_ file: RulesFileDescriptor) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            DetailViewSupport.sectionHeading(L10n.string("Configuration"))
            VStack(alignment: .leading, spacing: 6) {
                configRow(L10n.string("Level"), value: scopeLabel(file))
                configRow(
                    L10n.string("Agent"),
                    value: agentNames.isEmpty
                        ? L10n.string("None")
                        : agentNames.joined(separator: ", ")
                )
                configRow(L10n.string("Path"), value: file.path)
                if let fileSize = file.fileSize {
                    configRow(
                        L10n.string("Size"),
                        value: ByteCountFormatter.string(
                            fromByteCount: Int64(fileSize),
                            countStyle: .file
                        )
                    )
                }
                if let date = file.modificationDate {
                    configRow(
                        L10n.string("Modified"),
                        value: date.formatted(date: .abbreviated, time: .shortened)
                    )
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(Rectangle().stroke(AppTheme.ink, lineWidth: 2))
        }
    }

    private func configRow(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(verbatim: label)
                .font(AppTheme.body(12))
                .foregroundStyle(AppTheme.muted)
            Spacer(minLength: 8)
            Text(verbatim: value)
                .font(AppTheme.mono(12))
                .foregroundStyle(AppTheme.foreground)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.trailing)
        }
    }

    // MARK: Comparison

    /// Rules files worth comparing against this one.
    ///
    /// Two axes, answering different questions. The same name in another
    /// root is the global-versus-project case that was always covered. A
    /// different name in the *same* root is the one nothing covered before:
    /// a project that has both `CLAUDE.md` and `AGENTS.md` and no longer
    /// keeps them in step.
    @ViewBuilder
    private func comparisonSection(_ file: RulesFileDescriptor) -> some View {
        let sameName = model.rules.files.filter {
            $0.filename == file.filename && $0.id != file.id
        }
        let otherNames = model.rules.files.filter {
            $0.filename != file.filename && $0.projectRootID == file.projectRootID
        }
        if !sameName.isEmpty || !otherNames.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                if !sameName.isEmpty {
                    DetailViewSupport.sectionHeading(L10n.string("Same-Name Rules Comparison"))
                    ForEach(sameName) { counterpart in
                        RuleFileDiffCard(file: file, counterpart: counterpart)
                    }
                }
                if !otherNames.isEmpty {
                    DetailViewSupport.sectionHeading(L10n.string("Other Rules Files"))
                    ForEach(otherNames) { counterpart in
                        RuleFileDiffCard(file: file, counterpart: counterpart)
                    }
                }
            }
        }
    }

    @MainActor
    private func load(_ file: RulesFileDescriptor) async {
        actionError = nil
        contentState = .loading
        do {
            let document = try await model.rules.loadDocument(file)
            try Task.checkCancellation()
            let text = MarkdownBody.hardenedText(from: FrontmatterParser.bodyLines(from: document.source))
            try Task.checkCancellation()
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                contentState = .rendered(text)
            } else {
                contentState = .raw(document.source)
            }
        } catch SkillDocumentReaderError.tooLarge {
            guard !Task.isCancelled else { return }
            contentState = .tooLarge
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            contentState = .failed(
                (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            )
        }
    }

    // MARK: Empty state

    /// Same treatment as the MCP detail's empty state: the design shows the
    /// rules pane only with a selection, so the placeholder borrows
    /// mcp.html's ink-bordered glyph box.
    private var emptyState: some View {
        VStack(spacing: 20) {
            Rectangle()
                .fill(AppTheme.surface)
                .frame(width: 96, height: 96)
                .overlay {
                    Image(systemName: "doc.text")
                        .font(.system(size: 40))
                        .foregroundStyle(AppTheme.foregroundSecondary)
                }
                .overlay(Rectangle().stroke(AppTheme.ink, lineWidth: 2))
                .hardShadow(.rest)
            VStack(spacing: 8) {
                Text(verbatim: L10n.string("Select a Rules File"))
                    .font(AppTheme.body(14, weight: .bold))
                    .foregroundStyle(AppTheme.foreground)
                Text(verbatim: L10n.string("Select a Rules File Description"))
                    .font(AppTheme.body(12))
                    .foregroundStyle(AppTheme.muted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 240)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// rules.html's detail action buttons: 32 pt tall, 2 px ink border on the
/// page-tone fill, small bold label, hard shadow, hover lift / press sink.
private struct CompactInkButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AppTheme.body(12, weight: .bold))
            .foregroundStyle(AppTheme.foreground)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(AppTheme.background)
            .overlay(Rectangle().stroke(AppTheme.ink, lineWidth: 2))
            .contentShape(Rectangle())
            .modifier(CompactInkChrome(isPressed: configuration.isPressed, isHovering: isHovering))
            .onHover { isHovering = $0 }
    }
}

private struct CompactInkChrome: ViewModifier {
    let isPressed: Bool
    let isHovering: Bool

    func body(content: Content) -> some View {
        Group {
            if isPressed {
                content
            } else {
                content
                    .hardShadow(isHovering ? .raised : .rest)
            }
        }
        .offset(
            x: isPressed ? 1 : (isHovering ? -1 : 0),
            y: isPressed ? 1 : (isHovering ? -1 : 0)
        )
    }
}

/// rules.html content blocks: 2 px ink border on the page-tone fill with
/// 12 pt padding (`border-2 border-ring bg-background p-3`).
private struct InkContentBlock: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.background)
            .overlay(Rectangle().stroke(AppTheme.ink, lineWidth: 2))
    }
}

private extension View {
    var inkContentBlock: some View {
        modifier(InkContentBlock())
    }
}

/// One counterpart rules file, with a lazy line diff against the selected
/// file and an expandable view of both the paragraph summary and the diff.
private struct RuleFileDiffCard: View {
    @EnvironmentObject private var model: AppModel
    let file: RulesFileDescriptor
    let counterpart: RulesFileDescriptor

    @State private var diff: LineDiff?
    @State private var structure: RulesStructuralComparison?
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: { isExpanded.toggle() }) {
                HStack(spacing: 8) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 12))
                        .foregroundStyle(AppTheme.accentInk)
                    Text(verbatim: counterpart.path)
                        .font(AppTheme.mono(12))
                        .foregroundStyle(AppTheme.foregroundSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    scopeBadge
                    Spacer(minLength: 8)
                    if let diff {
                        summaryBadge(diff)
                    } else {
                        ProgressView()
                            .controlSize(.mini)
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10))
                        .foregroundStyle(AppTheme.meta)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.vertical, 8)

            if isExpanded {
                if let diff {
                    VStack(alignment: .leading, spacing: 10) {
                        if let structure, !structure.isIdentical || !structure.isAligned {
                            structuralSummary(structure)
                        }
                        if diff.rows.allSatisfy({ $0.kind == .same }) {
                            Text(verbatim: L10n.string("Identical Content"))
                                .font(AppTheme.body(11.5))
                                .foregroundStyle(AppTheme.muted)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            LineDiffView(diff: diff)
                        }
                    }
                    .padding(8)
                }
                Rectangle()
                    .fill(AppTheme.ink)
                    .frame(height: 1)
            }
        }
        .background(AppTheme.background)
        .overlay {
            Rectangle().stroke(AppTheme.ink, lineWidth: 1)
        }
        .task(id: counterpart.id) {
            guard let result = await model.rules.bodyComparison(file, counterpart) else { return }
            diff = result.lines
            structure = result.structure
        }
    }

    // MARK: Paragraph summary

    /// The paragraph-level answer, above the line diff: "which paragraphs
    /// differ" is the question, and the diff is the receipt for it.
    @ViewBuilder
    private func structuralSummary(_ structure: RulesStructuralComparison) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if structure.isAligned {
                Text(verbatim: L10n.string("Paragraphs Differ %d", structure.divergences.count))
                    .font(AppTheme.body(11, weight: .medium))
                    .foregroundStyle(AppTheme.foregroundSecondary)
                // Capped: a badly drifted pair can produce hundreds of
                // divergences, and the line diff below already carries the
                // full picture.
                ForEach(structure.divergences.prefix(Self.maximumListedDivergences)) { divergence in
                    Text(verbatim: summaryLine(divergence))
                        .font(AppTheme.body(11))
                        .foregroundStyle(AppTheme.muted)
                        .lineLimit(1)
                }
                let remaining = structure.divergences.count - Self.maximumListedDivergences
                if remaining > 0 {
                    Text(verbatim: L10n.string("Paragraphs Differ More %d", remaining))
                        .font(AppTheme.body(11))
                        .foregroundStyle(AppTheme.muted)
                }
            } else {
                Text(verbatim: L10n.string("Paragraph Compare Too Large"))
                    .font(AppTheme.body(11))
                    .foregroundStyle(AppTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// "Block 3 · changed" — block numbers stay visible so the two files can
    /// be checked in place, which is the whole point of reporting paragraphs
    /// rather than lines.
    private func summaryLine(_ divergence: RulesStructuralComparison.Divergence) -> String {
        let kind: String
        switch divergence.kind {
        case .changed: kind = L10n.string("Paragraph Changed")
        case .onlyInFirst: kind = L10n.string("Paragraph Only In This File")
        case .onlyInSecond: kind = L10n.string("Paragraph Only In That File")
        }
        let numbers = [divergence.firstBlock, divergence.secondBlock]
            .compactMap { $0 }
            .map(String.init)
            .joined(separator: "/")
        return "\(L10n.string("Rules Paragraph")) \(numbers) · \(kind)"
    }

    private static let maximumListedDivergences = 8

    private var scopeBadge: some View {
        InkChip(
            text: counterpart.projectRootID != nil
                ? L10n.string("Project")
                : L10n.string("Global"),
            muted: true
        )
    }

    /// rules.html's verdict chip on each comparison row: the ink chip for
    /// a real difference, the muted chip for "identical".
    @ViewBuilder
    private func summaryBadge(_ diff: LineDiff) -> some View {
        if diff.rows.allSatisfy({ $0.kind == .same }) {
            InkChip(text: L10n.string("Identical Content"), muted: true)
        } else {
            InkChip(text: "+\(diff.addedCount) −\(diff.removedCount)")
        }
    }
}
