import AppKit
import SkillSelectorCore
import SwiftUI

/// The main browser window, laid out as the design's three fixed columns
/// (240 / 400 / flexible) with a titlebar toolbar hosting back/forward,
/// search and the appearance toggle.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(ThemePreference.storageKey) private var themeMode = "system"
    @State private var destination: BrowserDestination
    @State private var searchText = ""
    @State private var sort: SkillQuery.Sort = .default
    @State private var openError: String?
    @FocusState private var searchFocused: Bool
    /// Suppresses history recording while a back/forward navigation is
    /// restoring state — the restore is not a new action.
    @State private var suppressingHistory = false
    /// Seeds the history stack bottom once with the initial destination.
    @State private var didSeedHistory = false
    /// Selected MCP server id for the MCP detail pane.
    @State private var mcpSelection: String?
    /// True while a probe-all pass is in flight (drives list progress).
    @State private var mcpProbingAll = false

    init(initialDestination: BrowserDestination = .all) {
        _destination = State(initialValue: initialDestination)
    }

    var body: some View {
        @Bindable var model = model
        let currentDestination = destination
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
        ).union(BrowserSidebar.mcpAgentIDs(from: model.mcpServers))
        let selectedSkill = model.selection.flatMap { selection in
            model.snapshots.first { $0.path == selection.path }
        }
        let symlinkSkills = model.snapshots.filter { $0.resolvedTarget != nil }

        VStack(spacing: 0) {
            if !model.unhealthyRootIDs.isEmpty {
                authorizationBanner
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
                        onRevealInFinder: { skill in reveal(skill) },
                        onOpenInEditor: { skill in openInEditor(skill) },
                        onIgnoreGroup: { fingerprint in
                            _ = try? model.setDuplicateGroupIgnored(fingerprint: fingerprint, ignored: true)
                        },
                        onSelect: { path in selectSkill(path) }
                    )
                    .frame(width: 400)
                } else if currentDestination == .links {
                    SymlinkListView(
                        links: symlinkSkills,
                        selection: model.selection,
                        agentNamesByID: agentNamesByID,
                        onRevealInFinder: { skill in reveal(skill) },
                        onSelect: { path in selectSkill(path) }
                    )
                    .frame(width: 400)
                } else if currentDestination == .mcp {
                    McpListView(
                        servers: model.mcpServers,
                        statuses: model.mcpProbeStatuses,
                        selection: mcpSelection,
                        agentNamesByID: agentNamesByID,
                        isProbing: mcpProbingAll,
                        onSelect: { server in
                            mcpSelection = server.id
                            model.recordNavigation(.sidebar(.mcp))
                        },
                        onProbeAll: { probeAllMcp() },
                        onRevealConfig: { server in model.revealMcpConfigFile(server) }
                    )
                    .frame(width: 400)
                } else {
                    SkillListView(
                        selection: model.selection,
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
                        onRevealInFinder: { skill in reveal(skill) },
                        onOpenInEditor: { skill in openInEditor(skill) },
                        onPrimarySelect: { path in selectSkill(path) },
                        onArrowSelect: { path in model.selectOnly(path) }
                    )
                    .frame(width: 400)
                }

                if currentDestination == .mcp {
                    McpDetailView(
                        server: model.mcpServers.first { $0.id == mcpSelection },
                        status: mcpSelection.flatMap { id in model.mcpProbeStatuses[id] } ?? .unknown,
                        agentNamesByID: agentNamesByID,
                        onProbe: {
                            if let id = mcpSelection {
                                Task { await model.probeMcpServer(id: id) }
                            }
                        },
                        onRevealConfig: { server in model.revealMcpConfigFile(server) }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let agentID = currentDestination.agentID {
                    // Agent detail: Skill and MCP stacked vertically.
                    AgentDetailView(
                        skill: selectedSkill,
                        agentID: agentID,
                        rootsByID: model.rootsByID,
                        agentNamesByID: agentNamesByID,
                        mcpServers: model.mcpServers,
                        mcpStatuses: model.mcpProbeStatuses,
                        onRevealInFinder: { skill in reveal(skill) },
                        onOpenInEditor: { skill in openInEditor(skill) },
                        onSelectMcp: { server in
                            mcpSelection = server.id
                            destination = .mcp
                        },
                        onRevealConfig: { server in model.revealMcpConfigFile(server) },
                        onProbeAll: { probeAgentMcp(agentID: agentID) }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    SkillDetailView(
                        skill: selectedSkill,
                        rootsByID: model.rootsByID,
                        agentNamesByID: agentNamesByID,
                        onRevealInFinder: { skill in reveal(skill) },
                        onOpenInEditor: { skill in openInEditor(skill) }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
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
            // ⌘[ / ⌘] macOS-standard navigation shortcuts. Kept on hidden
            // buttons so they fire even when the toolbar buttons are
            // disabled at a stack edge.
            Button(L10n.string("Go Back")) {
                goBack()
            }
            .keyboardShortcut("[", modifiers: .command)
            .opacity(0)
            .accessibilityHidden(true)
            Button(L10n.string("Go Forward")) {
                goForward()
            }
            .keyboardShortcut("]", modifiers: .command)
            .opacity(0)
            .accessibilityHidden(true)
        }
        .onAppear {
            // The stack bottom is the launch default destination; seed it
            // once so back can traverse all the way to it.
            guard !didSeedHistory else { return }
            didSeedHistory = true
            model.recordNavigation(.sidebar(destination))
        }
        .onChange(of: destination) { _, newValue in
            guard !suppressingHistory else { return }
            model.recordNavigation(.sidebar(newValue))
        }
        .onChange(of: searchFocused) { _, focused in
            guard !suppressingHistory else { return }
            if focused {
                model.recordNavigation(.search(searchText))
            } else {
                // Dismissing the field ends the search session (AC-15): the
                // session's single history entry is removed.
                model.endSearchIfNeeded()
            }
        }
        .onChange(of: searchText) { _, newValue in
            guard !suppressingHistory, searchFocused else { return }
            // Intermediate search-word changes rewrite the in-flight search
            // entry in place — never a second stack push.
            if case .search = model.backEntries.last {
                model.recordNavigation(.search(newValue))
            }
        }
        .languageReloading()
        .themedAppearance()
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button(action: goBack) {
                    Image(systemName: "chevron.backward")
                }
                .disabled(!model.canGoBack)
                .help(L10n.string("Go Back"))
                .accessibilityLabel(L10n.string("Go Back"))
                Button(action: goForward) {
                    Image(systemName: "chevron.forward")
                }
                .disabled(!model.canGoForward)
                .help(L10n.string("Go Forward"))
                .accessibilityLabel(L10n.string("Go Forward"))
            }
            ToolbarItemGroup(placement: .primaryAction) {
                searchField
                themeToggle
            }
        }
        .alert(
            L10n.string("Unable to Open"),
            isPresented: openErrorBinding
        ) {
            Button(L10n.string("OK")) { openError = nil }
        } message: {
            Text(verbatim: openError ?? "")
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

    // MARK: Re-authorization banner

    /// Top-of-window banner shown while any authorized root's bookmark no
    /// longer resolves. With a single broken root the button goes straight
    /// to the authorization panel (pre-selected to the lost directory) so
    /// one click in the panel restores access; with several, it opens the
    /// Settings directories pane to manage them together. Sandboxed apps
    /// cannot silently re-acquire a broken bookmark — macOS requires the
    /// user to re-pick the directory in the open panel.
    private var authorizationBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13))
                .foregroundStyle(AppTheme.warn)
            Text(verbatim: L10n.string("Authorization Lost Banner"))
                .font(AppTheme.body(13))
                .foregroundStyle(AppTheme.foreground)
            Spacer(minLength: 12)
            Button(L10n.string("Re-authorize…")) {
                reauthorizeUnhealthyRoots()
            }
            .buttonStyle(SettingsButtonStyle())
            .help(L10n.string("Re-authorize Directory"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(AppTheme.warn.opacity(0.12))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(AppTheme.borderSoft)
                .frame(height: 1)
        }
    }

    /// Routes the banner's re-authorization: a single broken root opens the
    /// authorization panel directly; multiple roots fall back to the
    /// Settings directories pane.
    private func reauthorizeUnhealthyRoots() {
        let broken = model.authorizedRoots.filter { model.unhealthyRootIDs.contains($0.id) }
        if let only = broken.count == 1 ? broken.first : nil {
            reauthorize(only)
        } else if !broken.isEmpty {
            openSettingsDirectories()
        }
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
        counts[.links] = model.snapshots.filter { $0.resolvedTarget != nil }.count
        counts[.mcp] = model.mcpServers.count
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
            let skillCount = SkillQuery(scope: .all, agentID: definition.id)
                .apply(to: model.snapshots, rootsByID: model.rootsByID).count
            let mcpCount = model.mcpServers.filter { $0.agentID == definition.id }.count
            // An Agent detected only through MCP (no Skills on disk) still
            // shows: the count reflects whatever it owns that is visible.
            counts[.agent(id: definition.id)] = skillCount > 0 ? skillCount : mcpCount
        }
        return counts
    }

    private func clearFilters() {
        destination = .all
        searchText = ""
    }

    /// One-shot probe of every MCP server, driven by the MCP list header.
    /// Marks the pass in flight for the list, runs it, and clears the flag.
    private func probeAllMcp() {
        guard !mcpProbingAll else { return }
        mcpProbingAll = true
        Task {
            await model.probeAllMcpServers()
            mcpProbingAll = false
        }
    }

    /// One-shot probe of one Agent's MCP servers (Agent detail half).
    private func probeAgentMcp(agentID: String) {
        guard !mcpProbingAll else { return }
        mcpProbingAll = true
        Task {
            let agents = model.mcpServers.filter { $0.agentID == agentID }
            for server in agents {
                model.mcpProbeStatuses[server.id] = .probing
                let status = await McpProber().probe(server)
                model.mcpProbeStatuses[server.id] = status
            }
            mcpProbingAll = false
        }
    }

    // MARK: Navigation

    /// An explicit click (list row, duplicate member, symlink row) selects
    /// the Skill and records the detail as a history step. Clicking a search
    /// result first ends the search session, so back goes straight to the
    /// pre-search state (AC-15). Keyboard moves go through `onArrowSelect`
    /// and never grow the stack.
    private func selectSkill(_ path: String) {
        model.selectOnly(path)
        model.endSearchIfNeeded()
        model.recordNavigation(.skillDetail(SkillSelection(path: path)))
    }

    private func goBack() {
        if let entry = model.goBack() {
            apply(entry)
        } else {
            restoreDefault()
        }
    }

    private func goForward() {
        if let entry = model.goForward() {
            apply(entry)
        }
    }

    private func apply(_ entry: NavigationEntry) {
        suppressingHistory = true
        if let destination = entry.sidebarDestination {
            self.destination = destination
            searchText = ""
            model.selectOnly(nil)
            if destination != .mcp { mcpSelection = nil }
        } else if let query = entry.searchQuery {
            searchText = query
            model.selectOnly(nil)
        } else if let selection = entry.skillSelection {
            model.selectOnly(selection.path)
        }
        suppressingHistory = false
    }

    /// At the stack bottom, back restores the All Skills view.
    private func restoreDefault() {
        suppressingHistory = true
        destination = .all
        searchText = ""
        model.selectOnly(nil)
        mcpSelection = nil
        suppressingHistory = false
    }

    // MARK: Reveal / open

    private func reveal(_ skill: SkillSnapshot) {
        do {
            try model.revealDocumentInFinder(for: skill)
        } catch {
            openError = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        }
    }

    private func openInEditor(_ skill: SkillSnapshot) {
        do {
            try model.openDocumentInDefaultEditor(for: skill)
        } catch {
            openError = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        }
    }

    // MARK: Bindings

    private var openErrorBinding: Binding<Bool> {
        Binding(
            get: { openError != nil },
            set: { isPresented in
                if !isPresented { openError = nil }
            }
        )
    }

    // MARK: Directories

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
        destination = BrowserDestination.fallback(afterRemoving: root.id, from: destination)
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

    /// Opens the Settings scene on the directories pane — used by the
    /// re-authorization banner.
    private func openSettingsDirectories() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        NotificationCenter.default.post(name: .openSettingsTab, object: SettingsTab.directories)
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
        case .links: L10n.string("Symbolic Links")
        case .mcp: L10n.string("MCP")
        case .system(let rootID), .project(let rootID):
            rootsByID[rootID]?.displayName ?? rootID
        case .agent(let id):
            definitions.first { $0.id == id }?.displayName ?? id
        }
    }
}
