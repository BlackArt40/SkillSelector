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
                VStack(alignment: .leading, spacing: 32) {
                    hero(file)
                    actionBar(file)
                    contentSection(file)
                    comparisonSection(file)
                    metadataSection(file)
                }
                .padding(.horizontal, 32)
                .padding(.top, 32)
                .padding(.bottom, 48)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(AppTheme.background)
            .navigationTitle(file.filename)
            .task(id: file.id) {
                await load(file)
            }
        } else {
            emptyState
                .background(AppTheme.background)
        }
    }

    // MARK: Hero

    private func hero(_ file: RulesFileDescriptor) -> some View {
        HStack(alignment: .top, spacing: 20) {
            SkillTileView(
                title: skillTileLetter(for: file.filename),
                size: 72,
                cornerRadius: 18,
                active: false
            )
            .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: file.filename)
                    .font(AppTheme.display(28, weight: .semibold))
                    .foregroundStyle(AppTheme.foreground)
                    .lineLimit(1)
                    .textSelection(.enabled)
                Text(verbatim: file.path)
                    .font(AppTheme.mono(12))
                    .foregroundStyle(AppTheme.muted)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .padding(.top, 3)
                HStack(spacing: 8) {
                    ForEach(agentNames.prefix(5), id: \.self) { name in
                        PillBadge(text: name, style: .link)
                    }
                    if agentNames.count > 5 {
                        PillBadge(text: "+\(agentNames.count - 5)", style: .link)
                    }
                    PillBadge(text: scopeLabel(file), style: .link)
                }
                .padding(.top, 12)
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
            actionButton(
                icon: Image(systemName: "folder"),
                title: L10n.string("Reveal in Finder"),
                role: .secondary
            ) {
                onReveal?(file)
            }
            actionButton(
                icon: nil,
                title: L10n.string("Open in Default Editor"),
                role: .secondary
            ) {
                onOpen?(file)
            }
            Spacer(minLength: 8)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Content

    @ViewBuilder
    private func contentSection(_ file: RulesFileDescriptor) -> some View {
        VStack(alignment: .leading, spacing: 12) {
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
                .padding(20)
                .background(AppTheme.surfaceWarm, in: RoundedRectangle(cornerRadius: 12))
            case .rendered(let text):
                MarkdownBodyView(text: text)
                    .padding(20)
                    .background(AppTheme.surfaceWarm, in: RoundedRectangle(cornerRadius: 12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(AppTheme.borderSoft, lineWidth: 1)
                    }
            case .raw(let source):
                Text(verbatim: source)
                    .font(AppTheme.mono(12))
                    .foregroundStyle(AppTheme.foregroundSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(20)
                    .background(AppTheme.surfaceWarm, in: RoundedRectangle(cornerRadius: 12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(AppTheme.borderSoft, lineWidth: 1)
                    }
            case .tooLarge:
                DetailViewSupport.messageShell(
                    title: L10n.string("Document Too Large to Render"),
                    detail: L10n.string("Documents larger than 1 MiB can be opened in the default editor.")
                )
                .padding(20)
                .background(AppTheme.surfaceWarm, in: RoundedRectangle(cornerRadius: 12))
            case .failed(let detail):
                DetailViewSupport.errorShell(title: L10n.string("Unable to Load Skill Document"), detail: detail)
                    .padding(20)
                    .background(AppTheme.surfaceWarm, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    // MARK: Metadata

    private func metadataSection(_ file: RulesFileDescriptor) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            DetailViewSupport.sectionHeading(L10n.string("Configuration"))
            VStack(alignment: .leading, spacing: 10) {
                DetailViewSupport.keyValueRow(L10n.string("Level"), value: scopeLabel(file), monospaced: false)
                DetailViewSupport.keyValueRow(
                    L10n.string("Agent"),
                    value: agentNames.isEmpty
                        ? L10n.string("None")
                        : agentNames.joined(separator: ", "),
                    monospaced: false
                )
                DetailViewSupport.keyValueRow(L10n.string("Path"), value: file.path, monospaced: true)
                if let fileSize = file.fileSize {
                    DetailViewSupport.keyValueRow(
                        L10n.string("Size"),
                        value: ByteCountFormatter.string(
                            fromByteCount: Int64(fileSize),
                            countStyle: .file
                        ),
                        monospaced: false
                    )
                }
                if let date = file.modificationDate {
                    DetailViewSupport.keyValueRow(
                        L10n.string("Modified"),
                        value: date.formatted(date: .abbreviated, time: .shortened),
                        monospaced: false
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Same-name comparison

    /// Lists rules files that share this file's name in another root
    /// (typically the same-named file at global vs project scope), each
    /// with a lazy line diff against the selected file.
    @ViewBuilder
    private func comparisonSection(_ file: RulesFileDescriptor) -> some View {
        let counterparts = model.rules.files.filter {
            $0.filename == file.filename && $0.id != file.id
        }
        if !counterparts.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                DetailViewSupport.sectionHeading(L10n.string("Same-Name Rules Comparison"))
                ForEach(counterparts) { counterpart in
                    RuleFileDiffCard(file: file, counterpart: counterpart)
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

    private var emptyState: some View {
        VStack(spacing: 16) {
            AppIconView(size: 96)
                .opacity(0.9)
            Text(verbatim: L10n.string("Select a Rules File"))
                .font(AppTheme.display(28, weight: .semibold))
                .foregroundStyle(AppTheme.foreground)
            Text(verbatim: L10n.string("Select a Rules File Description"))
                .font(AppTheme.body(14))
                .foregroundStyle(AppTheme.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// One same-named rules file in another root, with a lazy line diff against
/// the selected file and an expandable diff view.
private struct RuleFileDiffCard: View {
    @EnvironmentObject private var model: AppModel
    let file: RulesFileDescriptor
    let counterpart: RulesFileDescriptor

    @State private var diff: LineDiff?
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: { isExpanded.toggle() }) {
                HStack(spacing: 8) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 12))
                        .foregroundStyle(AppTheme.accent)
                    Text(verbatim: counterpart.path)
                        .font(AppTheme.mono(11.5))
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
            .padding(.horizontal, 10)
            .padding(.vertical, 7)

            if isExpanded {
                if let diff {
                    if diff.rows.allSatisfy({ $0.kind == .same }) {
                        Text(verbatim: L10n.string("Identical Content"))
                            .font(AppTheme.body(11.5))
                            .foregroundStyle(AppTheme.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    } else {
                        LineDiffView(diff: diff)
                            .padding(12)
                    }
                }
                Rectangle()
                    .fill(AppTheme.borderSoft)
                    .frame(height: 1)
            }
        }
        .background(AppTheme.surfaceWarm, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(AppTheme.borderSoft, lineWidth: 1)
        }
        .task(id: counterpart.id) {
            diff = await model.rules.bodyDiff(file, counterpart)
        }
    }

    private var scopeBadge: some View {
        PillBadge(
            text: counterpart.projectRootID != nil
                ? L10n.string("Project")
                : L10n.string("Global"),
            style: .link
        )
    }

    @ViewBuilder
    private func summaryBadge(_ diff: LineDiff) -> some View {
        if diff.rows.allSatisfy({ $0.kind == .same }) {
            Text(verbatim: L10n.string("Identical Content"))
                .font(AppTheme.body(11, weight: .medium))
                .foregroundStyle(AppTheme.muted)
                .padding(.horizontal, 7)
                .padding(.vertical, 1)
                .background(AppTheme.surface, in: Capsule())
                .overlay {
                    Capsule().stroke(AppTheme.borderSoft, lineWidth: 1)
                }
        } else {
            Text(verbatim: "+\(diff.addedCount) −\(diff.removedCount)")
                .font(AppTheme.body(11, weight: .medium))
                .foregroundStyle(
                    diff.addedCount > 0 ? AppTheme.success : AppTheme.warn
                )
                .padding(.horizontal, 7)
                .padding(.vertical, 1)
                .background(AppTheme.surface, in: Capsule())
                .overlay {
                    Capsule().stroke(AppTheme.borderSoft, lineWidth: 1)
                }
        }
    }
}
