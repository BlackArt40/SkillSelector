import AppKit
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
    @ObservationIgnored private var activeRefresh: (id: UUID, task: Task<Void, Never>)?

    var refreshState: RefreshState = .idle
    var selection: SkillSelection?
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
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
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
        guard persistedHomeRoot == nil else { return }
        do {
            _ = try bookmarks.save(url: homeDirectory, kind: .home)
            try reloadAuthorizedRoots()
        } catch {
            // Non-fatal: auto-scan is best-effort.
        }
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

    func exportDiagnostics(to url: URL) async throws {
        let input = DiagnosticExportInput(
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                ?? "development",
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            registryIDs: agentDefinitions.map(\.id),
            roots: diagnosticRootSummaries(),
            diagnostics: diagnosticStore.recent()
        )
        try DiagnosticExporter(redactor: currentRedactor()).write(input, to: url)
    }

    func refresh() async {
        guard fileOperations.pendingOperationPlan == nil,
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

    var fileOperationCommandsDisabled: Bool {
        fileOperations.isOperating
            || fileOperations.pendingOperationPlan != nil
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
            ?? FileManager.default.homeDirectoryForCurrentUser
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
        if let selection,
           !updatedSnapshots.contains(where: { $0.path == selection.path }) {
            self.selection = nil
        }
    }
}

extension AppModel: FileOperationCoordinatorOwner {
    func updateSelection(to path: String?) {
        selection = path.map(SkillSelection.init(path:))
    }

    func setRefreshState(_ state: RefreshState) {
        refreshState = state
    }

    func makeRedactor() -> Redactor {
        currentRedactor()
    }
}
