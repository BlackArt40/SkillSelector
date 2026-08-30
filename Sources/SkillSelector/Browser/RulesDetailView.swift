import AppKit
import SkillSelectorCore
import SwiftUI

/// The right `.detail` column for one rules file, laid out like
/// `SkillDetailView` / `McpDetailView`: hero (tile + filename + path +
/// agent badge), an action bar, the rendered markdown content, and a
/// metadata grid. Read-only — rules files are only revealed or opened.
struct RulesDetailView: View {
    @Environment(AppModel.self) private var model
    let file: RulesFileDescriptor?
    var agentNamesByID: [String: String] = [:]
    var onReveal: ((RulesFileDescriptor) -> Void)?
    var onOpen: ((RulesFileDescriptor) -> Void)?

    private enum ContentState {
        case loading
        case rendered(AttributedString)
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
                    if let agentName = file.agentID.flatMap({ agentNamesByID[$0] }) {
                        PillBadge(text: agentName, style: .link)
                    }
                    PillBadge(text: scopeLabel(file), style: .link)
                }
                .padding(.top, 12)
            }
        }
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
            sectionHeading(L10n.string("Rules Content"))
            if let actionError {
                errorShell(title: L10n.string("Unable to Open Skill Document"), detail: actionError)
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
            case .rendered(let attributed):
                Text(attributed)
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(20)
                    .background(AppTheme.surfaceWarm, in: RoundedRectangle(cornerRadius: 12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(AppTheme.borderSoft, lineWidth: 1)
                    }
                    .markdownLinkPolicy()
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
                messageShell(
                    title: L10n.string("Document Too Large to Render"),
                    detail: L10n.string("Documents larger than 1 MiB can be opened in the default editor.")
                )
                .padding(20)
                .background(AppTheme.surfaceWarm, in: RoundedRectangle(cornerRadius: 12))
            case .failed(let detail):
                errorShell(title: L10n.string("Unable to Load Skill Document"), detail: detail)
                    .padding(20)
                    .background(AppTheme.surfaceWarm, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    // MARK: Metadata

    private func metadataSection(_ file: RulesFileDescriptor) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeading(L10n.string("Configuration"))
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                keyValue(L10n.string("Level"), value: scopeLabel(file), monospaced: false)
                keyValue(
                    L10n.string("Agent"),
                    value: file.agentID.flatMap { agentNamesByID[$0] } ?? L10n.string("None"),
                    monospaced: false
                )
                keyValue(L10n.string("Path"), value: file.path, monospaced: true)
                if let fileSize = file.fileSize {
                    keyValue(
                        L10n.string("Size"),
                        value: ByteCountFormatter.string(
                            fromByteCount: Int64(fileSize),
                            countStyle: .file
                        ),
                        monospaced: false
                    )
                }
                if let date = file.modificationDate {
                    keyValue(
                        L10n.string("Modified"),
                        value: date.formatted(date: .abbreviated, time: .shortened),
                        monospaced: false
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func keyValue(_ label: String, value: String, monospaced: Bool) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(verbatim: label)
                .font(AppTheme.body(13))
                .foregroundStyle(AppTheme.muted)
                .frame(width: 108, alignment: .leading)
            Text(verbatim: value)
                .font(monospaced ? AppTheme.mono(12) : AppTheme.body(13))
                .foregroundStyle(AppTheme.foreground)
                .textSelection(.enabled)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Shared

    private func sectionHeading(_ title: String) -> some View {
        Text(verbatim: title)
            .font(AppTheme.display(14, weight: .semibold))
            .foregroundStyle(AppTheme.foreground)
    }

    private func messageShell(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: title)
                .font(.callout.weight(.medium))
            Text(verbatim: detail)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func errorShell(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Text(verbatim: detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }

    @MainActor
    private func load(_ file: RulesFileDescriptor) async {
        actionError = nil
        contentState = .loading
        do {
            let document = try await model.rules.loadDocument(file)
            try Task.checkCancellation()
            let body = MarkdownRenderer.extractBody(document.source)
            let attributed = MarkdownRenderer.buildAttributedString(from: body)
            try Task.checkCancellation()
            if let attributed {
                contentState = .rendered(attributed)
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
