import SkillSelectorCore
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var destination: BrowserDestination? = .all
    @State private var searchText = ""
    @State private var sort: SkillQuery.Sort = .default
    @State private var revealError: String?

    var body: some View {
        @Bindable var model = model
        let currentDestination = destination ?? .all
        let query = SkillQuery(
            scope: currentDestination.queryScope,
            agentID: currentDestination.agentID,
            searchText: searchText,
            sort: sort
        )
        let filteredSkills = query.apply(to: model.snapshots, rootsByID: model.rootsByID)
        let agentNamesByID = Dictionary(
            uniqueKeysWithValues: model.agentDefinitions.map { ($0.id, $0.displayName) }
        )
        let detectedAgentIDs = BrowserSidebar.detectedAgentIDs(
            from: model.snapshots,
            hasAuthorization: model.hasAuthorization
        )
        let selectedSkill = model.selection.flatMap { selection in
            model.snapshots.first { $0.path == selection.path }
        }

        NavigationSplitView {

            BrowserSidebar(
                destination: $destination,
                roots: model.authorizedRoots,
                definitions: model.agentDefinitions,
                detectedAgentIDs: detectedAgentIDs,
                onDrop: { payload, rootURL in
                    guard let skill = model.snapshots.first(where: { $0.path == payload.path }) else { return }
                    Task { await model.planFileOperation(.move, for: skill, destinationRootURL: rootURL) }
                }
            )
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 260)
        } content: {
            SkillListView(
                selection: $model.selection,
                searchText: $searchText,
                sort: $sort,
                skills: filteredSkills,
                allSkillCount: model.snapshots.count,
                hasAuthorization: model.hasAuthorization,
                hasActiveFilters: hasActiveFilters,
                showFolderGroups: currentDestination.showsFolderGroups,
                refreshState: model.refreshState,
                agentNamesByID: agentNamesByID,
                onRefresh: refresh,
                onClearFilters: clearFilters,
                onOperation: { operation, skill in
                    if operation == .delete {
                        Task { await model.planFileOperation(operation, for: skill) }
                    } else {
                        chooseDestination(for: operation, skill: skill)
                    }
                },
                onRevealInFinder: { skill in
                    do {
                        try model.revealDocumentInFinder(for: skill)
                    } catch {
                        revealError = (error as? LocalizedError)?.errorDescription
                            ?? String(describing: error)
                    }
                }
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
        .languageReloading()
        .toolbar {
            ToolbarItemGroup {
                SettingsLink {
                    Image(systemName: "gearshape")
                        .frame(width: 18, height: 18)
                }
                .help(L10n.string("Open Settings"))
                .accessibilityLabel(L10n.string("Open Settings"))
            }
        }
        .sheet(item: pendingOperationBinding) { plan in
            OperationConfirmationView(
                plan: plan,
                isOperating: model.isOperating,
                onConflictChange: model.updatePendingConflictPolicy,
                onCancel: model.cancelPendingFileOperation,
                onConfirm: { replacementConfirmed in
                    Task {
                        await model.executePendingFileOperation(
                            replacementConfirmed: replacementConfirmed
                        )
                    }
                }
            )
            .id(plan.id)
        }

        .alert(
            L10n.string("File Operation Failed"),
            isPresented: operationErrorBinding
        ) {
            Button(L10n.string("OK")) { model.operationError = nil }
        } message: {
            Text(verbatim: model.operationError ?? "")
        }

        .alert(
            L10n.string("Unable to Reveal in Finder"),
            isPresented: revealErrorBinding
        ) {
            Button(L10n.string("OK")) { revealError = nil }
        } message: {
            Text(verbatim: revealError ?? "")
        }

    }

    private var hasActiveFilters: Bool {
        destination != .all
            || !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func clearFilters() {
        destination = .all
        searchText = ""
    }

    private var pendingOperationBinding: Binding<FileOperationPlan?> {
        Binding(
            get: { model.pendingOperationPlan },
            set: { value in
                if value == nil { model.cancelPendingFileOperation() }
            }
        )
    }

    private var operationErrorBinding: Binding<Bool> {
        Binding(
            get: { model.operationError != nil },
            set: { isPresented in
                if !isPresented { model.operationError = nil }
            }
        )
    }

    private var revealErrorBinding: Binding<Bool> {
        Binding(
            get: { revealError != nil },
            set: { isPresented in
                if !isPresented { revealError = nil }
            }
        )
    }



    private func refresh() {
        Task { await model.refresh() }
    }

    private func chooseDestination(for operation: FileOperationKind, skill: SkillSnapshot) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.title = L10n.string("Choose Skill Root")
        panel.prompt = L10n.string("Choose Skill Root")
        panel.message = L10n.string("Choose a registered Skill root")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            await model.planFileOperation(
                operation,
                for: skill,
                destinationRootURL: url,
                conflictPolicy: .keepBoth
            )
        }
    }
}
