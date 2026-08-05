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

enum AppModelDocumentError: Error {
    case authorizationStorageUnavailable
    case noAuthorizedRoot
    case externalOpenFailed
}

enum AppModelOperationError: Error {
    case authorizationStorageUnavailable
    case operationAlreadyPending
    case noAuthorizedRoot
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
    private var registry: AgentRegistry
    private let builtInRegistry: AgentRegistry
    private let customAgentStore: any AgentDefinitionStoring
    private let documentManager: DocumentManager
    private let defaults: UserDefaults
    private let diagnosticStore: DiagnosticStore
    @ObservationIgnored private var activeRefresh: (id: UUID, task: Task<Void, Never>)?
    @ObservationIgnored private var pendingOperationContext: PendingOperationContext?

    var refreshState: RefreshState = .idle
    var selection: SkillSelection?
    private(set) var snapshots: [SkillSnapshot] = []
    private(set) var authorizedRoots: [AuthorizedRootSnapshot] = []
    private(set) var rootsByID: [String: AuthorizedRootSnapshot] = [:]
    private(set) var agentDefinitions: [AgentDefinition]
    private(set) var customAgentDefinitions: [AgentDefinition]
    var pendingOperationPlan: FileOperationPlan?
    var operationError: String?
    private(set) var isOperating = false
    var refreshOnLaunch: Bool {
        didSet { defaults.set(refreshOnLaunch, forKey: Self.refreshOnLaunchDefaultsKey) }
    }

    init(
        refresher: IndexRefresher,
        index: SkillIndex,
        bookmarks: BookmarkStore? = nil,
        registry: AgentRegistry,
        defaults: UserDefaults = .standard,
        customAgentStore: (any AgentDefinitionStoring)? = nil,
        diagnosticStore: DiagnosticStore = .shared
    ) {
        self.refresher = refresher
        self.index = index
        self.bookmarks = bookmarks
        self.documentManager = DocumentManager(bookmarks: bookmarks)
        builtInRegistry = registry
        self.defaults = defaults
        self.diagnosticStore = diagnosticStore
        let store = customAgentStore ?? UserDefaultsAgentDefinitionStore(defaults: defaults)
        self.customAgentStore = store
        let storedCustomDefinitions = (try? store.definitions()) ?? []
        customAgentDefinitions = storedCustomDefinitions
        var effectiveRegistry = registry
        effectiveRegistry.merge(customDefinitions: storedCustomDefinitions)
        self.registry = effectiveRegistry
        refreshOnLaunch = defaults.object(forKey: Self.refreshOnLaunchDefaultsKey) == nil
            ? true
            : defaults.bool(forKey: Self.refreshOnLaunchDefaultsKey)
        agentDefinitions = effectiveRegistry.definitions
        refresher.updateRegistry(effectiveRegistry)
        do {
            try reloadSnapshot()
        } catch {
            refreshState = .failed(String(describing: error))
        }
    }

    func checkEnvironment() async {
        await refresh(.startup)
    }

    func checkEnvironmentOnLaunch() async {
        do {
            guard refreshOnLaunch, try bookmarks?.roots().isEmpty == false else { return }
            await checkEnvironment()
        } catch {
            refreshState = .failed(String(describing: error))
        }
    }

    func authorize(_ url: URL, as kind: AuthorizedRootKind) async {
        guard let bookmarks else {
            refreshState = .failed(L10n.string("Authorization storage is unavailable"))
            return
        }
        await waitForActiveRefresh()
        guard pendingOperationPlan == nil, !isOperating else {
            operationError = L10n.string("Finish the current file operation first.")
            return
        }
        do {
            _ = try bookmarks.save(url: url, kind: kind)
            authorizedRoots = try bookmarks.roots()
            rootsByID = Dictionary(uniqueKeysWithValues: authorizedRoots.map { ($0.id, $0) })
            await refresh(.manual)
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
        guard SkillDocumentReader.isSimpleEntryFilename(finalEntry) else {
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

    func refresh(_ trigger: RefreshTrigger) async {
        guard pendingOperationPlan == nil,
              !isOperating else {
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
            await self.performRefresh(trigger)
        }
        activeRefresh = (id, task)
        await task.value
        clearRefresh(id: id)
    }

    var hasAuthorization: Bool {
        !authorizedRoots.isEmpty
    }

    var fileOperationCommandsDisabled: Bool {
        isOperating
            || pendingOperationPlan != nil
            || activeRefresh != nil
    }



    func planFileOperation(
        _ operation: FileOperationKind,
        for skill: SkillSnapshot,
        destinationRootURL: URL? = nil,
        conflictPolicy: FileConflictPolicy = .keepBoth
    ) async {
        await waitForActiveRefresh()
        guard pendingOperationPlan == nil,
              !isOperating else {
            operationError = L10n.string("Finish the current file operation first.")
            return
        }
        guard let bookmarks else {
            operationError = L10n.string("Authorization storage is unavailable")
            return
        }

        do {
            let rootIDs = operationAccessRootIDs(
                for: skill,
                destinationRootURL: destinationRootURL
            )
            guard !rootIDs.isEmpty else { throw AppModelOperationError.noAuthorizedRoot }
            var accesses: [AuthorizedRootAccess] = []
            var firstResolutionError: Error?
            for rootID in rootIDs {
                do {
                    accesses.append(try bookmarks.resolve(id: rootID))
                } catch {
                    firstResolutionError = firstResolutionError ?? error
                }
            }
            do {
                guard operationPathsAreCovered(
                    skill: skill,
                    destinationRootURL: destinationRootURL,
                    accesses: accesses
                ) else {
                    throw firstResolutionError ?? AppModelOperationError.noAuthorizedRoot
                }
                let currentRoots = try bookmarks.roots()
                let currentAliases = snapshots.map {
                    IndexedSkillAlias(
                        path: $0.path,
                        resolvedTarget: $0.resolvedTarget,
                        rootIDs: $0.rootIDs
                    )
                }
                let fileOperator = SkillFileOperator(
                    registryProvider: { [registry] in registry },
                    authorizedRootsProvider: { [currentRoots] in currentRoots },
                    indexedAliasesProvider: { [currentAliases] in currentAliases }
                )
                let request = FileOperationRequest(
                    operation: operation,
                    sourceURL: URL(fileURLWithPath: skill.path),
                    resolvedSourceURL: skill.resolvedTarget.map(URL.init(fileURLWithPath:)),
                    sourceEntryFilename: skill.entryFilename,
                    destinationRootURL: destinationRootURL,
                    proposedName: nil,
                    conflictPolicy: operation == .delete ? .fail : conflictPolicy,
                    metadata: SkillAppMetadata(customDescription: nil)
                )
                let plan = try fileOperator.plan(request)
                pendingOperationContext = PendingOperationContext(
                    fileOperator: fileOperator,
                    request: request,
                    authorizedRoots: currentRoots,
                    leases: accesses.map(\.lease)
                )
                pendingOperationPlan = plan
                operationError = nil
            } catch {
                accesses.forEach { $0.lease.close() }
                throw error
            }
        } catch {
            operationError = localizedOperationError(error)
        }
    }

    func updatePendingConflictPolicy(_ policy: FileConflictPolicy) {
        guard let context = pendingOperationContext,
              context.request.operation != .delete else { return }
        let request = FileOperationRequest(
            operation: context.request.operation,
            sourceURL: context.request.sourceURL,
            resolvedSourceURL: context.request.resolvedSourceURL,
            sourceEntryFilename: context.request.sourceEntryFilename,
            destinationRootURL: context.request.destinationRootURL,
            proposedName: context.request.proposedName,
            conflictPolicy: policy,
            metadata: context.request.metadata
        )
        do {
            pendingOperationPlan = try context.fileOperator.plan(request)
            pendingOperationContext?.request = request
            operationError = nil
        } catch {
            operationError = localizedOperationError(error)
        }
    }

    func cancelPendingFileOperation() {
        closePendingOperation()
    }

    func executePendingFileOperation(replacementConfirmed: Bool) async {
        guard let plan = pendingOperationPlan,
              let context = pendingOperationContext,
              !isOperating else {
            return
        }
        isOperating = true
        defer {
            isOperating = false
            closePendingOperation()
        }
        do {
            guard let bookmarks,
                  try bookmarks.roots() == context.authorizedRoots else {
                throw SkillFileOperatorError.authorizationChanged
            }
            let result = try await context.fileOperator.execute(
                plan,
                confirmation: plan.confirmationToken,
                replacementConfirmation: replacementConfirmed
                    ? plan.replacementConfirmationToken
                    : nil
            )
            guard result.outcome == .completed else { return }
            let summary = try await refresher.refresh(
                .manual,
                rootIDs: Set(result.refreshRootIDs)
            )
            try reloadSnapshot()
            if let destinationPath = result.destinationURL?.path {
                try index.applyOperationMetadataTransfer(
                    result.metadataTransfer,
                    to: destinationPath
                )
                try reloadSnapshot()
                if result.metadataTransfer.isMove {
                    selection = SkillSelection(path: destinationPath)
                }
            }
            refreshState = .finished(summary)
            operationError = nil
            diagnosticStore.record(
                category: .operations,
                code: "OPERATION_COMPLETED",
                message: "File operation completed",
                redactor: currentRedactor()
            )
        } catch {
            operationError = localizedOperationError(error)
            diagnosticStore.record(
                category: .operations,
                code: "OPERATION_FAILED",
                message: operationError ?? "File operation failed",
                redactor: currentRedactor()
            )
        }
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

    func saveCustomDescription(path: String, value: String?) throws {
        _ = try index.setCustomDescription(path: path, value: value)
        try reloadSnapshot()
    }

    func restoreDefaultDescription(path: String) throws {
        try saveCustomDescription(path: path, value: nil)
    }

    private func performRefresh(_ trigger: RefreshTrigger) async {
        refreshState = .running
        do {
            let summary = try await refresher.refresh(trigger)
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

    private static let refreshOnLaunchDefaultsKey = "SkillSelector.refreshOnLaunch"
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
                guard let bookmarks else { throw AppModelDocumentError.authorizationStorageUnavailable }
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

    private func reloadSnapshot() throws {
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

    private struct PendingOperationContext {
        let fileOperator: SkillFileOperator
        var request: FileOperationRequest
        let authorizedRoots: [AuthorizedRootSnapshot]
        let leases: [AccessLease]
    }


    private func closePendingOperation() {
        pendingOperationContext?.leases.forEach { $0.close() }
        pendingOperationContext = nil
        pendingOperationPlan = nil
    }


    private func operationAccessRootIDs(
        for skill: SkillSnapshot,
        destinationRootURL: URL?
    ) -> [String] {
        var ids = Set(skill.rootIDs)
        if let resolvedTarget = skill.resolvedTarget.map(URL.init(fileURLWithPath:)) {
            ids.formUnion(authorizedRoots.rootIDs(containingResolvedURL: resolvedTarget))
        }
        if let destinationRootURL {
            ids.formUnion(authorizedRoots.rootIDs(containingLogicalURL: destinationRootURL))
        }
        return ids.sorted()
    }

    private func operationPathsAreCovered(
        skill: SkillSnapshot,
        destinationRootURL: URL?,
        accesses: [AuthorizedRootAccess]
    ) -> Bool {
        let source = URL(fileURLWithPath: skill.path)
        let logicalSourceCovered = accesses.contains {
            source.isContained(in: $0.root.url.standardizedFileURL)
        }
        let resolvedSourceCovered = skill.resolvedTarget.map(URL.init(fileURLWithPath:)).map { target in
            accesses.contains {
                target.standardizedFileURL.isContained(
                    in: $0.root.url.resolvingSymlinksInPath().standardizedFileURL
                )
            }
        } ?? true
        let destinationCovered = destinationRootURL.map { destination in
            accesses.contains {
                destination.isContained(in: $0.root.url.standardizedFileURL)
            }
        } ?? true
        return logicalSourceCovered && resolvedSourceCovered && destinationCovered
    }



    private func localizedOperationError(_ error: Error) -> String {
        if let error = error as? AppModelOperationError {
            return switch error {
            case .authorizationStorageUnavailable:
                L10n.string("Authorization storage is unavailable")
            case .operationAlreadyPending:
                L10n.string("Finish the current file operation first.")
            case .noAuthorizedRoot:
                L10n.string("No authorized directory covers this operation.")
            }
        }
        guard let error = error as? SkillFileOperatorError else {
            return String(describing: error)
        }
        return switch error {
        case .sourceMissing: L10n.string("The source Skill no longer exists.")
        case .sourceChanged: L10n.string("The source Skill changed. Plan the operation again.")
        case .unauthorizedSource: L10n.string("The source Skill is not authorized.")
        case .unregisteredSource: L10n.string("The source is not in a registered Skill root.")
        case .resolvedSourceMismatch: L10n.string("The symbolic link target changed.")
        case .destinationRequired: L10n.string("Choose a destination Skill root.")
        case .unauthorizedDestination: L10n.string("The destination is not authorized.")
        case .unregisteredDestination: L10n.string("The destination is not a registered Skill root.")
        case .invalidName: L10n.string("The Skill name is not valid.")
        case .destinationConflict: L10n.string("A Skill with this name already exists.")
        case .destinationChanged: L10n.string("The destination changed. Plan the operation again.")
        case .authorizationChanged: L10n.string("Directory authorization changed. Plan the operation again.")
        case .registryChanged: L10n.string("The Agent registry changed. Plan the operation again.")
        case .invalidConfirmation, .invalidOrConsumedPlan:
            L10n.string("This confirmation is no longer valid.")
        case .replacementConfirmationRequired, .invalidReplacementConfirmation:
            L10n.string("Confirm replacement separately before continuing.")
        case .invalidStagedSkill: L10n.string("The staged copy is not a readable Skill.")
        case .filesystemFailure(let detail): String.localizedStringWithFormat(
            L10n.string("The file operation failed: %@"), detail
        )
        case .rollbackFailed(let original, let rollback): String.localizedStringWithFormat(
            L10n.string("The operation failed and rollback was incomplete: %@ (%@)"),
            original,
            rollback
        )
        }
    }


}

private extension FileOperationMetadataTransfer {
    var isMove: Bool {
        if case .move = self { return true }
        return false
    }
}
