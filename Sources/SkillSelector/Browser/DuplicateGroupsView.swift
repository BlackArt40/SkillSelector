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
    /// Groups the user previously ignored, offered back with a restore
    /// action so ignoring stays reversible.
    var ignoredExactGroups: [IgnoredDuplicateGroup] = []
    var ignoredNearGroups: [IgnoredDuplicateGroup] = []
    var onRestoreGroup: ((String) -> Void)?
    var onRestoreNearGroup: ((String) -> Void)?
    /// Loads the read-only comparison between two members (documents +
    /// stat trees), for the compare sheet.
    var onLoadComparison: ((SkillSnapshot, SkillSnapshot) async throws -> SkillComparison)? = nil
    /// Loads per-member body line differences within a near-duplicate
    /// group (relative to its highest-similarity baseline), for the
    /// "+N −M lines" badges.
    var onLoadNearDiffs: ((NearDuplicateSkillGroup) async -> [String: LineDiffSummary])? = nil
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

    /// duplicates.html's `.list-head`: title + count badge + the mode
    /// switch, then the search field — one block on the panel surface
    /// above a white hairline, like the main list column's.
    private var header: some View {
        VStack(spacing: 12) {
            HStack(alignment: .center, spacing: 8) {
                Text(verbatim: L10n.string("Duplicate Skills"))
                    .font(AppTheme.display(18, weight: .bold))
                    .kerning(-0.9)
                    .foregroundStyle(AppTheme.foreground)
                    .lineLimit(1)
                Text(verbatim: String.localizedStringWithFormat(
                    L10n.string("Duplicate Groups Count"),
                    mode == .exact ? displayedExactGroups.count : displayedNearGroups.count
                ))
                .font(AppTheme.body(11, weight: .bold))
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(AppTheme.surfaceMuted)
                .overlay(Rectangle().stroke(AppTheme.border, lineWidth: 1))
                Spacer(minLength: 8)
                if !groups.isEmpty || !nearGroups.isEmpty {
                    modeSwitch
                }
            }
            if !groups.isEmpty || !nearGroups.isEmpty {
                ListSearchBar(placeholderKey: "Search Skills", text: $searchText)
            }
        }
        .padding(16)
        .background(AppTheme.surface)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(AppTheme.border)
                .frame(height: 1)
        }
    }

    /// duplicates.html's `.mode-switch`: two 30 pt mode buttons; the active
    /// one inverts to the primary ink pair, the inactive ones sit on the
    /// muted surface with the hairline border. The page's visible
    /// "duplicate mode" label becomes the group's accessibility label —
    /// the header row has no room for it beside the English title.
    private var modeSwitch: some View {
        HStack(spacing: 4) {
            modeButton(.exact, title: L10n.string("Mode Exact Short"))
            modeButton(.near, title: L10n.string("Mode Near Short"))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.string("Duplicate Mode"))
    }

    private func modeButton(_ value: Mode, title: String) -> some View {
        let isActive = mode == value
        return Button {
            mode = value
        } label: {
            Text(verbatim: title)
                .font(AppTheme.body(12, weight: .bold))
                .foregroundStyle(isActive ? AppTheme.primaryButtonForeground : AppTheme.foreground)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .fixedSize()
                .background(isActive ? AppTheme.primaryButtonBackground : AppTheme.surfaceMuted)
                .overlay {
                    if !isActive {
                        Rectangle().stroke(AppTheme.border, lineWidth: 1)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(ModeButtonStyle(isActive: isActive))
        .accessibilityLabel(title)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .exact:
            if groups.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    emptyState(
                        title: L10n.string("No Duplicates"),
                        message: L10n.string(hasAuthorization
                            ? "No Duplicates Description"
                            : "No Skills in Scope Description")
                    )
                    ignoredGroupsSection(ignoredExactGroups, restore: onRestoreGroup)
                }
            } else if displayedExactGroups.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    emptyState(
                        title: L10n.string("No Matching Skills"),
                        message: L10n.string("No Matching Skills Description")
                    )
                    ignoredGroupsSection(ignoredExactGroups, restore: onRestoreGroup)
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
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
                        ignoredGroupsSection(ignoredExactGroups, restore: onRestoreGroup)
                    }
                    .padding(16)
                }
            }
        case .near:
            if nearGroups.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    emptyState(
                        title: L10n.string("No Near Duplicates"),
                        message: L10n.string(hasAuthorization
                            ? "No Near Duplicates Description"
                            : "No Skills in Scope Description")
                    )
                    ignoredGroupsSection(ignoredNearGroups, restore: onRestoreNearGroup)
                }
            } else if displayedNearGroups.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    emptyState(
                        title: L10n.string("No Matching Skills"),
                        message: L10n.string("No Matching Skills Description")
                    )
                    ignoredGroupsSection(ignoredNearGroups, restore: onRestoreNearGroup)
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
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
                                onLoadDiffs: onLoadNearDiffs,
                                onSelect: onSelect
                            )
                        }
                        ignoredGroupsSection(ignoredNearGroups, restore: onRestoreNearGroup)
                    }
                    .padding(16)
                }
            }
        }
    }

    /// Rows for ignored groups, each with a restore action. Hidden entirely
    /// when nothing is ignored.
    @ViewBuilder
    private func ignoredGroupsSection(
        _ groups: [IgnoredDuplicateGroup],
        restore: ((String) -> Void)?
    ) -> some View {
        if !groups.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: L10n.string("Ignored Groups"))
                    .font(AppTheme.body(11, weight: .semibold))
                    .kerning(0.2)
                    .foregroundStyle(AppTheme.muted)
                    .padding(.horizontal, 10)
                    .padding(.top, 10)
                ForEach(groups) { group in
                    HStack(spacing: 8) {
                        Image(systemName: "eye.slash")
                            .font(.system(size: 12))
                            .foregroundStyle(AppTheme.muted)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(verbatim: group.displayName)
                                .font(AppTheme.body(13))
                                .foregroundStyle(AppTheme.foreground)
                                .lineLimit(1)
                            Text(verbatim: String.localizedStringWithFormat(
                                L10n.string("Duplicate Members Count"),
                                group.members.count
                            ))
                            .font(AppTheme.body(11))
                            .foregroundStyle(AppTheme.muted)
                        }
                        Spacer(minLength: 8)
                        if let restore {
                            Button {
                                restore(group.fingerprint)
                            } label: {
                                Label(L10n.string("Restore"), systemImage: "arrow.up.circle")
                                    .font(AppTheme.body(11, weight: .medium))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(AppTheme.foregroundSecondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(AppTheme.surfaceMuted)
                            .overlay(Rectangle().stroke(AppTheme.border, lineWidth: 1))
                            .help(L10n.string("Restore Ignored Group"))
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppTheme.surface)
                    .overlay(Rectangle().stroke(AppTheme.border, lineWidth: 1))
                }
            }
            .padding(.top, 6)
        }
    }

    private func presentCompare(_ members: [SkillSnapshot]) {
        guard members.count > 1 else { return }
        compareRequest = DuplicateCompareRequest(members: members)
    }

    private func emptyState(title: String, message: String) -> some View {
        EmptyState(
            icon: "doc.on.doc",
            title: title,
            message: message
        )
    }
}

/// Shared header row for one group: icon, group name/meta, and the
/// compare / ignore tool buttons.
private struct GroupHeaderActions: View {
    let groupName: String
    let meta: String
    let icon: String
    let iconColor: Color
    let ignoreHelp: String
    let onIgnore: () -> Void
    let onCompare: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(iconColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: groupName)
                    .font(AppTheme.body(13, weight: .bold))
                    .foregroundStyle(AppTheme.foreground)
                    .lineLimit(1)
                Text(verbatim: meta)
                    .font(AppTheme.body(11))
                    .foregroundStyle(AppTheme.foregroundSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            GroupHeaderToolButton(
                title: L10n.string("Compare"),
                icon: "rectangle.split.2x1",
                help: L10n.string("Compare Duplicate Group"),
                action: onCompare
            )
            GroupHeaderToolButton(
                title: L10n.string("Ignore"),
                icon: "eye.slash",
                help: ignoreHelp,
                action: onIgnore
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

/// duplicates.html's `.tool-btn` at group level: 30 pt, muted surface,
/// hairline border, hard shadow, hover lift / press sink.
private struct GroupHeaderToolButton: View {
    let title: String
    let icon: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                Text(verbatim: title)
            }
            .font(AppTheme.body(11, weight: .bold))
            .foregroundStyle(AppTheme.foreground)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(AppTheme.surfaceMuted)
            .overlay(Rectangle().stroke(AppTheme.border, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(ToolPressButtonStyle())
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Hover lift / press sink shared by the duplicates page's bordered
/// buttons (duplicates.html's shared transition rules).
struct ToolPressButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .hardShadow(.rest, isActive: !configuration.isPressed)
            .offset(
                x: configuration.isPressed ? 1 : (isHovering ? -1 : 0),
                y: configuration.isPressed ? 1 : (isHovering ? -1 : 0)
            )
            .onHover { isHovering = $0 }
    }
}

/// The duplicates page's mode-switch buttons (30 pt; active one inverts).
private struct ModeButtonStyle: ButtonStyle {
    let isActive: Bool
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .hardShadow(.rest, isActive: !isActive && !configuration.isPressed)
            .offset(
                x: configuration.isPressed ? 1 : (isHovering && !isActive ? -1 : 0),
                y: configuration.isPressed ? 1 : (isHovering && !isActive ? -1 : 0)
            )
            .onHover { isHovering = $0 }
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
        // duplicates.html `.dup-group`: one bordered panel card with the
        // header, then member rows separated by white hairlines.
        VStack(alignment: .leading, spacing: 0) {
            GroupHeaderActions(
                groupName: groupName,
                meta: String.localizedStringWithFormat(
                    L10n.string("Duplicate Members Count"), group.members.count
                ),
                icon: "doc.on.doc.fill",
                iconColor: AppTheme.success,
                ignoreHelp: L10n.string("Ignore Duplicate Group"),
                onIgnore: { onIgnoreGroup?(group.fingerprint) },
                onCompare: onCompare
            )
            VStack(spacing: 0) {
                ForEach(Array(group.members.enumerated()), id: \.element) { index, skill in
                    DupMemberRow(
                        skill: skill,
                        agentNamesByID: agentNamesByID,
                        isActive: selection?.path == skill.path,
                        highlightQuery: highlightQuery,
                        badge: copyBadge(index),
                        badgeHelp: nil,
                        onSelect: { onSelect(skill.path) },
                        onRevealInFinder: onRevealInFinder,
                        onOpenInEditor: onOpenInEditor
                    )
                }
            }
        }
        .background(AppTheme.surface)
        .overlay(Rectangle().stroke(AppTheme.border, lineWidth: 1))
        .hardShadow(.rest)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var groupName: String {
        group.members.map(\.name).min() ?? group.fingerprint
    }

    /// 副本 A/B/C — the design's dashed copy tag distinguishes the
    /// identical members the list groups together.
    private func copyBadge(_ index: Int) -> String {
        let letter = Character(UnicodeScalar(65 + min(index, 25)) ?? "?")
        return String.localizedStringWithFormat(L10n.string("Copy %@ Badge"), String(letter))
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
    /// Loads per-member body line differences relative to the group's
    /// highest-similarity baseline; rendered as "+N −M lines" badges.
    var onLoadDiffs: ((NearDuplicateSkillGroup) async -> [String: LineDiffSummary])?
    let onSelect: (String) -> Void

    @State private var diffs: [String: LineDiffSummary] = [:]
    @State private var hasLoadedDiffs = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            GroupHeaderActions(
                groupName: groupName,
                meta: groupMeta,
                icon: "doc.on.doc",
                iconColor: AppTheme.accentInk,
                ignoreHelp: L10n.string("Ignore Near Duplicate Group"),
                onIgnore: { onIgnoreGroup?(group) },
                onCompare: onCompare
            )
            VStack(spacing: 0) {
                ForEach(group.members) { member in
                    DupMemberRow(
                        skill: member.snapshot,
                        agentNamesByID: agentNamesByID,
                        isActive: selection?.path == member.snapshot.path,
                        highlightQuery: highlightQuery,
                        badge: "≈\(member.similarityPercent)%",
                        badgeHelp: L10n.string("Similarity Estimate Help"),
                        trailingBadge: diffSummaryText(member),
                        onSelect: { onSelect(member.snapshot.path) },
                        onRevealInFinder: onRevealInFinder,
                        onOpenInEditor: onOpenInEditor
                    )
                }
            }
        }
        .background(AppTheme.surface)
        .overlay(Rectangle().stroke(AppTheme.border, lineWidth: 1))
        .hardShadow(.rest)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: group.fingerprint) {
            guard let onLoadDiffs, !hasLoadedDiffs else { return }
            diffs = await onLoadDiffs(group)
            hasLoadedDiffs = true
        }
    }

    private var groupName: String {
        group.members.map(\.snapshot.name).min() ?? group.fingerprint
    }

    private var groupMeta: String {
        let count = String.localizedStringWithFormat(
            L10n.string("Near Members Count"), group.members.count
        )
        guard !similarityRangeLabel.isEmpty else { return count }
        return "\(count) · \(similarityRangeLabel)"
    }

    private func diffSummaryText(_ member: NearDuplicateMember) -> String? {
        diffs[member.snapshot.path].map { "+\($0.added) −\($0.removed)" }
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

/// One duplicates.html `.dup-row`: avatar, name + description, the dashed
/// copy/similarity tag, and agent chips — flat rows over white hairlines,
/// selected with the muted fill and a 2 px accent bar on the leading edge.
private struct DupMemberRow: View {
    let skill: SkillSnapshot
    let agentNamesByID: [String: String]
    let isActive: Bool
    var highlightQuery: String = ""
    /// The dashed tag before the chips: 副本 A/B or the similarity percent.
    var badge: String? = nil
    var badgeHelp: String? = nil
    /// A second dashed tag after the chips (the near-mode diff counts).
    var trailingBadge: String? = nil
    var onSelect: (() -> Void)?
    var onRevealInFinder: ((SkillSnapshot) -> Void)?
    var onOpenInEditor: ((SkillSnapshot) -> Void)?

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 12) {
            SkillTileView(
                title: skillTileLetter(for: skill.name),
                size: 32,
                active: isActive
            )
            VStack(alignment: .leading, spacing: 2) {
                HighlightedText(
                    text: skill.name,
                    query: highlightQuery,
                    font: AppTheme.body(13, weight: .bold),
                    baseColor: AppTheme.foreground
                )
                .lineLimit(1)
                if let localDescription = skill.localDescription {
                    HighlightedText(
                        text: localDescription,
                        query: highlightQuery,
                        font: AppTheme.body(12),
                        baseColor: AppTheme.foregroundSecondary
                    )
                    .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let badge {
                dashedTag(badge)
                    .help(badgeHelp ?? badge)
            }
            ForEach(skill.agentIDs.prefix(3), id: \.self) { agentID in
                if let name = agentNamesByID[agentID] {
                    AgentChip(text: name, onActiveRow: isActive)
                }
            }
            if let trailingBadge {
                dashedTag(trailingBadge)
                    .help(L10n.string("Diff Lines Help"))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minHeight: 56, alignment: .center)
        .background {
            if isActive || isHovering {
                AppTheme.surfaceMuted
            }
        }
        .overlay(alignment: .leading) {
            if isActive {
                Rectangle()
                    .fill(AppTheme.accent)
                    .frame(width: 2)
            }
        }
        .overlay(alignment: .top) {
            Rectangle()
                .fill(AppTheme.border)
                .frame(height: 1)
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture {
            onSelect?()
        }
        .contextMenu {
            Button {
                onRevealInFinder?(skill)
            } label: {
                Label(L10n.string("Reveal in Finder"), systemImage: "folder")
            }
            Button {
                onOpenInEditor?(skill)
            } label: {
                Label(L10n.string("Open in Default Editor"), systemImage: "chevron.left.forwardslash.chevron.right")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    /// `.copy-badge`: mono 10 pt, dashed hairline, secondary text.
    private func dashedTag(_ text: String) -> some View {
        Text(verbatim: text)
            .font(AppTheme.mono(10))
            .foregroundStyle(AppTheme.foregroundSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay {
                Rectangle()
                    .stroke(AppTheme.border, style: StrokeStyle(lineWidth: 1, dash: [3]))
            }
    }
}
