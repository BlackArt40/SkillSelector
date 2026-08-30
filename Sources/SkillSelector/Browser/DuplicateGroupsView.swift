import SkillSelectorCore
import SwiftUI

/// The middle column for the duplicates destination. Two modes share the
/// column via a segmented control: content-identical groups (exact body
/// SHA-256) and near-duplicate clusters (bodies drifted by small edits).
/// Selecting a member keeps the normal detail pane; every member is still
/// its own record.
struct DuplicateGroupsView: View {
    enum Mode: Hashable {
        case exact
        case near
    }

    let groups: [DuplicateSkillGroup]
    let nearGroups: [NearDuplicateSkillGroup]
    let selection: SkillSelection?
    let agentNamesByID: [String: String]
    let hasAuthorization: Bool
    var onRevealInFinder: ((SkillSnapshot) -> Void)?
    var onOpenInEditor: ((SkillSnapshot) -> Void)?
    /// Marks the whole group (by fingerprint) as ignored, hiding it.
    var onIgnoreGroup: ((String) -> Void)?
    /// Marks the whole near-duplicate cluster as ignored, hiding it.
    var onIgnoreNearGroup: ((NearDuplicateSkillGroup) -> Void)?
    /// Loads the read-only comparison between two members (documents +
    /// stat trees), for the compare sheet.
    var onLoadComparison: ((SkillSnapshot, SkillSnapshot) async throws -> SkillComparison)? = nil
    let onSelect: (String) -> Void

    @State private var mode: Mode = .exact
    @State private var compareRequest: DuplicateCompareRequest?
    /// In-column text filter (any member's name contains the term).
    @State private var searchText = ""

    private var displayedExactGroups: [DuplicateSkillGroup] {
        let term = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return groups }
        return groups
            .filter { matchesSearch($0.members.map(\.name)) }
            // Groups whose display name hits float above member-only hits.
            .sorted { lhs, rhs in
                let lhsHit = lhs.members.map(\.name).min()?.localizedCaseInsensitiveContains(term) ?? false
                let rhsHit = rhs.members.map(\.name).min()?.localizedCaseInsensitiveContains(term) ?? false
                if lhsHit != rhsHit { return lhsHit }
                return false
            }
    }

    private var displayedNearGroups: [NearDuplicateSkillGroup] {
        let term = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return nearGroups }
        return nearGroups
            .filter { matchesSearch($0.members.map { $0.snapshot.name }) }
            // Groups whose display name hits float above member-only hits.
            .sorted { lhs, rhs in
                let lhsHit = lhs.members.map { $0.snapshot.name }.min()?.localizedCaseInsensitiveContains(term) ?? false
                let rhsHit = rhs.members.map { $0.snapshot.name }.min()?.localizedCaseInsensitiveContains(term) ?? false
                if lhsHit != rhsHit { return lhsHit }
                return false
            }
    }

    private func matchesSearch(_ names: [String]) -> Bool {
        let term = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return true }
        return names.contains { $0.localizedCaseInsensitiveContains(term) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle()
                .fill(AppTheme.borderSoft)
                .frame(height: 1)
            if !groups.isEmpty || !nearGroups.isEmpty {
                searchBar
            }
            content
        }
        .background(AppTheme.background)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle(L10n.string("Duplicate Skills"))
        .sheet(item: $compareRequest) { request in
            if let onLoadComparison {
                DuplicateCompareSheet(
                    request: request,
                    agentNamesByID: agentNamesByID,
                    loadComparison: onLoadComparison
                )
            }
        }
    }

    /// In-column search field — same design as the marketplace's; a group
    /// stays visible when any member's name contains the term.
    private var searchBar: some View {
        ListSearchBar(placeholderKey: "Search Skills", text: $searchText)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(verbatim: L10n.string("Duplicate Skills"))
                .font(AppTheme.display(17, weight: .semibold))
                .foregroundStyle(AppTheme.foreground)
                .lineLimit(1)
            Text(verbatim: String.localizedStringWithFormat(
                L10n.string("Duplicate Groups Count"),
                mode == .exact ? displayedExactGroups.count : displayedNearGroups.count
            ))
            .font(AppTheme.body(12))
            .foregroundStyle(AppTheme.muted)
            Spacer(minLength: 8)
            Picker(L10n.string("Duplicate Mode"), selection: $mode) {
                Text(verbatim: L10n.string("Exact Duplicates")).tag(Mode.exact)
                Text(verbatim: L10n.string("Near Duplicates")).tag(Mode.near)
            }
            .pickerStyle(.segmented)
            .frame(width: 190)
            .accessibilityLabel(L10n.string("Duplicate Mode"))
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .frame(height: 46)
        .background(AppTheme.background)
    }

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .exact:
            if groups.isEmpty {
                emptyState(
                    title: L10n.string("No Duplicates"),
                    message: L10n.string(hasAuthorization
                        ? "No Duplicates Description"
                        : "No Skills in Scope Description")
                )
            } else if displayedExactGroups.isEmpty {
                emptyState(
                    title: L10n.string("No Matching Skills"),
                    message: L10n.string("No Matching Skills Description")
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(displayedExactGroups) { group in
                            DuplicateGroupSection(
                                group: group,
                                selection: selection,
                                agentNamesByID: agentNamesByID,
                                highlightQuery: searchText,
                                onRevealInFinder: onRevealInFinder,
                                onOpenInEditor: onOpenInEditor,
                                onIgnoreGroup: onIgnoreGroup,
                                onCompare: { presentCompare(group.members) },
                                onSelect: onSelect
                            )
                        }
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 8)
                }
            }
        case .near:
            if nearGroups.isEmpty {
                emptyState(
                    title: L10n.string("No Near Duplicates"),
                    message: L10n.string(hasAuthorization
                        ? "No Near Duplicates Description"
                        : "No Skills in Scope Description")
                )
            } else if displayedNearGroups.isEmpty {
                emptyState(
                    title: L10n.string("No Matching Skills"),
                    message: L10n.string("No Matching Skills Description")
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(displayedNearGroups) { group in
                            NearDuplicateGroupSection(
                                group: group,
                                selection: selection,
                                agentNamesByID: agentNamesByID,
                                highlightQuery: searchText,
                                onRevealInFinder: onRevealInFinder,
                                onOpenInEditor: onOpenInEditor,
                                onIgnoreGroup: onIgnoreNearGroup,
                                onCompare: {
                                    presentCompare(group.members.map(\.snapshot))
                                },
                                onSelect: onSelect
                            )
                        }
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 8)
                }
            }
        }
    }

    private func presentCompare(_ members: [SkillSnapshot]) {
        guard members.count > 1 else { return }
        compareRequest = DuplicateCompareRequest(members: members)
    }

    private func emptyState(title: String, message: String) -> some View {
        VStack(spacing: 8) {
            Spacer(minLength: 48)
            Text(verbatim: title)
                .font(AppTheme.display(17, weight: .semibold))
                .foregroundStyle(AppTheme.foreground)
            Text(verbatim: message)
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

/// Shared header row for one group: icon, group name, member count, and
/// the ignore / compare actions.
private struct GroupHeaderActions: View {
    let ignoreHelp: String
    let onIgnore: () -> Void
    let onCompare: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button {
                onCompare()
            } label: {
                Label(L10n.string("Compare"), systemImage: "rectangle.split.2x1")
                    .font(AppTheme.body(11, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppTheme.muted)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(AppTheme.surface, in: Capsule())
            .overlay(Capsule().stroke(AppTheme.borderSoft, lineWidth: 1))
            .help(L10n.string("Compare Duplicate Group"))

            Button {
                onIgnore()
            } label: {
                Label(L10n.string("Ignore"), systemImage: "eye.slash")
                    .font(AppTheme.body(11, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppTheme.muted)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(AppTheme.surface, in: Capsule())
            .overlay(Capsule().stroke(AppTheme.borderSoft, lineWidth: 1))
            .help(ignoreHelp)
        }
    }
}

private struct DuplicateGroupSection: View {
    let group: DuplicateSkillGroup
    let selection: SkillSelection?
    let agentNamesByID: [String: String]
    /// Active search text; hits in the group name/member rows highlight.
    var highlightQuery: String = ""
    var onRevealInFinder: ((SkillSnapshot) -> Void)?
    var onOpenInEditor: ((SkillSnapshot) -> Void)?
    var onIgnoreGroup: ((String) -> Void)?
    var onCompare: () -> Void
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "doc.on.doc.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(AppTheme.meta)
                HighlightedText(
                    text: groupName,
                    query: highlightQuery,
                    font: AppTheme.body(12, weight: .semibold),
                    baseColor: AppTheme.muted
                )
                Text(verbatim: String.localizedStringWithFormat(
                    L10n.string("Duplicate Members Count"), group.members.count
                ))
                .font(AppTheme.body(11))
                .foregroundStyle(AppTheme.meta)
                Spacer(minLength: 8)
                GroupHeaderActions(
                    ignoreHelp: L10n.string("Ignore Duplicate Group"),
                    onIgnore: { onIgnoreGroup?(group.fingerprint) },
                    onCompare: onCompare
                )
            }
            .padding(.horizontal, 8)
            .padding(.top, 4)

            VStack(spacing: 2) {
                ForEach(group.members) { skill in
                    SkillRow(
                        skill: skill,
                        agentNamesByID: agentNamesByID,
                        isActive: selection?.path == skill.path,
                        highlightQuery: highlightQuery,
                        onSelect: { onSelect(skill.path) },
                        onRevealInFinder: onRevealInFinder,
                        onOpenInEditor: onOpenInEditor
                    )
                }
            }
        }
    }

    private var groupName: String {
        group.members.map(\.name).min() ?? group.fingerprint
    }
}

private struct NearDuplicateGroupSection: View {
    let group: NearDuplicateSkillGroup
    let selection: SkillSelection?
    let agentNamesByID: [String: String]
    /// Active search text; hits in the group name/member rows highlight.
    var highlightQuery: String = ""
    var onRevealInFinder: ((SkillSnapshot) -> Void)?
    var onOpenInEditor: ((SkillSnapshot) -> Void)?
    var onIgnoreGroup: ((NearDuplicateSkillGroup) -> Void)?
    var onCompare: () -> Void
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 12))
                    .foregroundStyle(AppTheme.meta)
                HighlightedText(
                    text: groupName,
                    query: highlightQuery,
                    font: AppTheme.body(12, weight: .semibold),
                    baseColor: AppTheme.muted
                )
                Text(verbatim: String.localizedStringWithFormat(
                    L10n.string("Near Members Count"), group.members.count
                ))
                .font(AppTheme.body(11))
                .foregroundStyle(AppTheme.meta)
                Text(verbatim: similarityRangeLabel)
                    .font(AppTheme.body(11))
                    .foregroundStyle(AppTheme.meta)
                Spacer(minLength: 8)
                GroupHeaderActions(
                    ignoreHelp: L10n.string("Ignore Near Duplicate Group"),
                    onIgnore: { onIgnoreGroup?(group) },
                    onCompare: onCompare
                )
            }
            .padding(.horizontal, 8)
            .padding(.top, 4)

            VStack(spacing: 2) {
                ForEach(group.members) { member in
                    SkillRow(
                        skill: member.snapshot,
                        agentNamesByID: agentNamesByID,
                        isActive: selection?.path == member.snapshot.path,
                        highlightQuery: highlightQuery,
                        onSelect: { onSelect(member.snapshot.path) },
                        onRevealInFinder: onRevealInFinder,
                        onOpenInEditor: onOpenInEditor
                    )
                    .overlay(alignment: .topTrailing) {
                        Text(verbatim: "≈\(member.similarityPercent)%")
                            .font(AppTheme.body(10.5, weight: .medium))
                            .foregroundStyle(AppTheme.muted)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 1)
                            .background(AppTheme.surface, in: Capsule())
                            .overlay {
                                Capsule().stroke(AppTheme.borderSoft, lineWidth: 1)
                            }
                            .padding(.top, 8)
                            .padding(.trailing, 8)
                            .help(L10n.string("Similarity Estimate Help"))
                    }
                }
            }
        }
    }

    private var groupName: String {
        group.members.map(\.snapshot.name).min() ?? group.fingerprint
    }

    private var similarityRangeLabel: String {
        let percents = group.members.map(\.similarityPercent)
        guard let minimum = percents.min(), let maximum = percents.max() else {
            return ""
        }
        return String.localizedStringWithFormat(
            L10n.string("Similarity Range"), minimum, maximum
        )
    }
}
