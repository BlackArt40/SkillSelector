import SkillSelectorCore
import SwiftUI

/// The middle `.list-col` column for rules files: a header with title and
/// count, and the scrollable list of rules-file rows. Read-only — rows
/// reveal in Finder or open in the default editor, nothing else.
struct RulesListView: View {
    let files: [RulesFileDescriptor]
    var selection: String?
    var agentNamesByID: [String: String] = [:]
    var onSelect: ((RulesFileDescriptor) -> Void)?
    var onReveal: ((RulesFileDescriptor) -> Void)?
    var onOpen: ((RulesFileDescriptor) -> Void)?

    /// In-column text filter (path contains the term).
    @State private var searchText = ""

    private var displayedFiles: [RulesFileDescriptor] {
        let term = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return files }
        return files.filter { $0.path.localizedCaseInsensitiveContains(term) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle()
                .fill(AppTheme.borderSoft)
                .frame(height: 1)
            if !files.isEmpty {
                ListSearchBar(placeholderKey: "Search Paths Filenames Placeholder", text: $searchText)
            }
            content
        }
        .background(AppTheme.background)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(verbatim: L10n.string("Rules"))
                .font(AppTheme.display(17, weight: .semibold))
                .foregroundStyle(AppTheme.foreground)
                .lineLimit(1)
            Text(verbatim: "\(files.count)")
                .font(AppTheme.body(12))
                .foregroundStyle(AppTheme.muted)
            Spacer(minLength: 8)
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .frame(height: 46)
        .background(AppTheme.background)
    }

    @ViewBuilder
    private var content: some View {
        if files.isEmpty {
            emptyState
        } else if displayedFiles.isEmpty {
            NoResultsView()
        } else {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(displayedFiles) { file in
                        RulesFileRow(
                            file: file,
                            agentNamesByID: agentNamesByID,
                            isActive: selection == file.id,
                            highlightQuery: searchText,
                            onSelect: { onSelect?(file) },
                            onReveal: { onReveal?(file) },
                            onOpen: { onOpen?(file) }
                        )
                        .padding(.horizontal, 8)
                    }
                }
                .padding(.vertical, 8)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 48)
            Image(systemName: "text.document")
                .font(.system(size: 26))
                .foregroundStyle(AppTheme.meta)
            Text(verbatim: L10n.string("No Rules Files"))
                .font(AppTheme.display(17, weight: .semibold))
                .foregroundStyle(AppTheme.foreground)
            Text(verbatim: L10n.string("No Rules Files Description"))
                .font(AppTheme.body(13))
                .foregroundStyle(AppTheme.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)
            Spacer(minLength: 48)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One `.skill-row`-like row for a rules file: filename, agent badge,
/// path, size, and a reveal action.
struct RulesFileRow: View {
    let file: RulesFileDescriptor
    var agentNamesByID: [String: String] = [:]
    let isActive: Bool
    /// Active search text; hits in the filename/path are highlighted.
    var highlightQuery: String = ""
    var onSelect: (() -> Void)?
    var onReveal: (() -> Void)?
    var onOpen: (() -> Void)?

    /// Display names of the Agents that read this rules file, registry
    /// order; shared files (e.g. a project CLAUDE.md) carry several.
    private var agentNames: [String] {
        file.agentIDs.compactMap { agentNamesByID[$0] }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text")
                .font(.system(size: 13))
                .foregroundStyle(isActive ? AppTheme.accentActive : AppTheme.muted)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    HighlightedText(
                        text: file.filename,
                        query: highlightQuery,
                        font: AppTheme.body(13, weight: .medium),
                        baseColor: isActive ? AppTheme.accentActive : AppTheme.foreground
                    )
                    .lineLimit(1)
                    if !agentNames.isEmpty {
                        ForEach(agentNames.prefix(3), id: \.self) { name in
                            AgentChip(text: name, onActiveRow: isActive)
                        }
                        if agentNames.count > 3 {
                            AgentChip(
                                text: "+\(agentNames.count - 3)",
                                onActiveRow: isActive
                            )
                        }
                    }
                }
                HighlightedText(
                    text: file.path,
                    query: highlightQuery,
                    font: AppTheme.mono(11),
                    baseColor: AppTheme.muted
                )
                .lineLimit(1)
                .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if let fileSize = file.fileSize {
                Text(verbatim: ByteCountFormatter.string(
                    fromByteCount: Int64(fileSize),
                    countStyle: .file
                ))
                .font(AppTheme.body(11))
                .foregroundStyle(AppTheme.meta)
            }
            Button {
                onReveal?()
            } label: {
                Image(systemName: "folder")
                    .font(.system(size: 12))
                    .foregroundStyle(AppTheme.muted)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.string("Reveal in Finder"))
            .accessibilityLabel(L10n.string("Reveal in Finder"))
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 46)
        .background(isActive ? AppTheme.accentTint : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect?()
        }
        .contextMenu {
            Button {
                onReveal?()
            } label: {
                Label(L10n.string("Reveal in Finder"), systemImage: "folder")
            }
            Button {
                onOpen?()
            } label: {
                Label(L10n.string("Open in Default Editor"), systemImage: "chevron.left.forwardslash.chevron.right")
            }
        }
    }
}
