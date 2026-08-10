import SkillSelectorCore
import SwiftUI

struct SkillListView: View {
    @Binding var selection: SkillSelection?
    @Binding var searchText: String
    @Binding var status: SkillQuery.Status
    @Binding var sort: SkillQuery.Sort

    let skills: [SkillSnapshot]
    let allSkillCount: Int
    let hasAuthorization: Bool
    let hasActiveFilters: Bool
    let showFolderGroups: Bool
    let refreshState: RefreshState
    let agentNamesByID: [String: String]
    let onRefresh: () -> Void
    let onClearFilters: () -> Void
    var onOperation: ((FileOperationKind, SkillSnapshot) -> Void)?
    var onRevealInFinder: ((SkillSnapshot) -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle(L10n.string("Skills"))
        .searchable(
            text: $searchText,
            placement: .toolbar,
            prompt: L10n.string("Search Skills")
        )
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Picker(L10n.string("Status"), selection: $status) {
                Text(verbatim: L10n.string("All")).tag(SkillQuery.Status.all)
                Text(verbatim: L10n.string("Available")).tag(SkillQuery.Status.available)
                Text(verbatim: L10n.string("Unavailable")).tag(SkillQuery.Status.unavailable)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel(L10n.string("Filter by status"))

            Menu {
                Picker(L10n.string("Sort"), selection: $sort) {
                    Text(verbatim: L10n.string("Default Order")).tag(SkillQuery.Sort.default)
                    Text(verbatim: L10n.string("Name")).tag(SkillQuery.Sort.name)
                    Text(verbatim: L10n.string("Path")).tag(SkillQuery.Sort.path)
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .frame(width: 18, height: 18)
            }
            .menuStyle(.borderlessButton)
            .help(L10n.string("Sort Skills"))
            .accessibilityLabel(L10n.string("Sort Skills"))
        }
        .padding(.horizontal, 10)
        .frame(height: 42)
    }

    @ViewBuilder
    private var content: some View {
        if skills.isEmpty {
            emptyState
        } else if showFolderGroups {
            List(selection: $selection) {
                ForEach(folderGroups) { group in
                    DisclosureGroup {
                        ForEach(group.skills) { skill in
                            skillRow(skill)
                        }
                    } label: {
                        HStack {
                            Image(systemName: "folder")
                            Text(verbatim: group.name)
                            Spacer()
                            Text(verbatim: String.localizedStringWithFormat(
                                L10n.string("%d Skills"), group.skills.count
                            ))
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }
                    }
                }
            }
            .listStyle(.inset)
        } else {
            List(skills, selection: $selection) { skill in
                skillRow(skill)
            }
            .listStyle(.inset)
        }
    }

    private func skillRow(_ skill: SkillSnapshot) -> some View {
        SkillRow(
            skill: skill,
            agentNamesByID: agentNamesByID,
            onOperation: onOperation,
            onRevealInFinder: onRevealInFinder
        )
        .tag(SkillSelection(path: skill.path))
    }

    // Recomputed on every SwiftUI body pass. Fine for typical skill counts;
    // cache with @State or onChange if profiling shows a bottleneck.
    private var folderGroups: [SkillFolderGroup] {
        let grouped = Dictionary(grouping: skills) { skill in
            Self.skillFolderName(for: skill.path)
        }
        return grouped.map { folderName, folderSkills in
            SkillFolderGroup(
                name: folderName,
                skills: folderSkills.sorted {
                    $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
            )
        }.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    private static let skillsDirName = "skills"

    private static func skillFolderName(for skillPath: String) -> String {
        let components = URL(fileURLWithPath: skillPath).pathComponents
        for (index, component) in components.enumerated() {
            if component == skillsDirName, index + 1 < components.count {
                return components[index + 1]
            }
        }
        return URL(fileURLWithPath: skillPath).deletingLastPathComponent().lastPathComponent
    }

    @ViewBuilder
    private var emptyState: some View {
        if case .failed(let message) = refreshState {
            ContentUnavailableView {
                Label(L10n.string("Refresh Failed"), systemImage: "exclamationmark.triangle")
            } description: {
                Text(verbatim: message)
            }
        } else if !hasAuthorization {
            ContentUnavailableView {
                Label(L10n.string("Authorize Skill Folders"), systemImage: "folder.badge.questionmark")
            } description: {
                Text(verbatim: L10n.string("Authorize your home directory or add a project to find local Skills."))
            } actions: {
                AuthorizationViews(showsHeading: false)
                    .frame(width: 230)
            }
        } else if allSkillCount == 0 {
            ContentUnavailableView {
                Label(L10n.string("No Skills Indexed"), systemImage: "tray")
            } description: {
                Text(verbatim: L10n.string("Refresh the authorized folders or add another project."))
            } actions: {
                VStack(spacing: 8) {
                    Button(L10n.string("Refresh Skills"), action: onRefresh)
                    AuthorizationViews(showsHeading: false)
                        .frame(width: 230)
                }
            }
        } else if hasActiveFilters {
            ContentUnavailableView {
                Label(L10n.string("No Matching Skills"), systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text(verbatim: L10n.string("Change the search or filters to show more Skills."))
            } actions: {
                Button(L10n.string("Clear Filters"), action: onClearFilters)
            }
        }
    }
}

private struct SkillFolderGroup: Identifiable {
    let name: String
    let skills: [SkillSnapshot]
    var id: String { name }
}
