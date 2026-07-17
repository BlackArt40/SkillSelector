import SkillSelectorCore
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var destination: BrowserDestination? = .all
    @State private var searchText = ""
    @State private var status: SkillQuery.Status = .all
    @State private var sort: SkillQuery.Sort = .default

    var body: some View {
        @Bindable var model = model
        let currentDestination = destination ?? .all
        let query = SkillQuery(
            scope: currentDestination.queryScope,
            agentID: currentDestination.agentID,
            searchText: searchText,
            status: status,
            sort: sort
        )
        let filteredSkills = query.apply(to: model.snapshots, rootsByID: model.rootsByID)
        let agentNamesByID = Dictionary(
            uniqueKeysWithValues: model.agentDefinitions.map { ($0.id, $0.displayName) }
        )
        let detectedAgentIDs = Set(model.snapshots.flatMap(\.agentIDs))
        let selectedSkill = model.selection.flatMap { selection in
            model.snapshots.first { $0.path == selection.path }
        }

        NavigationSplitView {
            BrowserSidebar(
                destination: $destination,
                roots: model.authorizedRoots,
                definitions: model.agentDefinitions,
                detectedAgentIDs: detectedAgentIDs
            )
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 260)
        } content: {
            SkillListView(
                selection: $model.selection,
                searchText: $searchText,
                status: $status,
                sort: $sort,
                skills: filteredSkills,
                allSkillCount: model.snapshots.count,
                hasAuthorization: model.hasAuthorization,
                hasActiveFilters: hasActiveFilters,
                refreshState: model.refreshState,
                agentNamesByID: agentNamesByID,
                onRefresh: refresh,
                onClearFilters: clearFilters
            )
            .navigationSplitViewColumnWidth(min: 280, ideal: 330, max: 380)
        } detail: {
            SkillDetailView(
                skill: selectedSkill,
                rootsByID: model.rootsByID,
                agentNamesByID: agentNamesByID
            )
            .frame(minWidth: 420)
        }
        .toolbar {
            ToolbarItemGroup {
                Button(action: refresh) {
                    Group {
                        if model.refreshState == .running {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .frame(width: 18, height: 18)
                }
                .disabled(model.refreshState == .running)
                .help(model.refreshState == .running
                    ? L10n.string("Refreshing Skills")
                    : L10n.string("Refresh Skills"))
                .accessibilityLabel(model.refreshState == .running
                    ? L10n.string("Refreshing Skills")
                    : L10n.string("Refresh Skills"))

                SettingsLink {
                    Image(systemName: "gearshape")
                        .frame(width: 18, height: 18)
                }
                .help(L10n.string("Open Settings"))
                .accessibilityLabel(L10n.string("Open Settings"))
            }
        }
    }

    private var hasActiveFilters: Bool {
        destination != .all
            || !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || status != .all
    }

    private func refresh() {
        Task { await model.refresh(.manual) }
    }

    private func clearFilters() {
        destination = .all
        searchText = ""
        status = .all
    }
}
