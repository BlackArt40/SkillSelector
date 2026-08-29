import AppKit
import Darwin
import Foundation
import Observation
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
            return "Invalid entry filename: \(filename)"
        case .invalidPathTemplate(let path):
            return "Invalid path template: \(path)"
        }
    }
}

struct SkillSelection: Hashable, Identifiable {
    let path: String
    var id: String { path }
}

@MainActor
@Observable
final class AppModel {
    private let refresher: IndexRefresher
    private let index: SkillIndex
    /// `fileprivate(set)` so the MCP extension (same module, other file)
    /// can resolve leases in `reloadMcpServers()`.
    private(set) var bookmarks: BookmarkStore?
    private(set) var registry: AgentRegistry
    private let builtInRegistry: AgentRegistry
    private let customAgentStore: any AgentDefinitionStoring
    private let refreshHistoryStore: any RefreshHistoryStoring
    private let documentManager: DocumentManager
    private let defaults: UserDefaults
    private let diagnosticStore: DiagnosticStore
    private let homeDirectory: URL
    /// Test seam: pins the sandbox verdict that `isSandboxed` reads from the
    /// process environment, so unit tests can exercise the sandboxed path.
    var environmentIsSandboxed: Bool?
    @ObservationIgnored private var activeRefresh: (id: UUID, task: Task<Void, Never>)?
    @ObservationIgnored private var activeFingerprintBackfill: (id: UUID, task: Task<Void, Never>)?
    /// Paths whose deferred fingerprint failed to compute (unreadable
    /// content). They are not retried until the next refresh, when files
    /// may have changed — this keeps the schedule self-terminating.
    @ObservationIgnored private var fingerprintFailures: Set<String> = []
    /// Paths whose body is too short for a similarity fingerprint: the
    /// value is legitimately nil, so without this set the backfill would
    /// re-read them after every reload. Reset on refresh (files change).
    @ObservationIgnored private var shortSimilarityBodies: Set<String> = []
    @ObservationIgnored private var activeBodyIndexBuild: (id: UUID, task: Task<Void, Never>)?
    /// MCP servers parsed from authorized roots, refreshed with the index.
    /// Written only by AppModel+Mcp.swift's `reloadMcpServers()`; treated
    /// as read-only everywhere else.
    var mcpServers: [McpServerDescriptor] = []
    /// Rules files (CLAUDE.md, AGENTS.md, …) found in the authorized roots,
    /// refreshed with the index like MCP servers. Written only by
    /// AppModel+Rules.swift's `reloadRulesFiles()`; treated as read-only
    /// everywhere else — the app never edits these files.
    var rulesFiles: [RulesFileDescriptor] = []
    /// Last on-demand probe result per server id (see AppModel+Mcp.swift).
    /// Written only by the probe methods in AppModel+Mcp.swift.
    var mcpProbeStatuses: [String: McpProbeStatus] = [:]
    /// Read-only marketplace catalog state (see AppModel+Catalog.swift).
    /// Memory-only: fetched on demand from the declared sources, never
    /// persisted, never polled. Written only by AppModel+Catalog.swift.
    var catalogState: CatalogState = .idle
    /// Frontmatter descriptions keyed by skill id, prefetched in the
    /// background after a catalog load; rows fill them in progressively.
    /// Same memory-only discipline as the listing itself.
    var catalogDescriptions: [String: String] = [:]
    /// Catalog network boundary; injected for tests, immutable after init.
    @ObservationIgnored let catalogFetcher: any CatalogFetching
    /// In-flight catalog load; guards duplicate concurrent loads.
    @ObservationIgnored var catalogLoadTask: Task<Void, Never>?
    /// In-flight description prefetch; cancelled by the next load.
    @ObservationIgnored var catalogDescriptionTask: Task<Void, Never>?

    var refreshState: RefreshState = .idle
    var selection: SkillSelection?
    /// Recent refreshes that changed something, newest first. Empty
    /// refreshes are not recorded — the history answers "what moved".
    private(set) var refreshHistory: [RefreshChangeEntry] = []
    /// Folded entry-file bodies by installation path, powering body
    /// search (`body:` terms and free-term matching). Rebuilt in the
    /// background after each refresh; empty until the first build lands,
    /// and search degrades to name matching in the meantime.
    private(set) var bodySearchTextsByPath: [String: String] = [:]
    private(set) var snapshots: [SkillSnapshot] = []
    private(set) var authorizedRoots: [AuthorizedRootSnapshot] = []
    private(set) var rootsByID: [String: AuthorizedRootSnapshot] = [:]
    private(set) var agentDefinitions: [AgentDefinition]
    private(set) var customAgentDefinitions: [AgentDefinition]
    /// Fine-grained navigation history. Views record actions through
    /// `recordNavigation`; they never mutate the stacks directly.
    private(set) var backEntries: [NavigationEntry] = []
    private(set) var forwardEntries: [NavigationEntry] = []
    var autoScanHome: Bool {
        didSet { defaults.set(autoScanHome, forKey: Self.autoScanHomeDefaultsKey) }
    }
    private(set) var manuallyEnabledAgentIDs: Set<String> {
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
        catalogFetcher: (any CatalogFetching)? = nil
    ) {
        self.refresher = refresher
        self.index = index
        self.bookmarks = bookmarks
        self.documentManager = DocumentManager(bookmarks: bookmarks)
        builtInRegistry = registry
        self.defaults = defaults
        self.diagnosticStore = diagnosticStore
        self.homeDirectory = homeDirectory
        self.catalogFetcher = catalogFetcher ?? CatalogFetcher()
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
        refresher.updateRegistry(effectiveRegistry)
        do {
            try reloadSnapshot()
        } catch {
            refreshState = .failed(String(describing: error))
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
            refreshState = .failed(String(describing: error))
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
            // The home root is unique: the auto-scan already authorizes the
            // user's home directory, and scanning it covers every declared
            // ~/.../skills folder. Importing another directory as .home would
            // create a second, empty "Home Directory" entry.
            if kind == .home, persistedHomeRoot != nil {
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
                action: "Authorized",
                path: url.path
            )
        } catch {
            refreshState = .failed(String(describing: error))
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
                action: "Revoked",
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

    /// Roots whose security-scoped bookmark can no longer be resolved (moved
    /// directory, restored backup, reinstalled system). They need explicit
    /// re-authorization — a sandboxed app cannot heal these silently.
    private(set) var unhealthyRootIDs: Set<String> = []

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
        fingerprintFailures = []
        shortSimilarityBodies = []
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
                message: "Refresh completed",
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

    // MARK: Deferred fingerprint backfill

    /// Computes the fingerprints the scan deferred (its dominant I/O
    /// cost) off the critical path: the list is already on screen, and the
    /// duplicate views fill in when this lands. One read per Skill feeds
    /// both the exact SHA-256 and the similarity SimHash. Read-only aside
    /// from the write-back into the index.
    func backfillMissingFingerprints() async {
        let pending = snapshots.filter {
            let needsContent = $0.contentFingerprint == nil
                && !fingerprintFailures.contains($0.path)
            let needsSimilarity = $0.similarityFingerprint == nil
                && !shortSimilarityBodies.contains($0.path)
                && !fingerprintFailures.contains($0.path)
            return needsContent || needsSimilarity
        }
        guard !pending.isEmpty else { return }

        // Reading content under the sandbox needs the roots' security
        // scopes; hold every resolvable lease for the whole hash pass.
        var accesses: [AuthorizedRootAccess] = []
        if let bookmarks {
            for root in authorizedRoots {
                if let access = try? bookmarks.resolve(id: root.id) {
                    accesses.append(access)
                }
            }
        }
        defer { accesses.forEach { $0.lease.close() } }

        let targets = pending.map { skill in
            // The scanner hashes the resolved target of a symlink, not the
            // logical path; mirror that so fingerprints agree.
            (
                path: skill.path,
                directory: skill.resolvedTarget ?? skill.path,
                entryFilename: skill.entryFilename
            )
        }
        let outcome = await Task.detached(priority: .utility) {
            () -> (
                fingerprints: [String: String],
                similarities: [String: String],
                shortBodies: [String],
                failures: [String]
            ) in
            var fingerprints: [String: String] = [:]
            var similarities: [String: String] = [:]
            var shortBodies: [String] = []
            var failures: [String] = []
            for target in targets {
                if Task.isCancelled { break }
                do {
                    let pair = try SkillSimilarityFingerprint.computePair(
                        entryFileURL: URL(fileURLWithPath: target.directory)
                            .appendingPathComponent(target.entryFilename)
                    )
                    fingerprints[target.path] = pair.content
                    if let similarity = pair.similarity {
                        similarities[target.path] = similarity
                    } else {
                        shortBodies.append(target.path)
                    }
                } catch {
                    failures.append(target.path)
                }
            }
            return (fingerprints, similarities, shortBodies, failures)
        }.value
        // Cancelled mid-hash (a newer scan or backfill replaced this one):
        // drop everything, the replacement recomputes.
        guard !Task.isCancelled else { return }

        fingerprintFailures.formUnion(outcome.failures)
        shortSimilarityBodies.formUnion(outcome.shortBodies)
        do {
            let updated = try index.backfillFingerprints(
                contentByPath: outcome.fingerprints,
                similarityByPath: outcome.similarities
            )
            if updated > 0 {
                try reloadSnapshot()
                diagnosticStore.record(
                    category: .scanning,
                    code: "FINGERPRINTS_BACKFILLED",
                    message: "Backfilled \(updated) content fingerprints",
                    redactor: currentRedactor()
                )
            }
        } catch {
            // Non-fatal: the duplicate view simply stays without these
            // fingerprints until the next refresh re-defers them.
        }
    }

    /// Fires the background backfill when any snapshot is still missing a
    /// fingerprint. Replaces an in-flight backfill — its hashes may
    /// predate the scan that just reloaded the snapshots.
    private func scheduleFingerprintBackfillIfNeeded() {
        guard snapshots.contains(where: { skill in
            (skill.contentFingerprint == nil && !fingerprintFailures.contains(skill.path))
                || (skill.similarityFingerprint == nil
                    && !shortSimilarityBodies.contains(skill.path)
                    && !fingerprintFailures.contains(skill.path))
        }) else { return }
        activeFingerprintBackfill?.task.cancel()
        let id = UUID()
        let task = Task { [weak self] in
            await self?.backfillMissingFingerprints()
            self?.clearFingerprintBackfill(id: id)
        }
        activeFingerprintBackfill = (id, task)
    }

    /// Waits for any in-flight background backfill. Test seam.
    func waitForFingerprintBackfill() async {
        if let active = activeFingerprintBackfill {
            await active.task.value
        }
    }

    private func clearFingerprintBackfill(id: UUID) {
        guard activeFingerprintBackfill?.id == id else { return }
        activeFingerprintBackfill = nil
    }

    // MARK: Body search index

    /// Rebuilds the folded body texts powering body search. Runs off the
    /// critical path after every snapshot reload; skills whose entry file
    /// cannot be read are simply absent from the index (name-only match).
    private func rebuildBodySearchIndex() async {
        // Reading content under the sandbox needs the roots' security
        // scopes; hold every resolvable lease for the whole read pass.
        var accesses: [AuthorizedRootAccess] = []
        if let bookmarks {
            for root in authorizedRoots {
                if let access = try? bookmarks.resolve(id: root.id) {
                    accesses.append(access)
                }
            }
        }
        defer { accesses.forEach { $0.lease.close() } }

        let targets = snapshots.map { skill in
            // The scanner reads the resolved target of a symlink; mirror
            // that so the index sees the same content the scan saw.
            (
                path: skill.path,
                directory: skill.resolvedTarget ?? skill.path,
                entryFilename: skill.entryFilename
            )
        }
        let texts = await Task.detached(priority: .utility) {
            () -> [String: String] in
            var folded: [String: String] = [:]
            for target in targets {
                if Task.isCancelled { break }
                let entryURL = URL(fileURLWithPath: target.directory)
                    .appendingPathComponent(target.entryFilename)
                guard let fileSize = try? entryURL
                    .resourceValues(forKeys: [.fileSizeKey]).fileSize,
                      fileSize <= SkillDocumentReader.maximumRenderBytes,
                      let text = try? String(contentsOf: entryURL, encoding: .utf8)
                else { continue }
                let body = FrontmatterParser.bodyLines(from: text)
                    .joined(separator: "\n")
                folded[target.path] = SkillQuery.foldedSearchKey(body)
            }
            return folded
        }.value
        guard !Task.isCancelled else { return }
        bodySearchTextsByPath = texts
    }

    /// Fires (or replaces) the background body-index rebuild. The index is
    /// derived purely from disk state and rebuilt wholesale — no
    /// incremental bookkeeping for a few hundred small files.
    private func scheduleBodySearchIndexRebuild() {
        activeBodyIndexBuild?.task.cancel()
        let id = UUID()
        let task = Task { [weak self] in
            await self?.rebuildBodySearchIndex()
            self?.clearBodySearchIndexBuild(id: id)
        }
        activeBodyIndexBuild = (id, task)
    }

    /// Waits for any in-flight body-index build. Test seam.
    func waitForBodySearchIndex() async {
        if let active = activeBodyIndexBuild {
            await active.task.value
        }
    }

    private func clearBodySearchIndexBuild(id: UUID) {
        guard activeBodyIndexBuild?.id == id else { return }
        activeBodyIndexBuild = nil
    }

    // MARK: Copy comparison

    /// Gathers the read-only comparison between two Skill installations:
    /// both entry documents (validated reads) and fresh stat trees, fed
    /// through the pure `SkillComparisonBuilder`. User-triggered from the
    /// duplicates views; all I/O runs off the main actor while the leases
    /// stay held here.
    func compareSnapshots(
        _ left: SkillSnapshot,
        _ right: SkillSnapshot
    ) async throws -> SkillComparison {
        let leftAccess = try documentManager.resolveDocumentAccess(
            for: left, authorizedRoots: authorizedRoots
        )
        let rightAccess = try documentManager.resolveDocumentAccess(
            for: right, authorizedRoots: authorizedRoots
        )
        defer {
            (leftAccess.leases + rightAccess.leases).forEach { $0.close() }
        }
        let leftRequest = leftAccess.request
        let rightRequest = rightAccess.request
        return try await Task.detached(priority: .userInitiated) {
            let reader = SkillDocumentReader()
            let leftDocument = try reader.read(leftRequest)
            let rightDocument = try reader.read(rightRequest)
            func state(for skill: SkillSnapshot) -> SkillScanState {
                ScanStateBuilder.build(
                    contentDirectory: URL(
                        fileURLWithPath: skill.resolvedTarget ?? skill.path
                    ),
                    entryFilename: skill.entryFilename,
                    resolvedTarget: skill.resolvedTarget.map(URL.init(fileURLWithPath:))
                )
            }
            return SkillComparisonBuilder.compare(
                leftPath: left.path,
                rightPath: right.path,
                leftDocument: FrontmatterParser.parse(leftDocument.source),
                rightDocument: FrontmatterParser.parse(rightDocument.source),
                leftBody: FrontmatterParser.bodyLines(from: leftDocument.source)
                    .joined(separator: "\n"),
                rightBody: FrontmatterParser.bodyLines(from: rightDocument.source)
                    .joined(separator: "\n"),
                leftState: state(for: left),
                rightState: state(for: right)
            )
        }.value
    }

    private static let autoScanHomeDefaultsKey = "SkillSelector.autoScanHome"
    private static let manuallyEnabledAgentsDefaultsKey = "SkillSelector.manuallyEnabledAgents"
    private static let rootNameDefaultsKeyPrefix = "SkillSelector.rootName."
    /// Soft cap on the back stack: the stack bottom (the launch default
    /// seed) is preserved while older entries above it are dropped, so a
    /// very long session cannot grow history without bound.
    private static let maximumBackEntries = 200

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
        snapshots = updatedSnapshots
        authorizedRoots = updatedRoots
        rootsByID = Dictionary(updatedRoots.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        reloadBookmarkHealth()
        if let selection,
           !updatedSnapshots.contains(where: { $0.path == selection.path }) {
            self.selection = nil
        }
        reloadMcpServers()
        reloadRulesFiles()
        scheduleFingerprintBackfillIfNeeded()
        scheduleBodySearchIndexRebuild()
    }
}

// MARK: - Navigation history

extension AppModel {
    var canGoBack: Bool { !backEntries.isEmpty }
    var canGoForward: Bool { !forwardEntries.isEmpty }

    /// Records a navigation action. Re-recording a search session replaces
    /// the in-flight search entry instead of pushing a second one, so
    /// intermediate search-word changes never grow the stack. Any forward
    /// history is cleared, per macOS convention.
    func recordNavigation(_ entry: NavigationEntry) {
        if case .search(let query) = entry,
           case .search = backEntries.last {
            backEntries[backEntries.count - 1] = .search(query)
            return
        }
        backEntries.append(entry)
        forwardEntries = []
        if backEntries.count > Self.maximumBackEntries {
            // Keep the stack bottom (the launch default seed) and drop the
            // oldest entry above it.
            backEntries.remove(at: 1)
        }
    }

    /// Pops the current state onto the forward stack and returns the state
    /// to restore. The stack bottom is the launch default destination
    /// (seeded by the root view); at the bottom, nil is returned and the
    /// caller restores the default view (AC-16).
    func goBack() -> NavigationEntry? {
        guard backEntries.count >= 2 else { return nil }
        guard let current = backEntries.popLast() else { return nil }
        forwardEntries.append(current)
        return backEntries.last
    }

    /// Pops the forward stack back onto the back stack and returns the
    /// state to restore.
    func goForward() -> NavigationEntry? {
        guard let entry = forwardEntries.popLast() else { return nil }
        backEntries.append(entry)
        return entry
    }

    /// Ends an in-flight search session (clicking a result or dismissing the
    /// field): the search entry is removed so back returns directly to the
    /// pre-search state — the whole session counts as one step (AC-15).
    func endSearchIfNeeded() {
        if case .search = backEntries.last {
            _ = backEntries.popLast()
        }
    }
}

// MARK: - Duplicate group ignore

extension AppModel {
    /// Marks (or unmarks) every Skill in the duplicate group identified by
    /// `fingerprint` as ignored, removing the group from the duplicates
    /// view. Persisted with SwiftData. Returns the number of records
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
        let updated = try index.setIgnoredNearDuplicateGroup(
            paths: group.members.map(\.snapshot.path),
            key: group.fingerprint,
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
