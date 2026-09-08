import Darwin
import Foundation
import Combine
import SkillSelectorCore

enum RefreshState: Hashable {
    case idle
    case running
    case finished(RefreshSummary)
    case failed(String)
}

enum AppModelValidationError: Error, LocalizedError {
    case invalidEntryFilename(String)
    case invalidPathTemplate(String)

    var errorDescription: String? {
        switch self {
        case .invalidEntryFilename(let filename):
            return "\(L10n.string("Invalid Entry Filename")): \(filename)"
        case .invalidPathTemplate(let path):
            return "\(L10n.string("Invalid Path Template")): \(path)"
        }
    }
}

struct SkillSelection: Hashable, Identifiable {
    let path: String
    var id: String { path }
}

@MainActor
final class AppModel: ObservableObject {
    private let refresher: IndexRefresher
    private let index: SkillIndex
    /// Authorized-roots store, also handed to the state submodels.
    @Published private(set) var bookmarks: BookmarkStore?
    @Published private(set) var registry: AgentRegistry
    private let builtInRegistry: AgentRegistry
    private let customAgentStore: any AgentDefinitionStoring
    private let refreshHistoryStore: any RefreshHistoryStoring
    private let documentManager: DocumentManager
    private let defaults: UserDefaults
    private let diagnosticStore: DiagnosticStore
    private let homeDirectory: URL
    /// Test seam: pins the sandbox verdict that `isSandboxed` reads from the
    /// process environment, so unit tests can exercise the sandboxed path.
    @Published var environmentIsSandboxed: Bool?
    private var activeRefresh: (id: UUID, task: Task<Void, Never>)?
    /// Bridges the state submodels' `objectWillChange` into this model's
    /// (see the subscription at the end of `init`).
    private var cancellables: Set<AnyCancellable> = []
    /// MCP server detection state (probe statuses + server list), separated
    /// from this type to keep AppModel a composition root (Brooks finding 2).
    let mcps: McpStateModel
    /// Rules-file discovery state (see `RulesStateModel`).
    let rules: RulesStateModel
    /// Marketplace catalog state (sources + listing), separated from this
    /// type to keep AppModel a composition root (Brooks finding 2).
    let catalog: CatalogModel
    /// Deferred background work (fingerprint backfill, body search index),
    /// separated from this type to keep AppModel a composition root
    /// (Brooks finding 2 / review M10).
    let backgroundWork: BackgroundWorkCoordinator
    /// Stateless read-only comparison passes between Skill installations
    /// (review M10).
    let comparisons: ComparisonService

    @Published var refreshState: RefreshState = .idle
    @Published var selection: SkillSelection?
    /// Recent refreshes that changed something, newest first. Empty
    /// refreshes are not recorded — the history answers "what moved".
    @Published private(set) var refreshHistory: [RefreshChangeEntry] = []
    @Published private(set) var snapshots: [SkillSnapshot] = []
    @Published private(set) var authorizedRoots: [AuthorizedRootSnapshot] = []
    @Published private(set) var rootsByID: [String: AuthorizedRootSnapshot] = [:]
    @Published private(set) var agentDefinitions: [AgentDefinition]
    @Published private(set) var customAgentDefinitions: [AgentDefinition]
    /// Fine-grained navigation history, owned by the model. Views record
    /// actions through `recordNavigation`; they never mutate the stacks
    /// directly.
    @Published private var navigation = NavigationHistory()
    @Published var autoScanHome: Bool {
        didSet { defaults.set(autoScanHome, forKey: Self.autoScanHomeDefaultsKey) }
    }
    @Published private(set) var manuallyEnabledAgentIDs: Set<String> {
        didSet { defaults.set(manuallyEnabledAgentIDs.sorted(), forKey: Self.manuallyEnabledAgentsDefaultsKey) }
    }

    init(
        refresher: IndexRefresher,
        index: SkillIndex,
        bookmarks: BookmarkStore? = nil,
        registry: AgentRegistry,
        defaults: UserDefaults = .standard,
        customAgentStore: (any AgentDefinitionStoring)? = nil,
        refreshHistoryStore: (any RefreshHistoryStoring)? = nil,
        diagnosticStore: DiagnosticStore = .shared,
        homeDirectory: URL = AppModel.realUserHomeDirectory(),
        catalogFetcher: (any CatalogFetching)? = nil,
        catalogSourceStore: (any CatalogSourceStoring)? = nil
    ) {
        self.refresher = refresher
        self.index = index
        self.bookmarks = bookmarks
        self.mcps = McpStateModel(bookmarks: bookmarks)
        self.rules = RulesStateModel(bookmarks: bookmarks)
        self.documentManager = DocumentManager(bookmarks: bookmarks)
        builtInRegistry = registry
        self.defaults = defaults
        self.diagnosticStore = diagnosticStore
        self.homeDirectory = homeDirectory
        let sourceStore = catalogSourceStore ?? UserDefaultsCatalogSourceStore(defaults: defaults)
        self.catalog = CatalogModel(
            fetcher: catalogFetcher ?? CatalogFetcher(),
            sourceStore: sourceStore,
            defaults: defaults
        )
        let store = customAgentStore ?? UserDefaultsAgentDefinitionStore(defaults: defaults)
        self.customAgentStore = store
        self.refreshHistoryStore = refreshHistoryStore
            ?? UserDefaultsRefreshHistoryStore(defaults: defaults)
        let storedCustomDefinitions = (try? store.definitions()) ?? []
        customAgentDefinitions = storedCustomDefinitions
        var effectiveRegistry = registry
        effectiveRegistry.merge(customDefinitions: storedCustomDefinitions)
        self.registry = effectiveRegistry
        autoScanHome = defaults.object(forKey: Self.autoScanHomeDefaultsKey) == nil
            ? true
            : defaults.bool(forKey: Self.autoScanHomeDefaultsKey)
        manuallyEnabledAgentIDs = Set(defaults.stringArray(forKey: Self.manuallyEnabledAgentsDefaultsKey) ?? [])
        agentDefinitions = effectiveRegistry.definitions
        refreshHistory = (try? self.refreshHistoryStore.entries()) ?? []
        self.comparisons = ComparisonService(documentManager: documentManager)
        self.backgroundWork = BackgroundWorkCoordinator(
            index: index,
            diagnosticStore: diagnosticStore
        )
        refresher.updateRegistry(effectiveRegistry)
        do {
            try reloadSnapshot()
        } catch {
            refreshState = .failed(currentRedactor().redact(String(describing: error)))
        }
        // Forward submodel mutations into this model's `objectWillChange`.
        // Views observe only `AppModel` (via `@EnvironmentObject`), so under
        // ObservableObject a change to `mcps` / `rules` / `catalog` — e.g. a
        // probe verdict landing or the catalog leaving its loading state —
        // fires the submodel's own publisher, which nothing subscribes to.
        // Under @Observable the chained reads (`model.catalog.state`) tracked
        // the submodel instances directly; this re-send restores that
        // reactivity. `[weak self]` guards the retain cycle.
        mcps.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        rules.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        catalog.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        backgroundWork.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        backgroundWork.onFingerprintsBackfilled = { [weak self] updated, changedPaths in
            self?.handleFingerprintsBackfilled(updated: updated, changedPaths: changedPaths)
        }
    }

    func checkEnvironment() async {
        await refresh()
    }

    func checkEnvironmentOnLaunch() async {
        if isSandboxed {
            // A pre-fix build could have persisted the sandbox container
            // path as the .home root (FileManager.homeDirectoryForCurrentUser
            // resolves to the container under sandbox). Remove it so it
            // stops shadowing the real home and blocking the first-run guide.
            await purgeSandboxContainerHomeRoot()
        }
        guard autoScanHome else { return }
        await ensureHomeAuthorized()
        do {
            guard try bookmarks?.roots().isEmpty == false else { return }
            await checkEnvironment()
        } catch {
            refreshState = .failed(currentRedactor().redact(String(describing: error)))
        }
    }

    /// Agents flagged legacy in the registry (currently Roo Code). They stay
    /// out of the sidebar until their Skills are detected on disk or the
    /// user enables them manually.
    var legacyAgentDefinitions: [AgentDefinition] {
        agentDefinitions.filter(\.isLegacy)
    }

    /// Manual enable is the legacy agents' escape hatch; only they can be
    /// surfaced this way, so non-legacy agents never gain an empty row.
    func setLegacyAgent(_ agentID: String, enabled: Bool) {
        guard agentDefinitions.contains(where: { $0.id == agentID && $0.isLegacy }) else { return }
        if enabled {
            manuallyEnabledAgentIDs.insert(agentID)
        } else {
            manuallyEnabledAgentIDs.remove(agentID)
        }
    }

    /// Authorizes the user's home directory as a `.home` root when the
    /// auto-scan setting is enabled and no home root exists yet. Sandboxed
    /// builds cannot silently acquire home-directory access, so a failure is
    /// ignored — the user can import it through the panel instead.
    private func ensureHomeAuthorized() async {
        guard let bookmarks else { return }
        // Under App Sandbox the app has no silent access to the real home,
        // and FileManager.homeDirectoryForCurrentUser only resolves to the
        // container — so the auto-scan defers to the first-run guide and the
        // directory panel instead of recording a bogus root.
        guard !isSandboxed else { return }
        guard persistedHomeRoot == nil else { return }
        do {
            _ = try bookmarks.save(url: homeDirectory, kind: .home)
            try reloadAuthorizedRoots()
        } catch {
            // Non-fatal: auto-scan is best-effort.
        }
    }

    /// True when the process runs inside an App Sandbox container.
    private var isSandboxed: Bool {
        environmentIsSandboxed ?? (ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil)
    }

    /// Removes a `.home` root recorded against the sandbox container
    /// directory by an earlier, pre-fix build. Such a root can never be a
    /// real home — the container holds app data, not Agent Skills — and it
    /// would permanently shadow the authorizer while scanning nothing.
    private func purgeSandboxContainerHomeRoot() async {
        guard let bookmarks else { return }
        let containerHome = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        guard let stale = try? bookmarks.roots().first(where: {
            $0.kind == .home && $0.url.standardizedFileURL.path == containerHome.path
        }) else { return }
        do {
            try bookmarks.revoke(id: stale.id)
            try reloadAuthorizedRoots()
        } catch {
            // Best-effort cleanup; a manual re-import heals the state anyway.
        }
    }

    /// The user's real home directory. `FileManager.default.homeDirectoryForCurrentUser`
    /// is misleading under App Sandbox — it resolves to the app container
    /// (`~/Library/Containers/<bundle>/Data`), not the user's home. The
    /// system user record still carries the real path and is readable
    /// without extra entitlements, so the auto-scan and the directory panel
    /// agree on the same directory.
    nonisolated static func realUserHomeDirectory() -> URL {
        guard let record = getpwuid(getuid()), let directory = record.pointee.pw_dir else {
            return FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        }
        return URL(fileURLWithPath: String(cString: directory)).standardizedFileURL
    }

    /// The persisted home root, if any. Both the auto-scan and the import
    /// path consult this so home-root uniqueness has a single definition.
    private var persistedHomeRoot: AuthorizedRootSnapshot? {
        guard let roots = try? bookmarks?.roots() else { return nil }
        return roots.first { $0.kind == .home }
    }

    /// Refreshes the in-memory authorized-root state from the store.
    private func reloadAuthorizedRoots() throws {
        authorizedRoots = try bookmarks?.roots() ?? []
        rootsByID = Dictionary(authorizedRoots.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func authorize(_ url: URL, as kind: AuthorizedRootKind) async {
        guard let bookmarks else {
            refreshState = .failed(L10n.string("Authorization storage is unavailable"))
            return
        }
        await waitForActiveRefresh()
        do {
            // The home root is unique: an auto-scan already authorized the
            // user's home directory, and scanning it covers every declared
            // ~/.../skills folder. While that root is *healthy*, a second
            // `.home` import is refused — it would create a duplicate
            // "Home Directory" entry. But an *unhealthy* home root (the
            // re-authorization case: the directory moved) must fall through
            // to `save`, which merges by path and replaces the stale
            // bookmark data — otherwise the user's re-pick is discarded and
            // the directory stays broken.
            if kind == .home,
               let existing = persistedHomeRoot,
               !unhealthyRootIDs.contains(existing.id) {
                try reloadAuthorizedRoots()
                await refresh()
                return
            }
            let saved = try bookmarks.save(url: url, kind: kind)
            try reloadAuthorizedRoots()
            // Only the imported root rescan: other roots' installations are
            // unchanged on disk, and their incremental caches make a full
            // refresh pure overhead on the import's critical path.
            await refresh(rootIDs: [saved.id])
            recordPathDiagnostic(
                category: .persistence,
                code: "ROOT_AUTHORIZED",
                action: L10n.string("Authorized"),
                path: url.path
            )
        } catch {
            refreshState = .failed(currentRedactor().redact(String(describing: error)))
        }
    }

    func revokeAuthorization(id: String) async {
        guard let bookmarks,
              let root = authorizedRoots.first(where: { $0.id == id }) else { return }
        await waitForActiveRefresh()
        do {
            try index.apply(report: ScanReport(
                roots: [ScannedRoot(
                    id: root.id,
                    url: root.url,
                    availability: .unavailable(reason: "Authorization revoked")
                )]
            ))
            try bookmarks.revoke(id: root.id)
            try reloadSnapshot()
            recordPathDiagnostic(
                category: .persistence,
                code: "ROOT_REVOKED",
                action: L10n.string("Revoked"),
                path: root.url.path,
                additionalRoots: [root]
            )
        } catch {
            refreshState = .failed(currentRedactor().redact(String(describing: error)))
        }
    }

    func renameRoot(id: String, to newName: String) {
        defaults.set(newName.isEmpty ? nil : newName, forKey: Self.rootNameDefaultsKeyPrefix + id)
        for i in authorizedRoots.indices {
            if authorizedRoots[i].id == id {
                authorizedRoots[i].customName = newName.isEmpty ? nil : newName
                break
            }
        }
        var snapshotByID = rootsByID
        if var snapshot = snapshotByID[id] {
            snapshot.customName = newName.isEmpty ? nil : newName
            snapshotByID[id] = snapshot
            rootsByID = snapshotByID
        }
    }

    func saveCustomAgent(
        displayName: String,
        globalRoots: [String],
        entryFilename: String,
        existingID: String? = nil
    ) throws {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        let resolvedEntry = entryFilename.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalEntry = resolvedEntry.isEmpty ? "SKILL.md" : resolvedEntry
        guard EntryFilename.isValid(finalEntry) else {
            throw AppModelValidationError.invalidEntryFilename(finalEntry)
        }

        let resolvedRoots = normalizedLines(globalRoots)
        for template in resolvedRoots {
            let stripped = template.replacingOccurrences(of: "*", with: "")
                .trimmingCharacters(in: .whitespaces)
            guard template != "/", template != "~", !stripped.isEmpty else {
                throw AppModelValidationError.invalidPathTemplate(template)
            }
        }

        let definition = AgentDefinition.custom(
            displayName: name,
            globalRoots: resolvedRoots,
            entryFilename: finalEntry,
            id: existingID
        )
        if existingID == nil {
            try customAgentStore.insert(definition)
        } else {
            try customAgentStore.save(definition)
        }
        try reloadAgentDefinitions()
    }

    func removeCustomAgent(id: String) throws {
        try customAgentStore.remove(id: id)
        try reloadAgentDefinitions()
    }

    func exportDiagnostics(to url: URL) async throws {
        try DiagnosticExporter(redactor: currentRedactor()).write(diagnosticExportInput(), to: url)
    }

    /// The redacted export payload for the in-app read-only viewer — the
    /// same sanitizer the JSON export runs, so the screen never shows more
    /// than the file would.
    func redactedDiagnostics() -> DiagnosticExportInput {
        DiagnosticExporter(redactor: currentRedactor()).sanitized(diagnosticExportInput())
    }

    private func diagnosticExportInput() -> DiagnosticExportInput {
        DiagnosticExportInput(
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                ?? "development",
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            registryIDs: agentDefinitions.map(\.id),
            roots: diagnosticRootSummaries(),
            diagnostics: diagnosticStore.recent()
        )
    }

    func refresh() async {
        await refresh(selectedRootIDs: nil)
    }

    /// Rescans only the given roots' installations; other roots keep their
    /// indexed records and caches untouched. Import uses this so its
    /// critical path costs the imported root alone.
    func refresh(rootIDs: Set<String>) async {
        await refresh(selectedRootIDs: rootIDs)
    }

    private func refresh(selectedRootIDs: Set<String>?) async {
        if let activeRefresh {
            await activeRefresh.task.value
            clearRefresh(id: activeRefresh.id)
            return
        }

        let id = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performRefresh(selectedRootIDs: selectedRootIDs)
        }
        activeRefresh = (id, task)
        await task.value
        clearRefresh(id: id)
    }

    var hasAuthorization: Bool {
        !authorizedRoots.isEmpty
    }

    /// View-level duplicate grouping: skills whose content fingerprint
    /// matches, grouped for tidying. Every member keeps its own record.
    var duplicateGroups: [DuplicateSkillGroup] {
        DuplicateSkillGrouper.groups(snapshots)
    }

    /// Near-duplicate clusters: copies that drifted by small edits and no
    /// longer match byte-for-byte. Exact-duplicate pairs are excluded —
    /// the exact view above already covers them.
    var nearDuplicateGroups: [NearDuplicateSkillGroup] {
        NearDuplicateSkillGrouper.groups(snapshots)
    }

    /// Groups the user ignored, bucketed by their persisted ignore key —
    /// the duplicates view lists these with a restore action, so ignoring
    /// stays reversible.
    var ignoredDuplicateGroups: [IgnoredDuplicateGroup] {
        ignoredGroups(keyPath: \.ignoredDuplicateGroup)
    }

    /// Ignored near-duplicate clusters, keyed the same way as the exact
    /// ones above (the cluster key persists on each member record).
    var ignoredNearDuplicateGroups: [IgnoredDuplicateGroup] {
        ignoredGroups(keyPath: \.ignoredNearDuplicateGroup)
    }

    private func ignoredGroups(
        keyPath: KeyPath<SkillSnapshot, String?>
    ) -> [IgnoredDuplicateGroup] {
        let ignored = snapshots.filter { $0[keyPath: keyPath] != nil }
        return Dictionary(grouping: ignored, by: { $0[keyPath: keyPath] ?? "" })
            .map { key, members in
                IgnoredDuplicateGroup(
                    fingerprint: key,
                    members: members.sorted { $0.path < $1.path }
                )
            }
            .sorted { ($0.members.map(\.name).min() ?? "") < ($1.members.map(\.name).min() ?? "") }
    }

    /// Roots whose security-scoped bookmark can no longer be resolved (moved
    /// directory, restored backup, reinstalled system). They need explicit
    /// re-authorization — a sandboxed app cannot heal these silently.
    @Published private(set) var unhealthyRootIDs: Set<String> = []

    private func reloadBookmarkHealth() {
        guard let bookmarks else {
            unhealthyRootIDs = []
            return
        }
        var unhealthy: Set<String> = []
        for root in authorizedRoots {
            do {
                let access = try bookmarks.resolve(id: root.id)
                access.lease.close()
            } catch {
                unhealthy.insert(root.id)
            }
        }
        unhealthyRootIDs = unhealthy
    }

    func loadDocument(for skill: SkillSnapshot) async throws -> SkillDocument {
        try await documentManager.loadDocument(for: skill, authorizedRoots: authorizedRoots)
    }

    func revealDocumentInFinder(for skill: SkillSnapshot) throws {
        try documentManager.revealDocumentInFinder(for: skill, authorizedRoots: authorizedRoots)
    }

    func openDocumentInDefaultEditor(for skill: SkillSnapshot) throws {
        try documentManager.openDocumentInDefaultEditor(for: skill, authorizedRoots: authorizedRoots)
    }

    private func performRefresh(selectedRootIDs: Set<String>? = nil) async {
        refreshState = .running
        // Files may have changed since the last backfill attempt; give
        // previously failed paths another chance.
        backgroundWork.resetFingerprintBookkeeping()
        do {
            let summary: RefreshSummary
            if let selectedRootIDs {
                summary = try await refresher.refresh(rootIDs: selectedRootIDs)
            } else {
                summary = try await refresher.refresh()
            }
            try reloadSnapshot()
            refreshState = .finished(summary)
            recordRefreshHistory(summary)
            diagnosticStore.record(
                category: .scanning,
                code: "REFRESH_COMPLETED",
                message: L10n.string("Refresh completed"),
                redactor: currentRedactor()
            )
        } catch {
            let redacted = currentRedactor().redact(String(describing: error))
            refreshState = .failed(redacted)
            diagnosticStore.record(
                category: .scanning,
                code: "REFRESH_FAILED",
                message: redacted,
                redactor: currentRedactor()
            )
        }
    }

    /// Persists a refresh that changed something into the history store
    /// (capped, newest first). Empty refreshes are skipped so launch-time
    /// scans do not flood the log.
    /// Background-work state, bridged from `backgroundWork` (whose
    /// `objectWillChange` is forwarded into this model's).
    var isBackfilling: Bool { backgroundWork.isBackfilling }
    var bodySearchTextsByPath: [String: String] { backgroundWork.bodySearchTextsByPath }

    func waitForFingerprintBackfill() async {
        await backgroundWork.waitForFingerprintBackfill()
    }

    func waitForBodySearchIndex() async {
        await backgroundWork.waitForBodySearchIndex()
    }

    /// Merges the backfilled rows into the published snapshots and records
    /// the diagnostic. Review M14: a backfill changes only the rows it
    /// wrote — merge those instead of a full `index.skills()` reload, so
    /// large catalogs don't pay a whole-table read per backfill pass. The
    /// scanner's own `reloadSnapshot()` stays authoritative for everything
    /// else (roots, removals, agent associations).
    private func handleFingerprintsBackfilled(updated: Int, changedPaths: Set<String>) {
        guard updated > 0, !changedPaths.isEmpty else { return }
        applyFingerprintUpdates(paths: changedPaths)
        diagnosticStore.record(
            category: .scanning,
            code: "FINGERPRINTS_BACKFILLED",
            message: L10n.string("Backfilled Fingerprints", updated),
            redactor: currentRedactor()
        )
    }

    private func applyFingerprintUpdates(paths: Set<String>) {
        var updated = snapshots
        var changed = false
        for path in paths.sorted() {
            guard let fresh = try? index.skill(path: path),
                  let position = updated.firstIndex(where: { $0.path == path })
            else {
                // A skill the scan removed mid-backfill: leave the list as
                // it is; the next refresh reloads authoritatively.
                continue
            }
            if updated[position] != fresh {
                updated[position] = fresh
                changed = true
            }
        }
        guard changed else { return }
        snapshots = updated
    }

    private func recordRefreshHistory(_ summary: RefreshSummary) {
        guard !summary.isEmpty else { return }
        let entry = RefreshChangeEntry(summary: summary)
        do {
            try refreshHistoryStore.record(entry)
            refreshHistory = try refreshHistoryStore.entries()
        } catch {
            // Non-fatal: the history view simply misses this entry.
        }
    }

    private static let autoScanHomeDefaultsKey = "SkillSelector.autoScanHome"
    private static let manuallyEnabledAgentsDefaultsKey = "SkillSelector.manuallyEnabledAgents"
    private static let rootNameDefaultsKeyPrefix = "SkillSelector.rootName."

    private func reloadAgentDefinitions() throws {
        customAgentDefinitions = try customAgentStore.definitions()
        var effectiveRegistry = builtInRegistry
        effectiveRegistry.merge(customDefinitions: customAgentDefinitions)
        registry = effectiveRegistry
        agentDefinitions = registry.definitions
        refresher.updateRegistry(registry)
    }

    private func normalizedLines(_ values: [String]) -> [String] {
        Array(Set(values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })).sorted()
    }

    private func currentRedactor(
        additionalRoots: [AuthorizedRootSnapshot] = []
    ) -> Redactor {
        let roots = authorizedRoots + additionalRoots
        let home = roots.first(where: { $0.kind == .home })?.url
            ?? homeDirectory
        return Redactor(
            homeDirectory: home,
            projectDirectories: roots.filter { $0.kind == .project }.map(\.url)
        )
    }

    private func recordPathDiagnostic(
        category: AppLogCategory,
        code: String,
        action: String,
        path: String,
        additionalRoots: [AuthorizedRootSnapshot] = []
    ) {
        let redactor = currentRedactor(additionalRoots: additionalRoots)
        let redactedPath = redactor.redact(path)
        diagnosticStore.record(
            category: category,
            code: code,
            message: "\(action) \(redactedPath)",
            redactor: redactor
        )
    }

    /// Surfaces MCP configs that exist but were skipped (oversized,
    /// unreadable, or unparseable) so a broken config is distinguishable
    /// from "agent not installed" in the diagnostics viewer. Paths go
    /// through the redactor like every other diagnostic record.
    private func recordMcpScanIssues(_ issues: [McpScanIssue]) {
        guard !issues.isEmpty else { return }
        let redactor = currentRedactor()
        for issue in issues {
            let reason: String
            switch issue.kind {
            case .fileTooLarge(let bytes):
                reason = "\(L10n.string("MCP Config Skipped Too Large")) (\(bytes))"
            case .unreadable:
                reason = L10n.string("MCP Config Skipped Unreadable")
            case .parseFailed(let description):
                reason = "\(L10n.string("MCP Config Parse Failed")): \(description)"
            }
            diagnosticStore.record(
                category: .scanning,
                code: "MCP_CONFIG_SKIPPED",
                message: "\(reason) \(redactor.redact(issue.configPath))",
                redactor: redactor
            )
        }
    }

    private func diagnosticRootSummaries() -> [DiagnosticRootSummary] {
        authorizedRoots.map { root in
            let isAvailable: Bool
            do {
                guard let bookmarks else { throw DocumentAccessError.authorizationStorageUnavailable }
                let access = try bookmarks.resolve(id: root.id)
                access.lease.close()
                isAvailable = true
            } catch {
                isAvailable = false
            }
            return DiagnosticRootSummary(
                id: root.id,
                kind: root.kind,
                isAvailable: isAvailable
            )
        }
    }

    private func waitForActiveRefresh() async {
        guard let activeRefresh else { return }
        await activeRefresh.task.value
        clearRefresh(id: activeRefresh.id)
    }

    private func clearRefresh(id: UUID) {
        guard activeRefresh?.id == id else { return }
        activeRefresh = nil
    }

    func reloadSnapshot() throws {
        let updatedSnapshots = try index.skills()
        let updatedRoots = try bookmarks?.roots() ?? []
        // Review M14 fast path: when neither the rows nor the roots moved,
        // skip the whole-tree invalidation (submodel reloads, bookmark
        // health pass, background rescheduling). Empty snapshots always
        // fall through so the first load initializes the submodels.
        if updatedSnapshots == snapshots,
           updatedRoots == authorizedRoots,
           !updatedSnapshots.isEmpty {
            return
        }
        snapshots = updatedSnapshots
        authorizedRoots = updatedRoots
        rootsByID = Dictionary(updatedRoots.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        reloadBookmarkHealth()
        if let selection,
           !updatedSnapshots.contains(where: { $0.path == selection.path }) {
            self.selection = nil
        }
        mcps.reload(authorizedRoots: updatedRoots)
        recordMcpScanIssues(mcps.lastScanIssues)
        rules.reload(authorizedRoots: updatedRoots)
        backgroundWork.scheduleFingerprintBackfillIfNeeded(
            snapshots: updatedSnapshots,
            authorizedRoots: updatedRoots,
            bookmarks: bookmarks
        )
        backgroundWork.scheduleBodySearchIndexRebuild(
            snapshots: updatedSnapshots,
            authorizedRoots: updatedRoots,
            bookmarks: bookmarks
        )
    }
}

// MARK: - Navigation history

extension AppModel {
    /// The model owns the history (see `NavigationHistory`); these thin
    /// accessors keep views reading state and calling actions through the
    /// model rather than touching the stacks themselves.
    var backEntries: [NavigationEntry] { navigation.backEntries }
    var forwardEntries: [NavigationEntry] { navigation.forwardEntries }
    var canGoBack: Bool { navigation.canGoBack }
    var canGoForward: Bool { navigation.canGoForward }

    func recordNavigation(_ entry: NavigationEntry) {
        navigation.record(entry)
    }

    func goBack() -> NavigationEntry? {
        navigation.goBack()
    }

    func goForward() -> NavigationEntry? {
        navigation.goForward()
    }

    func endSearchIfNeeded() {
        navigation.endSearchIfNeeded()
    }
}

// MARK: - Duplicate group ignore

/// One ignored group: the persisted ignore key plus its current members.
/// The members re-derive from live snapshots, so a stale key (membership
/// changed since the ignore) simply yields no row.
struct IgnoredDuplicateGroup: Identifiable {
    let fingerprint: String
    let members: [SkillSnapshot]

    var id: String { fingerprint }
    /// First member name alphabetically — the group's display name.
    var displayName: String { members.map(\.name).min() ?? "" }
}

extension AppModel {
    /// Marks (or unmarks) every Skill in the duplicate group identified by
    /// `fingerprint` as ignored, removing the group from the duplicates
    /// view. Persisted in the index database. Returns the number of records
    /// updated.
    @discardableResult
    func setDuplicateGroupIgnored(fingerprint: String, ignored: Bool) throws -> Int {
        let updated = try index.setIgnoredDuplicateGroup(fingerprint, ignored: ignored)
        if updated > 0 {
            try reloadSnapshot()
        }
        return updated
    }

    /// Marks (or unmarks) every Skill of a near-duplicate cluster as
    /// ignored, removing the cluster from the near-duplicates view. The
    /// cluster key derives from member paths; a membership change makes a
    /// previous ignore stale and the cluster reappears. Returns the number
    /// of records updated.
    @discardableResult
    func setNearDuplicateGroupIgnored(
        _ group: NearDuplicateSkillGroup,
        ignored: Bool
    ) throws -> Int {
        try setNearDuplicateGroupIgnored(
            fingerprint: group.fingerprint,
            memberPaths: group.members.map(\.snapshot.path),
            ignored: ignored
        )
    }

    /// Key-based variant — the restore path from the duplicates view, where
    /// the ignored cluster's members re-derive from snapshots rather than
    /// arriving as a live group.
    @discardableResult
    func setNearDuplicateGroupIgnored(
        fingerprint: String,
        memberPaths: [String],
        ignored: Bool
    ) throws -> Int {
        let updated = try index.setIgnoredNearDuplicateGroup(
            paths: memberPaths,
            key: fingerprint,
            ignored: ignored
        )
        if updated > 0 {
            try reloadSnapshot()
        }
        return updated
    }
}

// MARK: - Selection

extension AppModel {
    /// Plain click / keyboard navigation: single selection.
    func selectOnly(_ path: String?) {
        selection = path.map(SkillSelection.init(path:))
    }
}
