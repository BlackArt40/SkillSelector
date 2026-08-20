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
    private let bookmarks: BookmarkStore?
    private(set) var registry: AgentRegistry
    private let builtInRegistry: AgentRegistry
    private let customAgentStore: any AgentDefinitionStoring
    private let documentManager: DocumentManager
    private let defaults: UserDefaults
    private let diagnosticStore: DiagnosticStore
    private let homeDirectory: URL
    let fileOperations: FileOperationCoordinator
    /// Test seam: pins the sandbox verdict that `isSandboxed` reads from the
    /// process environment, so unit tests can exercise the sandboxed path.
    var environmentIsSandboxed: Bool?
    @ObservationIgnored private var activeRefresh: (id: UUID, task: Task<Void, Never>)?
    @ObservationIgnored private var activeFingerprintBackfill: (id: UUID, task: Task<Void, Never>)?
    /// Paths whose deferred fingerprint failed to compute (unreadable
    /// content). They are not retried until the next refresh, when files
    /// may have changed — this keeps the schedule self-terminating.
    @ObservationIgnored private var fingerprintFailures: Set<String> = []

    var refreshState: RefreshState = .idle
    var selection: SkillSelection?
    /// Multi-select set for batch operations. Always contains the primary
    /// selection's path when one exists.
    private(set) var selectedPaths: Set<String> = []
    private var selectionAnchor: String?
    private(set) var showsOnboarding = false
    private(set) var snapshots: [SkillSnapshot] = []
    private(set) var authorizedRoots: [AuthorizedRootSnapshot] = []
    private(set) var rootsByID: [String: AuthorizedRootSnapshot] = [:]
    private(set) var agentDefinitions: [AgentDefinition]
    private(set) var customAgentDefinitions: [AgentDefinition]
    var autoScanHome: Bool {
        didSet { defaults.set(autoScanHome, forKey: Self.autoScanHomeDefaultsKey) }
    }
    private(set) var manuallyEnabledAgentIDs: Set<String> {
        didSet { defaults.set(manuallyEnabledAgentIDs.sorted(), forKey: Self.manuallyEnabledAgentsDefaultsKey) }
    }

    var pendingOperationPlan: FileOperationPlan? { fileOperations.pendingOperationPlan }
    var pendingBatchOperation: PendingBatchOperation? { fileOperations.pendingBatch }
    var operationError: String? {
        get { fileOperations.operationError }
        set { fileOperations.operationError = newValue }
    }
    var isOperating: Bool { fileOperations.isOperating }

    init(
        refresher: IndexRefresher,
        index: SkillIndex,
        bookmarks: BookmarkStore? = nil,
        registry: AgentRegistry,
        defaults: UserDefaults = .standard,
        customAgentStore: (any AgentDefinitionStoring)? = nil,
        diagnosticStore: DiagnosticStore = .shared,
        homeDirectory: URL = AppModel.realUserHomeDirectory()
    ) {
        self.refresher = refresher
        self.index = index
        self.bookmarks = bookmarks
        self.documentManager = DocumentManager(bookmarks: bookmarks)
        builtInRegistry = registry
        self.defaults = defaults
        self.diagnosticStore = diagnosticStore
        self.homeDirectory = homeDirectory
        let store = customAgentStore ?? UserDefaultsAgentDefinitionStore(defaults: defaults)
        self.customAgentStore = store
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
        refresher.updateRegistry(effectiveRegistry)
        fileOperations = FileOperationCoordinator(
            bookmarks: bookmarks,
            refresher: refresher,
            index: index,
            diagnosticStore: diagnosticStore
        )
        fileOperations.owner = self
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

    /// Whether the first-launch guide is eligible: it has not been shown
    /// yet and no folder is authorized. Upgrades that already carry roots
    /// never see it, and non-sandboxed dev builds authorize the home
    /// directory during the launch check before this is consulted.
    var shouldShowOnboarding: Bool {
        !defaults.bool(forKey: Self.onboardingShownDefaultsKey) && !hasAuthorization
    }

    /// Presents the onboarding sheet if eligible. Called after the launch
    /// check so the sheet cannot flash in builds that authorize silently.
    func presentOnboardingIfNeeded() {
        showsOnboarding = shouldShowOnboarding
    }

    /// Closes the onboarding sheet and records it as shown, so both
    /// completing and skipping the guide stop it from returning.
    func dismissOnboarding() {
        showsOnboarding = false
        defaults.set(true, forKey: Self.onboardingShownDefaultsKey)
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
        rootsByID = Dictionary(uniqueKeysWithValues: authorizedRoots.map { ($0.id, $0) })
    }

    func authorize(_ url: URL, as kind: AuthorizedRootKind) async {
        guard let bookmarks else {
            refreshState = .failed(L10n.string("Authorization storage is unavailable"))
            return
        }
        await waitForActiveRefresh()
        guard fileOperations.pendingOperationPlan == nil,
              fileOperations.pendingBatch == nil,
              !fileOperations.isOperating else {
            operationError = L10n.string("Finish the current file operation first.")
            return
        }
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
            _ = try bookmarks.save(url: url, kind: kind)
            try reloadAuthorizedRoots()
            await refresh()
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
        guard !fileOperationCommandsDisabled else { return }
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
        projectPatterns: [String],
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
        let resolvedPatterns = normalizedLines(projectPatterns)
        for template in resolvedRoots + resolvedPatterns {
            let stripped = template.replacingOccurrences(of: "*", with: "")
                .trimmingCharacters(in: .whitespaces)
            guard template != "/", template != "~", !stripped.isEmpty else {
                throw AppModelValidationError.invalidPathTemplate(template)
            }
        }

        let definition = AgentDefinition.custom(
            displayName: name,
            globalRoots: resolvedRoots,
            projectPatterns: resolvedPatterns,
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

    /// Writes the custom Agent definitions to a local JSON file so they can
    /// move to another machine (UserDefaults stays behind otherwise).
    func exportCustomAgents(to url: URL) throws {
        try CustomAgentTransfer().archive(customAgentDefinitions).write(to: url, options: .atomic)
    }

    /// Imports definitions from a transfer file. Definitions whose id
    /// already exists are skipped untouched; new ones are appended.
    func importCustomAgents(from url: URL) throws -> (imported: Int, skipped: Int) {
        let candidates = try CustomAgentTransfer().parse(Data(contentsOf: url))
        let existing = Set(customAgentDefinitions.map(\.id))
        var imported = 0
        for candidate in candidates where !existing.contains(candidate.id) {
            try customAgentStore.insert(candidate)
            imported += 1
        }
        if imported > 0 {
            try reloadAgentDefinitions()
        }
        return (imported, candidates.count - imported)
    }

    /// Previews which directories the draft project patterns would match in
    /// the authorized project folders. Read-only: nothing is indexed or
    /// refreshed. Security-scoped accesses are resolved on the main actor and
    /// held for the duration of the background walk.
    func dryRunProjectPatterns(
        patterns: [String],
        entryFilename: String
    ) async -> PatternDryRunReport {
        guard let bookmarks else {
            return PatternDryRunReport(matches: [], skippedRootPaths: [])
        }
        let projectRoots = authorizedRoots.filter { $0.kind == .project }
        guard !projectRoots.isEmpty else {
            return PatternDryRunReport(matches: [], skippedRootPaths: [])
        }

        var accesses: [AuthorizedRootAccess] = []
        var unresolvablePaths: [String] = []
        for root in projectRoots {
            do {
                accesses.append(try bookmarks.resolve(id: root.id))
            } catch {
                unresolvablePaths.append(root.url.path)
            }
        }
        defer { accesses.forEach { $0.lease.close() } }

        let roots = accesses.map(\.root)
        let runner = PatternDryRunner()
        let report = await Task.detached(priority: .userInitiated) {
            runner.run(patterns: patterns, roots: roots, entryFilename: entryFilename)
        }.value
        guard unresolvablePaths.isEmpty else {
            return PatternDryRunReport(
                matches: report.matches,
                skippedRootPaths: report.skippedRootPaths + unresolvablePaths
            )
        }
        return report
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
        guard fileOperations.pendingOperationPlan == nil,
              fileOperations.pendingBatch == nil,
              !fileOperations.isOperating else {
            return
        }
        if let activeRefresh {
            await activeRefresh.task.value
            clearRefresh(id: activeRefresh.id)
            return
        }

        let id = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performRefresh()
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

    var fileOperationCommandsDisabled: Bool {
        fileOperations.isOperating
            || fileOperations.pendingOperationPlan != nil
            || fileOperations.pendingBatch != nil
            || activeRefresh != nil
    }



    func planFileOperation(
        _ operation: FileOperationKind,
        for skill: SkillSnapshot,
        destinationRootURL: URL? = nil,
        conflictPolicy: FileConflictPolicy = .keepBoth,
        destinationIsArbitrary: Bool = false
    ) async {
        await waitForActiveRefresh()
        await fileOperations.plan(
            operation,
            for: skill,
            destinationRootURL: destinationRootURL,
            conflictPolicy: conflictPolicy,
            destinationIsArbitrary: destinationIsArbitrary
        )
    }

    func updatePendingConflictPolicy(_ policy: FileConflictPolicy) {
        fileOperations.updateConflictPolicy(policy)
    }

    func cancelPendingFileOperation() {
        fileOperations.cancelPending()
    }

    func executePendingFileOperation(replacementConfirmed: Bool) async {
        await fileOperations.execute(replacementConfirmed: replacementConfirmed)
    }

    func planBatchFileOperation(
        _ operation: FileOperationKind,
        for skills: [SkillSnapshot],
        destinationRootURL: URL? = nil,
        destinationIsArbitrary: Bool = false
    ) async {
        await waitForActiveRefresh()
        await fileOperations.planBatch(
            operation,
            for: skills,
            destinationRootURL: destinationRootURL,
            destinationIsArbitrary: destinationIsArbitrary
        )
    }

    func cancelPendingBatchOperation() {
        fileOperations.cancelPendingBatch()
    }

    func executePendingBatchOperation() async {
        await fileOperations.executePendingBatch()
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

    private func performRefresh() async {
        refreshState = .running
        // Files may have changed since the last backfill attempt; give
        // previously failed paths another chance.
        fingerprintFailures = []
        do {
            let summary = try await refresher.refresh()
            try reloadSnapshot()
            refreshState = .finished(summary)
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

    // MARK: Deferred fingerprint backfill

    /// Computes the content fingerprints the scan deferred (its dominant
    /// I/O cost) off the critical path: the list is already on screen, and
    /// the duplicate view fills in when this lands. Read-only aside from
    /// the write-back into the index.
    func backfillMissingFingerprints() async {
        let pending = snapshots.filter {
            $0.contentFingerprint == nil && !fingerprintFailures.contains($0.path)
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
            (path: skill.path, directory: skill.resolvedTarget ?? skill.path)
        }
        let outcome = await Task.detached(priority: .utility) {
            () -> (fingerprints: [String: String], failures: [String]) in
            var fingerprints: [String: String] = [:]
            var failures: [String] = []
            for target in targets {
                if Task.isCancelled { break }
                do {
                    fingerprints[target.path] = try SkillContentFingerprint.compute(
                        rootDirectory: URL(fileURLWithPath: target.directory)
                    )
                } catch {
                    failures.append(target.path)
                }
            }
            return (fingerprints, failures)
        }.value
        // Cancelled mid-hash (a newer scan or backfill replaced this one):
        // drop everything, the replacement recomputes.
        guard !Task.isCancelled else { return }

        fingerprintFailures.formUnion(outcome.failures)
        do {
            let updated = try index.backfillContentFingerprints(outcome.fingerprints)
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

    /// Fires the background backfill when any snapshot is still missing
    /// its fingerprint. Replaces an in-flight backfill — its hashes may
    /// predate the scan that just reloaded the snapshots.
    private func scheduleFingerprintBackfillIfNeeded() {
        guard snapshots.contains(where: {
            $0.contentFingerprint == nil && !fingerprintFailures.contains($0.path)
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

    private static let autoScanHomeDefaultsKey = "SkillSelector.autoScanHome"
    private static let manuallyEnabledAgentsDefaultsKey = "SkillSelector.manuallyEnabledAgents"
    private static let onboardingShownDefaultsKey = "SkillSelector.onboardingShown"
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
        rootsByID = Dictionary(uniqueKeysWithValues: updatedRoots.map { ($0.id, $0) })
        reloadBookmarkHealth()
        selectedPaths = selectedPaths.filter { path in
            updatedSnapshots.contains { $0.path == path }
        }
        if let selection,
           !updatedSnapshots.contains(where: { $0.path == selection.path }) {
            self.selection = selectedPaths.sorted().first.map(SkillSelection.init(path:))
        }
        if let selectionAnchor,
           !updatedSnapshots.contains(where: { $0.path == selectionAnchor }) {
            self.selectionAnchor = nil
        }
        scheduleFingerprintBackfillIfNeeded()
    }
}

extension AppModel: FileOperationCoordinatorOwner {
    func updateSelection(to path: String?) {
        selectOnly(path)
    }

    func setRefreshState(_ state: RefreshState) {
        refreshState = state
    }

    func makeRedactor() -> Redactor {
        currentRedactor()
    }
}

// MARK: - Selection

extension AppModel {
    /// Plain click / keyboard navigation: single selection.
    func selectOnly(_ path: String?) {
        guard let path else {
            selection = nil
            selectedPaths = []
            selectionAnchor = nil
            return
        }
        selection = SkillSelection(path: path)
        selectedPaths = [path]
        selectionAnchor = path
    }

    /// ⌘-click: toggle membership; the primary selection follows the last
    /// touched row (or the first remaining member when it was removed).
    func toggleSelection(_ path: String) {
        if selectedPaths.contains(path) {
            selectedPaths.remove(path)
            if selection?.path == path {
                selection = selectedPaths.sorted().first.map(SkillSelection.init(path:))
            }
        } else {
            selectedPaths.insert(path)
            selection = SkillSelection(path: path)
        }
        selectionAnchor = path
    }

    /// Shift-click: range from the anchor to the tapped row, in the visible
    /// list order the caller provides.
    func selectRange(to path: String, in orderedPaths: [String]) {
        guard let anchor = selectionAnchor ?? selection?.path,
              let anchorIndex = orderedPaths.firstIndex(of: anchor),
              let targetIndex = orderedPaths.firstIndex(of: path) else {
            selectOnly(path)
            return
        }
        selectedPaths = Set(orderedPaths[min(anchorIndex, targetIndex)...max(anchorIndex, targetIndex)])
        selection = SkillSelection(path: path)
    }

    var hasMultiSelection: Bool {
        selectedPaths.count > 1
    }

    var multiSelectedSkills: [SkillSnapshot] {
        snapshots.filter { selectedPaths.contains($0.path) }
    }
}
