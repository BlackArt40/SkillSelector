import AppKit
import SkillSelectorCore
import SwiftUI

/// The main browser window, laid out as the design's three fixed columns
/// (240 / 400 / flexible) with a titlebar toolbar hosting search, sort and
/// the appearance toggle.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(ThemePreference.storageKey) private var themeMode = "system"
    @State private var destination: BrowserDestination?
    @State private var searchText = ""
    @State private var sort: SkillQuery.Sort = .default
    @State private var revealError: String?
    @FocusState private var searchFocused: Bool

    init(initialDestination: BrowserDestination = .all) {
        _destination = State(initialValue: initialDestination)
    }

    var body: some View {
        @Bindable var model = model
        let currentDestination = destination ?? .all
        let query = SkillQuery(
            scope: currentDestination.queryScope,
            agentID: currentDestination.agentID,
            searchText: searchText,
            sort: sort
        )
        let agentNamesByID = Dictionary(
            model.agentDefinitions.map { ($0.id, $0.displayName) },
            uniquingKeysWith: { first, _ in first }
        )
        let filteredSkills = query.apply(
            to: model.snapshots,
            rootsByID: model.rootsByID,
            agentNamesByID: agentNamesByID
        )
        let detectedAgentIDs = BrowserSidebar.detectedAgentIDs(
            from: model.snapshots,
            hasAuthorization: model.hasAuthorization
        )
        let selectedSkill = model.selection.flatMap { selection in
            model.snapshots.first { $0.path == selection.path }
        }

        HStack(spacing: 0) {
            BrowserSidebar(
                destination: $destination,
                roots: model.authorizedRoots,
                definitions: model.agentDefinitions,
                detectedAgentIDs: detectedAgentIDs,
                manuallyEnabledAgentIDs: model.manuallyEnabledAgentIDs,
                unhealthyRootIDs: model.unhealthyRootIDs,
                counts: sidebarCounts,
                onAddProject: { chooseDestinationRoot() },
                onDrop: { payload, rootURL in
                    guard let skill = model.snapshots.first(where: { $0.path == payload.path }) else { return }
                    Task { await model.planFileOperation(.move, for: skill, destinationRootURL: rootURL) }
                },
                onReauthorize: { root in reauthorize(root) },
                onRemoveRoot: { root in removeRoot(root) }
            )
            .frame(width: 240)

            if currentDestination == .duplicates {
                DuplicateGroupsView(
                    groups: model.duplicateGroups,
                    selection: model.selection,
                    agentNamesByID: agentNamesByID,
                    hasAuthorization: model.hasAuthorization,
                    onOperation: { operation, skill in
                        startOperation(operation, skill: skill)
                    },
                    onRevealInFinder: { skill in
                        do {
                            try model.revealDocumentInFinder(for: skill)
                        } catch {
                            revealError = (error as? LocalizedError)?.errorDescription
                                ?? String(describing: error)
                        }
                    },
                    onSelect: { path in model.selectOnly(path) }
                )
                .frame(width: 400)
            } else {
                SkillListView(
                    selection: model.selection,
                    selectedPaths: model.selectedPaths,
                    searchText: $searchText,
                    sort: $sort,
                    title: currentDestination.title(rootsByID: model.rootsByID, definitions: model.agentDefinitions),
                    skills: filteredSkills,
                    allSkillCount: model.snapshots.count,
                    hasAuthorization: model.hasAuthorization,
                    hasActiveFilters: hasActiveFilters,
                    refreshState: model.refreshState,
                    agentNamesByID: agentNamesByID,
                    onClearFilters: clearFilters,
                    onImportProject: { chooseDestinationRoot() },
                    onImportHome: { chooseSystemRoot() },
                    onOperation: { operation, skill in
                        startOperation(operation, skill: skill)
                    },
                    onRevealInFinder: { skill in
                        do {
                            try model.revealDocumentInFinder(for: skill)
                        } catch {
                            revealError = (error as? LocalizedError)?.errorDescription
                                ?? String(describing: error)
                        }
                    },
                    onPrimarySelect: { path in model.selectOnly(path) },
                    onToggleSelect: { path in model.toggleSelection(path) },
                    onRangeSelect: { path in
                        model.selectRange(to: path, in: filteredSkills.map(\.path))
                    },
                    onClearSelection: { model.selectOnly(model.selection?.path) }
                )
                .frame(width: 400)
            }

            SkillDetailView(
                skill: selectedSkill,
                rootsByID: model.rootsByID,
                agentNamesByID: agentNamesByID,
                onOperation: { operation, skill in
                    startOperation(operation, skill: skill)
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 1080, minHeight: 700)
        .navigationTitle(currentDestination.title(rootsByID: model.rootsByID, definitions: model.agentDefinitions))
        .background {
            // Hidden ⌘F trigger: focuses the search field from anywhere in
            // the window without cross-scene focus plumbing.
            Button(L10n.string("Search Skills")) {
                searchFocused = true
            }
            .keyboardShortcut("f", modifiers: .command)
            .opacity(0)
            .accessibilityHidden(true)
        }
        .languageReloading()
        .themedAppearance()
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                searchField
                themeToggle
            }
        }
        .sheet(isPresented: onboardingBinding) {
            OnboardingView()
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

        .sheet(item: pendingBatchBinding) { batch in
            BatchOperationConfirmationView(
                batch: batch,
                isOperating: model.isOperating,
                onCancel: model.cancelPendingBatchOperation,
                onConfirm: {
                    Task {
                        await model.executePendingBatchOperation()
                        model.selectOnly(nil)
                    }
                }
            )
            .id(batch.id)
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

    // MARK: Toolbar

    /// `.search`: 240×30 rounded field with surface background.
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(AppTheme.meta)
            TextField(L10n.string("Search Skills"), text: $searchText)
                .textFieldStyle(.plain)
                .font(AppTheme.body(13))
                .focused($searchFocused)
        }
        .padding(.horizontal, 10)
        .frame(width: 240, height: 30)
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(searchFocused ? AppTheme.accent : AppTheme.borderSoft, lineWidth: 1)
        }
        .accessibilityLabel(L10n.string("Search Skills"))
        .help(L10n.string("Search Help"))
    }

    /// `.themeBtn`: moon in light mode, sun in dark mode; toggles between
    /// the two like the HTML prototype's `ss.theme` flip.
    private var themeToggle: some View {
        Button {
            let dark = ThemePreference.effectiveDark(mode: themeMode)
            themeMode = dark ? "light" : "dark"
        } label: {
            Image(systemName: ThemePreference.effectiveDark(mode: themeMode) ? "sun.max" : "moon")
                .font(.system(size: 14))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(
            ThemePreference.effectiveDark(mode: themeMode)
                ? L10n.string("Switch to Light Mode")
                : L10n.string("Switch to Dark Mode")
        )
        .accessibilityLabel(
            ThemePreference.effectiveDark(mode: themeMode)
                ? L10n.string("Switch to Light Mode")
                : L10n.string("Switch to Dark Mode")
        )
    }

    // MARK: Derived state

    private var hasActiveFilters: Bool {
        destination != .all
            || !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var sidebarCounts: [BrowserDestination: Int] {
        var counts: [BrowserDestination: Int] = [:]
        counts[.all] = model.snapshots.count
        counts[.global] = SkillQuery(scope: .global).apply(to: model.snapshots, rootsByID: model.rootsByID).count
        counts[.duplicates] = DuplicateSkillGrouper.memberCount(in: model.duplicateGroups)
        for root in model.authorizedRoots {
            switch root.kind {
            case .home, .system:
                counts[.system(rootID: root.id)] = SkillQuery(scope: .root(rootID: root.id))
                    .apply(to: model.snapshots, rootsByID: model.rootsByID).count
            case .project, .custom:
                counts[.project(rootID: root.id)] = SkillQuery(scope: .project(rootID: root.id))
                    .apply(to: model.snapshots, rootsByID: model.rootsByID).count
            }
        }
        for definition in model.agentDefinitions {
            counts[.agent(id: definition.id)] = SkillQuery(scope: .all, agentID: definition.id)
                .apply(to: model.snapshots, rootsByID: model.rootsByID).count
        }
        return counts
    }

    private func clearFilters() {
        destination = .all
        searchText = ""
    }

    // MARK: Bindings

    private var onboardingBinding: Binding<Bool> {
        Binding(
            get: { model.showsOnboarding },
            set: { presented in
                if !presented { model.dismissOnboarding() }
            }
        )
    }

    private var pendingOperationBinding: Binding<FileOperationPlan?> {
        Binding(
            get: { model.pendingOperationPlan },
            set: { value in
                if value == nil { model.cancelPendingFileOperation() }
            }
        )
    }

    private var pendingBatchBinding: Binding<PendingBatchOperation?> {
        Binding(
            get: { model.pendingBatchOperation },
            set: { value in
                if value == nil { model.cancelPendingBatchOperation() }
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

    // MARK: Import / operations

    /// Routes a context-menu operation: when the tapped row belongs to a
    /// multi-selection, the operation runs as a batch over every selected
    /// Skill; otherwise it is the ordinary single-Skill flow.
    private func startOperation(_ operation: FileOperationKind, skill: SkillSnapshot) {
        let skills = batchTargets(containing: skill, operation: operation)
        if skills.count > 1 {
            if operation == .delete {
                Task { await model.planBatchFileOperation(operation, for: skills) }
            } else {
                chooseBatchDestination(for: operation, skills: skills)
            }
            return
        }
        if operation == .delete {
            Task { await model.planFileOperation(operation, for: skill) }
        } else {
            chooseDestination(for: operation, skill: skill)
        }
    }

    private func batchTargets(
        containing skill: SkillSnapshot,
        operation: FileOperationKind
    ) -> [SkillSnapshot] {
        guard operation == .copy || operation == .move || operation == .delete,
              model.hasMultiSelection,
              model.selectedPaths.contains(skill.path) else {
            return [skill]
        }
        return model.multiSelectedSkills
    }

    private func reauthorize(_ root: AuthorizedRootSnapshot) {
        let panel = NSOpenPanel()
        panel.title = L10n.string("Re-authorize Directory")
        panel.prompt = L10n.string("Authorize")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = root.url
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.authorize(url, as: root.kind) }
    }

    /// Sidebar context-menu removal: revoke the root's authorization and,
    /// when the removed root is the one being browsed, fall back to the
    /// All Skills list instead of an empty column titled by a dead root.
    private func removeRoot(_ root: AuthorizedRootSnapshot) {
        destination = BrowserDestination.fallback(afterRemoving: root.id, from: destination ?? .all)
        Task { await model.revokeAuthorization(id: root.id) }
    }

    private func chooseDestinationRoot() {
        guard let url = chooseDirectory(
            title: L10n.string("Import Project Directory"),
            message: L10n.string("Choose a project directory to scan for all Skills.")
        ) else { return }
        Task { await model.authorize(url, as: .project) }
    }

    private func chooseSystemRoot() {
        guard let url = chooseDirectory(
            title: L10n.string("Import System Directory"),
            message: L10n.string("Choose a home directory containing Agent Skills (e.g. ~/.claude, ~/.codex).")
        ) else { return }
        Task { await model.authorize(url, as: .home) }
    }

    private func chooseDirectory(title: String, message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.message = message
        panel.prompt = L10n.string("Import")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        return panel.runModal() == .OK ? panel.url?.standardizedFileURL : nil
    }

    private func chooseBatchDestination(for operation: FileOperationKind, skills: [SkillSnapshot]) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        // Any user-picked folder is a valid batch copy/move target — no
        // registered Skill root required.
        panel.title = L10n.string("Choose a destination folder")
        panel.prompt = operation == .copy
            ? L10n.string("Copy To Current Folder")
            : L10n.string("Move To Current Folder")
        panel.message = L10n.string("Choose a destination folder")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            await model.planBatchFileOperation(
                operation,
                for: skills,
                destinationRootURL: url,
                destinationIsArbitrary: true
            )
        }
    }

    private func chooseDestination(for operation: FileOperationKind, skill: SkillSnapshot) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        if operation == .copy || operation == .move {
            // Any user-picked folder is a valid copy/move target — no
            // registered Skill root required.
            panel.title = L10n.string("Choose a destination folder")
            panel.prompt = operation == .copy
                ? L10n.string("Copy To Current Folder")
                : L10n.string("Move To Current Folder")
            panel.message = L10n.string("Choose a destination folder")
        } else {
            panel.title = L10n.string("Choose Skill Root")
            panel.prompt = L10n.string("Choose Skill Root")
            panel.message = L10n.string("Choose a registered Skill root")
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            await model.planFileOperation(
                operation,
                for: skill,
                destinationRootURL: url,
                conflictPolicy: .keepBoth,
                destinationIsArbitrary: operation == .copy || operation == .move
            )
        }
    }
}

extension BrowserDestination {
    /// The column title for the current destination ("全部 Skill",
    /// "全局 Skill", the root label, or the agent name).
    func title(rootsByID: [String: AuthorizedRootSnapshot], definitions: [AgentDefinition]) -> String {
        switch self {
        case .all: L10n.string("All Skills")
        case .global: L10n.string("Global Skills")
        case .duplicates: L10n.string("Duplicate Skills")
        case .system(let rootID), .project(let rootID):
            rootsByID[rootID]?.displayName ?? rootID
        case .agent(let id):
            definitions.first { $0.id == id }?.displayName ?? id
        }
    }
}
