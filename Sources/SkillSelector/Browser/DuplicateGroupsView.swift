import SkillSelectorCore
import SwiftUI

/// The middle column for the duplicates destination: content-identical
/// installations grouped under one header. Selecting a member keeps the
/// normal detail pane; every member is still its own record.
struct DuplicateGroupsView: View {
    let groups: [DuplicateSkillGroup]
    let selection: SkillSelection?
    let agentNamesByID: [String: String]
    let hasAuthorization: Bool
    var onRevealInFinder: ((SkillSnapshot) -> Void)?
    var onOpenInEditor: ((SkillSnapshot) -> Void)?
    /// Marks the whole group (by fingerprint) as ignored, hiding it.
    var onIgnoreGroup: ((String) -> Void)?
    let onSelect: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle()
                .fill(AppTheme.borderSoft)
                .frame(height: 1)
            content
        }
        .background(AppTheme.background)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle(L10n.string("Duplicate Skills"))
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(verbatim: L10n.string("Duplicate Skills"))
                .font(AppTheme.display(17, weight: .semibold))
                .foregroundStyle(AppTheme.foreground)
                .lineLimit(1)
            Text(verbatim: String.localizedStringWithFormat(
                L10n.string("Duplicate Groups Count"), groups.count
            ))
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
        if groups.isEmpty {
            VStack(spacing: 8) {
                Spacer(minLength: 48)
                Text(verbatim: L10n.string("No Duplicates"))
                    .font(AppTheme.display(17, weight: .semibold))
                    .foregroundStyle(AppTheme.foreground)
                Text(verbatim: L10n.string(hasAuthorization
                    ? "No Duplicates Description"
                    : "No Skills in Scope Description"))
                    .font(AppTheme.body(13))
                    .foregroundStyle(AppTheme.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 24)
                Spacer(minLength: 48)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(groups) { group in
                        DuplicateGroupSection(
                            group: group,
                            selection: selection,
                            agentNamesByID: agentNamesByID,
                            onRevealInFinder: onRevealInFinder,
                            onOpenInEditor: onOpenInEditor,
                            onIgnoreGroup: onIgnoreGroup,
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

private struct DuplicateGroupSection: View {
    let group: DuplicateSkillGroup
    let selection: SkillSelection?
    let agentNamesByID: [String: String]
    var onRevealInFinder: ((SkillSnapshot) -> Void)?
    var onOpenInEditor: ((SkillSnapshot) -> Void)?
    var onIgnoreGroup: ((String) -> Void)?
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "doc.on.doc.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(AppTheme.meta)
                Text(verbatim: groupName)
                    .font(AppTheme.body(12, weight: .semibold))
                    .foregroundStyle(AppTheme.muted)
                Text(verbatim: String.localizedStringWithFormat(
                    L10n.string("Duplicate Members Count"), group.members.count
                ))
                .font(AppTheme.body(11))
                .foregroundStyle(AppTheme.meta)
                Spacer(minLength: 8)
                Button {
                    onIgnoreGroup?(group.fingerprint)
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
                .help(L10n.string("Ignore Duplicate Group"))
            }
            .padding(.horizontal, 8)
            .padding(.top, 4)

            VStack(spacing: 2) {
                ForEach(group.members) { skill in
                    SkillRow(
                        skill: skill,
                        agentNamesByID: agentNamesByID,
                        isActive: selection?.path == skill.path,
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
