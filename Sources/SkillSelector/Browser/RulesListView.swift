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
        return files
            .filter { $0.path.localizedCaseInsensitiveContains(term) }
            // Filename hits float above path-only hits (stable), matching
            // the other list columns' name-first search.
            .sorted { lhs, rhs in
                let lhsHit = URL(fileURLWithPath: lhs.path).lastPathComponent.localizedCaseInsensitiveContains(term)
                let rhsHit = URL(fileURLWithPath: rhs.path).lastPathComponent.localizedCaseInsensitiveContains(term)
                if lhsHit != rhsHit { return lhsHit }
                return false
            }
    }

    var body: some View {
        ScrollView {
            // rules.html `#list-pane`: one padded column — heading row,
            // search field, then the bordered file cards — no toolbar
            // hairline between them.
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: L10n.string("Rules"))
                        .font(AppTheme.display(24, weight: .bold))
                        .kerning(-1.2)
                        .foregroundStyle(AppTheme.foreground)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(verbatim: "\(displayedFiles.count)")
                        .font(AppTheme.mono(13))
                        .foregroundStyle(AppTheme.muted)
                        .accessibilityLabel(String.localizedStringWithFormat(
                            L10n.string("Rules List Count"), displayedFiles.count
                        ))
                }
                if !files.isEmpty {
                    ListSearchBar(
                        placeholderKey: "Search Paths Filenames Placeholder",
                        text: $searchText,
                        style: .inputInk,
                        height: 36
                    )
                }
                content
            }
            .padding(16)
        }
        .background(AppTheme.background)
    }

    @ViewBuilder
    private var content: some View {
        if files.isEmpty {
            emptyState
        } else if displayedFiles.isEmpty {
            NoResultsView()
        } else {
            // rules.html `#file-list`: 2 px ink-bordered cards with 8 px
            // gaps; the selected card swaps its card fill for the muted one.
            VStack(spacing: 8) {
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
                }
            }
        }
    }

    private var emptyState: some View {
        EmptyState(
            icon: "doc.text",
            title: L10n.string("No Rules Files"),
            message: L10n.string("No Rules Files Description")
        )
    }
}

/// One rules.html card (`article`): the mono filename with the byte count
/// on the baseline row, then the wrapped agent chips — a 2 px ink-bordered
/// card panel, selected with the muted fill.
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                HighlightedText(
                    text: file.filename,
                    query: highlightQuery,
                    font: AppTheme.mono(13, weight: .bold),
                    baseColor: AppTheme.foreground
                )
                .lineLimit(1)
                Spacer(minLength: 8)
                if let fileSize = file.fileSize {
                    Text(verbatim: ByteCountFormatter.string(
                        fromByteCount: Int64(fileSize),
                        countStyle: .file
                    ))
                    .font(AppTheme.mono(12))
                    .foregroundStyle(AppTheme.muted)
                }
            }
            if !agentNames.isEmpty {
                HStack(spacing: 6) {
                    ForEach(agentNames.prefix(3), id: \.self) { name in
                        InkChip(text: name)
                    }
                    if agentNames.count > 3 {
                        InkChip(text: "+\(agentNames.count - 3)", muted: true)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isActive ? AppTheme.surfaceMuted : AppTheme.surface)
        .overlay(Rectangle().stroke(AppTheme.ink, lineWidth: 2))
        .hardShadow(.rest)
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
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}
