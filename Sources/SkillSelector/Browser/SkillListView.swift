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
    let refreshState: RefreshState
    let agentNamesByID: [String: String]
    let onRefresh: () -> Void
    let onClearFilters: () -> Void

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
        } else {
            List(skills, selection: $selection) { skill in
                SkillRow(skill: skill, agentNamesByID: agentNamesByID)
                    .tag(SkillSelection(path: skill.path))
            }
            .listStyle(.inset)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if case .failed(let message) = refreshState {
            ContentUnavailableView {
                Label(L10n.string("Refresh Failed"), systemImage: "exclamationmark.triangle")
            } description: {
                VStack(spacing: 4) {
                    Text(verbatim: L10n.string("Check folder access, then try refreshing again."))
                    Text(verbatim: message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } actions: {
                Button(L10n.string("Retry Refresh"), action: onRefresh)
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
        } else {
            ContentUnavailableView(
                L10n.string("No Skills Found"),
                systemImage: "tray",
                description: Text(verbatim: L10n.string("Refresh the authorized folders to check again."))
            )
        }
    }

}
