import AppKit
import SkillSelectorCore
import SwiftUI

/// The main browser window, laid out as the design's three columns
/// (240 / 400-default / flexible). The middle list column is user-resizable
/// via the drag handle, and a titlebar toolbar hosts back/forward, search
/// and the appearance toggle.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @AppStorage(ThemePreference.storageKey) private var themeMode = "system"
    @State private var destination: BrowserDestination
    /// Ends in-column search editing when the user clicks outside the
    /// field — SwiftUI keeps field focus on outside clicks otherwise.
    @State private var editEndMonitor: Any?
    /// Local event monitor translating two-finger horizontal swipes into
    /// history navigation (right = back, left = forward), mirroring
    /// Safari/Mail. Fires only when the system "swipe between pages"
    /// gesture is enabled — the same setting Safari uses — so it never
    /// fights normal scrolling in the list column.
    @State private var swipeMonitor: Any?
    @State private var searchText = ""
    @State private var sort: SkillQuery.Sort = .default
    @State private var openError: String?
    @FocusState private var searchFocused: Bool
    /// ⌘1/⌘2/⌘3 column focus. Sidebar and detail panes have no text field,
    /// so the focus lands on the pane itself (the sidebar's first
    /// interactive row via focusability, the detail's scroll content) —
    /// enough for VoiceOver / full keyboard access to reach them. The list
    /// column focuses its search field, the same target as ⌘F.
    @FocusState private var sidebarFocused: Bool
    @FocusState private var detailFocused: Bool
    /// Searchable middle-column width, adjustable by dragging the resizer.
    @State private var listColumnWidth: CGFloat = 400
    /// Local event monitor resigning the toolbar search field on outside
    /// clicks (AppKit focus; see `installSearchFocusMonitors`).
    /// Notification observers removed with the monitor.
    /// Suppresses history recording while a back/forward navigation is
    /// restoring state — the restore is not a new action.
    @State private var suppressingHistory = false
    /// Seeds the history stack bottom once with the initial destination.
    @State private var didSeedHistory = false
    /// Selected MCP server id for the MCP detail pane.
    @State private var mcpSelection: String?
    /// Selected rules file id for the Rules detail pane.
    @State private var rulesSelection: String?
    /// Selected catalog skill id for the Catalog detail pane.
    @State private var catalogSelection: String?
    /// True while a probe-all pass is in flight (drives list progress).
    @State private var mcpProbingAll = false
    /// True while the refresh history popover is presented.
    @State private var isShowingRefreshHistory = false
    /// Set when the user dismisses the refresh-complete banner; reset on
    /// the next refresh so a later change re-shows it (spec §5.7: a banner
    /// stays hidden after dismissal until re-triggered).
    @State private var dismissedRefreshBanner = false

    init(
        initialDestination: BrowserDestination = .all,
        initialRulesSelection: String? = nil,
        initialCatalogSelection: String? = nil
    ) {
        _destination = State(initialValue: initialDestination)
        _rulesSelection = State(initialValue: initialRulesSelection)
        _catalogSelection = State(initialValue: initialCatalogSelection)
    }

    var body: some View {
        @Bindable var model = model
        let currentDestination = destination
        let detectedAgentIDs = BrowserSidebar.detectedAgentIDs(
            from: model.snapshots,
            hasAuthorization: model.hasAuthorization
        ).union(BrowserSidebar.mcpAgentIDs(from: model.mcps.servers))
        let title = currentDestination.title(rootsByID: model.rootsByID, definitions: model.agentDefinitions)

        mainContent(detectedAgentIDs: detectedAgentIDs, title: title)
            .modifier(WindowCommandHandling(
                onGoBack: { goBack() },
                onGoForward: { goForward() },
                onFocusSearch: { focusSearchField() },
                onRefresh: { Task { await model.refresh() } },
                onRevealSelection: { revealCurrentSelection() },
                onOpenSelection: { openCurrentSelection() },
                onToggleAppearance: { toggleAppearance() },
                onFocusSidebar: { sidebarFocused = true },
                onFocusList: { searchFocused = true },
                onFocusDetail: { detailFocused = true }
            ))
            .onAppear { onAppear() }
            .onDisappear { onDisappear() }
            .onChange(of: destination) { _, newValue in
                destinationChanged(newValue)
            }
            .onChange(of: searchFocused) { _, focused in
                searchFocusChanged(focused)
            }
            .onChange(of: searchText) { _, newValue in
                searchTextChanged(newValue)
            }
            .onChange(of: model.refreshState) { _, newState in
                refreshStateChanged(newState)
            }
            .languageReloading()
            .themedAppearance()
            .toolbar { windowToolbar }
            .alert(
                L10n.string("Unable to Open"),
                isPresented: openErrorBinding
            ) {
                Button(L10n.string("OK")) { openError = nil }
            } message: {
                Text(verbatim: openError ?? "")
            }
    }

    /// The three-column layout: banners, sidebar, list column, resizer, and
    /// detail pane. Kept separate from `body` so the root view's modifier
    /// chain stays type-checkable.
    private func mainContent(detectedAgentIDs: Set<String>, title: String) -> some View {
        VStack(spacing: 0) {
            if !model.unhealthyRootIDs.isEmpty {
                authorizationBanner
            }
            if let summary = finishedRefreshSummary, !summary.isEmpty, !dismissedRefreshBanner {
                refreshCompleteBanner(summary)
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
                // ⌘1 target: the sidebar is a button list; focusing the
                // container lets full-keyboard-access / VoiceOver land in
                // the pane and tab through its rows.
                .focused($sidebarFocused)
                .focusable()

                listPane

                ColumnResizer(width: $listColumnWidth, range: 300...620)

                // ⌘3 target: the detail pane. Wrapped in a group so one
                // focused() covers every detail variant; focusability lets
                // full-keyboard-access land in the pane and scroll it.
                detailPane
                    .focused($detailFocused)
                    .focusable()
            }
        }
        .frame(minWidth: 960, minHeight: 600)
        .navigationTitle(title)
    }

    // MARK: Lifecycle & command handlers

    /// View-appear: install event monitors and seed the history stack
    /// bottom once with the launch destination.
    private func onAppear() {
        installEditingEndMonitor()
        installSwipeNavigationMonitor()
        guard !didSeedHistory else { return }
        didSeedHistory = true
        model.recordNavigation(.sidebar(destination))
    }

    /// View-disappear: tear down both event monitors.
    private func onDisappear() {
        if let monitor = editEndMonitor {
            NSEvent.removeMonitor(monitor)
            editEndMonitor = nil
        }
        if let monitor = swipeMonitor {
            NSEvent.removeMonitor(monitor)
            swipeMonitor = nil
        }
    }

    /// Destination change: record a sidebar history step (suppressed while
    /// a back/forward navigation is restoring state).
    private func destinationChanged(_ newValue: BrowserDestination) {
        guard !suppressingHistory else { return }
        model.recordNavigation(.sidebar(newValue))
    }

    /// Search-focus change: opening the field starts a search session
    /// (one history step); dismissing it ends the session (AC-15).
    private func searchFocusChanged(_ focused: Bool) {
        guard !suppressingHistory else { return }
        if focused {
            model.recordNavigation(.search(searchText))
        } else {
            model.endSearchIfNeeded()
        }
    }

    /// Search-term change: rewrite the in-flight search entry in place,
    /// never a second stack push.
    private func searchTextChanged(_ newValue: String) {
        guard !suppressingHistory, searchFocused else { return }
        if case .search = model.backEntries.last {
            model.recordNavigation(.search(newValue))
        }
    }

    /// ⌘F / Search item: focus the field and select the existing query so
    /// typing replaces it.
    private func focusSearchField() {
        searchFocused = true
        DispatchQueue.main.async {
            (NSApp.keyWindow?.firstResponder as? NSTextView)?.selectAll(nil)
        }
    }

    /// Refresh-state change: a new refresh re-arms the completion banner —
    /// dismissing it only silences the current refresh's result.
    private func refreshStateChanged(_ newState: RefreshState) {
        if case .running = newState {
            dismissedRefreshBanner = false
        }
    }

    /// The window toolbar: back/forward navigation group and the primary
    /// action group (refresh, history, appearance, settings).
    @ToolbarContentBuilder
    private var windowToolbar: some ToolbarContent {
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
            refreshButton
            historyButton
            themeToggle
            settingsButton
        }
    }

    /// history. Dismissible; reappears on the next refresh that changes
    /// something.
    private func refreshCompleteBanner(_ summary: RefreshSummary) -> some View {
        Banner(
            tone: .success,
            icon: "checkmark.circle.fill",
            text: String.localizedStringWithFormat(
                L10n.string("Refresh Complete Banner"),
                summary.added, summary.changed, summary.removed
            ),
            actionTitle: L10n.string("View Changes"),
            action: { isShowingRefreshHistory = true },
            onDismiss: { dismissedRefreshBanner = true }
        )
    }

    // MARK: Toolbar

    /// The explicit refresh action: rescans every authorized root now.
    /// While a refresh runs the button shows progress and ignores clicks
    /// (the in-flight task is awaited either way).
    private var refreshButton: some View {
        let isRunning = model.refreshState == RefreshState.running
        return Button {
            Task { await model.refresh() }
        } label: {
            if isRunning {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 30, height: 30)
            } else {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 14))
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
        }
        .buttonStyle(.borderless)
        .disabled(isRunning)
        .help(L10n.string("Refresh Now"))
        .accessibilityLabel(L10n.string("Refresh Now"))
    }

    /// Recent refresh changes, anchored to the history button.
    private var historyButton: some View {
        Button {
            isShowingRefreshHistory = true
        } label: {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 14))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(L10n.string("Change History"))
        .accessibilityLabel(L10n.string("Change History"))
        .popover(isPresented: $isShowingRefreshHistory, arrowEdge: .bottom) {
            RefreshHistoryPopover(history: model.refreshHistory)
        }
    }

    /// Settings entry point in the window toolbar (top-right), replacing
    /// the old sidebar footer link. Icon-only, matching the other toolbar
    /// actions.
    private var settingsButton: some View {
        Button {
            openSettings()
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 14))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(L10n.string("Open Settings"))
        .accessibilityLabel(L10n.string("Open Settings"))
    }

    /// `.themeBtn`: moon in light mode, sun in dark mode; toggles between
    /// the two like the HTML prototype's `ss.theme` flip.
    private var themeToggle: some View {
        Button(action: toggleAppearance) {
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

    /// Flips the persisted appearance between light and dark — the shared
    /// implementation behind the toolbar toggle and the ⌘⌥T menu item.
    private func toggleAppearance() {
        let dark = ThemePreference.effectiveDark(mode: themeMode)
        themeMode = dark ? "light" : "dark"
    }

    // MARK: Detail pane

    /// Display names keyed by agent id — same dictionary `body` builds
    /// locally, hoisted so the extracted `detailPane` can use it too.
    private var agentNamesByID: [String: String] {
        Dictionary(
            model.agentDefinitions.map { ($0.id, $0.displayName) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// The middle column's filtered rows for the current destination,
    /// mirroring the query `body` previously built inline.
    private var filteredSkills: [SkillSnapshot] {
        SkillQuery(
            scope: destination.queryScope,
            agentID: destination.agentID,
            searchText: searchText,
            sort: sort
        ).apply(
            to: model.snapshots,
            rootsByID: model.rootsByID,
            agentNamesByID: agentNamesByID,
            bodyTextsByPath: model.bodySearchTextsByPath
        )
    }

    /// Skills that resolve through a symbolic link.
    private var symlinkSkills: [SkillSnapshot] {
        model.snapshots.filter { $0.resolvedTarget != nil }
    }

    /// The middle column, switching on the current destination. Extracted
    /// from `body` so SwiftUI can type-check the root view in reasonable
    /// time.
    @ViewBuilder
    private var listPane: some View {
        if destination == .duplicates {
            DuplicateGroupsView(
                groups: model.duplicateGroups,
                nearGroups: model.nearDuplicateGroups,
                selection: model.selection,
                agentNamesByID: agentNamesByID,
                hasAuthorization: model.hasAuthorization,
                onRevealInFinder: { skill in reveal(skill) },
                onOpenInEditor: { skill in openInEditor(skill) },
                onIgnoreGroup: { fingerprint in
                    _ = try? model.setDuplicateGroupIgnored(fingerprint: fingerprint, ignored: true)
                },
                onIgnoreNearGroup: { group in
                    _ = try? model.setNearDuplicateGroupIgnored(group, ignored: true)
                },
                onLoadComparison: { left, right in
                    try await model.compareSnapshots(left, right)
                },
                onLoadNearDiffs: { group in
                    await model.nearBodyDiffs(in: group)
                },
                onSelect: { path in selectSkill(path) }
            )
            .frame(width: listColumnWidth)
        } else if destination == .links {
            SymlinkListView(
                links: symlinkSkills,
                selection: model.selection,
                agentNamesByID: agentNamesByID,
                onRevealInFinder: { skill in reveal(skill) },
                onSelect: { path in selectSkill(path) }
            )
            .frame(width: listColumnWidth)
        } else if destination == .rules {
            RulesListView(
                files: model.rules.files,
                selection: rulesSelection,
                agentNamesByID: agentNamesByID,
                onSelect: { file in selectRules(file) },
                onReveal: { file in revealRules(file) },
                onOpen: { file in openRules(file) }
            )
            .frame(width: listColumnWidth)
        } else if destination == .mcp {
            McpListView(
                servers: model.mcps.servers,
                statuses: model.mcps.probeStatuses,
                selection: mcpSelection,
                agentNamesByID: agentNamesByID,
                isProbing: mcpProbingAll,
                onSelect: { server in
                    mcpSelection = server.id
                    model.recordNavigation(.sidebar(.mcp))
                },
                onProbeAll: { probeAllMcp() },
                onRevealConfig: { server in model.mcps.revealConfigFile(server) }
            )
            .frame(width: listColumnWidth)
        } else if destination == .catalog {
            CatalogListView(
                state: model.catalog.state,
                selection: catalogSelection,
                onSelect: { skill in selectCatalog(skill) },
                onRefresh: { Task { await model.catalog.refresh() } }
            )
            .task { await model.catalog.loadIfNeeded() }
            .frame(width: listColumnWidth)
        } else {
            SkillListView(
                selection: model.selection,
                searchText: $searchText,
                sort: $sort,
                searchFocused: $searchFocused,
                title: destination.title(rootsByID: model.rootsByID, definitions: model.agentDefinitions),
                skills: filteredSkills,
                allSkillCount: model.snapshots.count,
                hasAuthorization: model.hasAuthorization,
                hasActiveFilters: hasActiveFilters,
                refreshState: model.refreshState,
                agentNamesByID: agentNamesByID,
                bodyTextsByPath: model.bodySearchTextsByPath,
                onClearFilters: clearFilters,
                onImportProject: { chooseDestinationRoot() },
                onImportHome: { chooseSystemRoot() },
                onRevealInFinder: { skill in reveal(skill) },
                onOpenInEditor: { skill in openInEditor(skill) },
                onPrimarySelect: { path in selectSkill(path) },
                onArrowSelect: { path in model.selectOnly(path) }
            )
            .frame(width: listColumnWidth)
        }
    }

    /// The right column, switching on the current destination. Extracted
    /// from `body` so SwiftUI can type-check the root view in reasonable
    /// time; `detailPane` also gives ⌘3 a single focus target covering
    /// every detail variant.
    @ViewBuilder
    private var detailPane: some View {
        if destination == .rules {
            RulesDetailView(
                file: model.rules.files.first { $0.id == rulesSelection },
                agentNamesByID: agentNamesByID,
                onReveal: { file in revealRules(file) },
                onOpen: { file in openRules(file) }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if destination == .mcp {
            McpDetailView(
                server: model.mcps.servers.first { $0.id == mcpSelection },
                status: mcpSelection.flatMap { id in model.mcps.probeStatuses[id] } ?? .unknown,
                agentNamesByID: agentNamesByID,
                onProbe: {
                    if let id = mcpSelection {
                        Task { await model.mcps.probe(serverID: id) }
                    }
                },
                onRevealConfig: { server in model.mcps.revealConfigFile(server) }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if destination == .catalog {
            CatalogDetailView(
                skill: catalogSkills.first { $0.id == catalogSelection },
                sourceNamesByID: catalogSourceNames,
                agentNamesByID: agentNamesByID
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let agentID = destination.agentID {
            // Agent detail: Skill and MCP stacked vertically.
            AgentDetailView(
                skill: selectedSkillSnapshot,
                agentID: agentID,
                rootsByID: model.rootsByID,
                agentNamesByID: agentNamesByID,
                mcpServers: model.mcps.servers,
                mcpStatuses: model.mcps.probeStatuses,
                onRevealInFinder: { skill in reveal(skill) },
                onOpenInEditor: { skill in openInEditor(skill) },
                onSelectMcp: { server in
                    mcpSelection = server.id
                    destination = .mcp
                },
                onRevealConfig: { server in model.mcps.revealConfigFile(server) },
                onProbeAll: { probeAgentMcp(agentID: agentID) }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            SkillDetailView(
                skill: selectedSkillSnapshot,
                rootsByID: model.rootsByID,
                agentNamesByID: agentNamesByID,
                onRevealInFinder: { skill in reveal(skill) },
                onOpenInEditor: { skill in openInEditor(skill) }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The most recent refresh summary, when a refresh actually finished
    /// (drives the green "refresh complete" banner).
    private var finishedRefreshSummary: RefreshSummary? {
        if case .finished(let summary) = model.refreshState {
            return summary
        }
        return nil
    }

    /// Top-of-window banner shown while any authorized root's bookmark no
    /// longer resolves. With a single broken root the button goes straight
    /// to the authorization panel (pre-selected to the lost directory) so
    /// one click in the panel restores access; with several, it opens the
    /// Settings directories pane to manage them together. Sandboxed apps
    /// cannot silently re-acquire a broken bookmark — macOS requires the
    /// user to re-pick the directory in the open panel.
    private var authorizationBanner: some View {
        Banner(
            tone: .warning,
            icon: "exclamationmark.triangle.fill",
            text: L10n.string("Authorization Lost Banner"),
            actionTitle: L10n.string("Re-authorize…"),
            action: { reauthorizeUnhealthyRoots() },
            actionHelp: L10n.string("Re-authorize Directory")
        )
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
        counts[.rules] = model.rules.files.count
        counts[.mcp] = model.mcps.servers.count
        let catalogSkillCount = catalogSkills.count
        if catalogSkillCount > 0 {
            counts[.catalog] = catalogSkillCount
        }
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
            let mcpCount = model.mcps.servers.filter { $0.agentID == definition.id }.count
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
            await model.mcps.probeAll()
            mcpProbingAll = false
        }
    }

    /// One-shot probe of one Agent's MCP servers (Agent detail half).
    private func probeAgentMcp(agentID: String) {
        guard !mcpProbingAll else { return }
        mcpProbingAll = true
        Task {
            await model.mcps.probe(agentID: agentID)
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
            if destination != .rules { rulesSelection = nil }
            if destination != .catalog { catalogSelection = nil }
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
        rulesSelection = nil
        catalogSelection = nil
        suppressingHistory = false
    }

    // MARK: Reveal / open

    /// The Skill behind the current primary selection, if any — the target
    /// of the ⌘↩ / ⌘O menu actions.
    private var selectedSkillSnapshot: SkillSnapshot? {
        model.selection.flatMap { selection in
            model.snapshots.first { $0.path == selection.path }
        }
    }

    /// ⌘↩ handler: reveals the currently selected Skill in Finder. Falls
    /// back gracefully when nothing is selected — the menu item is active
    /// app-wide, but the action needs a concrete path to act on.
    private func revealCurrentSelection() {
        guard let skill = selectedSkillSnapshot else { return }
        reveal(skill)
    }

    /// ⌘O handler: opens the selected Skill's SKILL.md in the default
    /// editor. Same fallback as `revealCurrentSelection`.
    private func openCurrentSelection() {
        guard let skill = selectedSkillSnapshot else { return }
        openInEditor(skill)
    }

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

    // MARK: Catalog

    /// Loaded catalog skills — the loaded state doubles as the memory
    /// cache; empty until the first on-demand fetch lands.
    private var catalogSkills: [CatalogSkill] {
        if case .loaded(let skills, _) = model.catalog.state { return skills }
        return []
    }

    private var catalogSourceNames: [String: String] {
        Dictionary(uniqueKeysWithValues: model.catalog.sources.map { ($0.id, $0.displayName) })
    }

    /// Selecting a catalog skill shows its detail and records the sidebar
    /// jump as a history step, mirroring the MCP flow.
    private func selectCatalog(_ skill: CatalogSkill) {
        catalogSelection = skill.id
        model.recordNavigation(.sidebar(.catalog))
    }
    /// Selecting a rules file shows its detail; the destination change is
    /// already recorded by the sidebar, so this mirrors the MCP flow's
    /// re-record of the sidebar step per selection.
    private func selectRules(_ file: RulesFileDescriptor) {
        rulesSelection = file.id
        model.recordNavigation(.sidebar(.rules))
    }

    private func revealRules(_ file: RulesFileDescriptor) {
        do {
            try model.rules.revealFile(file)
        } catch {
            openError = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        }
    }

    private func openRules(_ file: RulesFileDescriptor) {
        do {
            try model.rules.openFileInEditor(file)
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

    /// Clicking anywhere outside a focused search field ends its editing
    /// (caret gone, keyboard detached) — AppKit used to do this for the
    /// toolbar field via its own monitors; one window-level monitor now
    /// covers every in-column field.
    private func installEditingEndMonitor() {
        guard editEndMonitor == nil else { return }
        editEndMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown]
        ) { event in
            guard let window = event.window,
                  let editor = window.firstResponder as? NSTextView else { return event }
            let editorFrame = editor.convert(editor.bounds, to: nil)
            if !editorFrame.contains(event.locationInWindow) {
                window.makeFirstResponder(nil)
            }
            return event
        }
    }

    /// Two-finger horizontal swipe navigation, mirroring Safari / Mail:
    /// swipe right (deltaX > 0) steps back, swipe left steps forward. The
    /// `.swipe` event only fires when the system "swipe between pages"
    /// gesture is enabled, so it never collides with normal scrolling —
    /// the list column has no horizontal scroll to fight with.
    private func installSwipeNavigationMonitor() {
        guard swipeMonitor == nil else { return }
        swipeMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.swipe]
        ) { event in
            if event.deltaX > 0.5 {
                goBack()
            } else if event.deltaX < -0.5 {
                goForward()
            }
            return event
        }
    }

    /// Opens the Settings scene on the directories pane — used by the
    /// re-authorization banner.
    private func openSettingsDirectories() {
        openSettings()
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
        case .rules: L10n.string("Rules")
        case .mcp: L10n.string("MCP")
        case .catalog: L10n.string("Marketplace")
        case .system(let rootID), .project(let rootID):
            rootsByID[rootID]?.displayName ?? rootID
        case .agent(let id):
            definitions.first { $0.id == id }?.displayName ?? id
        }
    }
}

/// Routes menu-bar command notifications (⌘F / ⌘[ / ⌘] / ⌘R / ⌘↩ / ⌘O /
/// ⌘⌥T / ⌘1 / ⌘2 / ⌘3) into RootView's handlers. Bundled as one modifier
/// so the root view's body chain stays type-checkable.
private struct WindowCommandHandling: ViewModifier {
    let onGoBack: () -> Void
    let onGoForward: () -> Void
    let onFocusSearch: () -> Void
    let onRefresh: () -> Void
    let onRevealSelection: () -> Void
    let onOpenSelection: () -> Void
    let onToggleAppearance: () -> Void
    let onFocusSidebar: () -> Void
    let onFocusList: () -> Void
    let onFocusDetail: () -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .performGoBack)) { _ in onGoBack() }
            .onReceive(NotificationCenter.default.publisher(for: .performGoForward)) { _ in onGoForward() }
            .onReceive(NotificationCenter.default.publisher(for: .focusSearchField)) { _ in onFocusSearch() }
            .onReceive(NotificationCenter.default.publisher(for: .performRefresh)) { _ in onRefresh() }
            .onReceive(NotificationCenter.default.publisher(for: .performRevealSelection)) { _ in onRevealSelection() }
            .onReceive(NotificationCenter.default.publisher(for: .performOpenSelection)) { _ in onOpenSelection() }
            .onReceive(NotificationCenter.default.publisher(for: .performToggleAppearance)) { _ in onToggleAppearance() }
            .onReceive(NotificationCenter.default.publisher(for: .performFocusSidebar)) { _ in onFocusSidebar() }
            .onReceive(NotificationCenter.default.publisher(for: .performFocusList)) { _ in onFocusList() }
            .onReceive(NotificationCenter.default.publisher(for: .performFocusDetail)) { _ in onFocusDetail() }
    }
}
