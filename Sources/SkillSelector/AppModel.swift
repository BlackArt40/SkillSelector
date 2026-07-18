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

struct SkillSelection: Hashable, Identifiable {
    let path: String
    var id: String { path }
}

struct EnrichmentCandidateGroup: Identifiable, Hashable {
    let skillPath: String
    let skillName: String
    let candidates: [MetadataCandidate]
    var id: String { skillPath }
}

@MainActor
@Observable
final class AppModel {
    private let refresher: IndexRefresher
    private let index: SkillIndex
    private let bookmarks: BookmarkStore?
    private var registry: AgentRegistry
    private let builtInAgentDefinitions: [AgentDefinition]
    private let customAgentStore: any AgentDefinitionStoring
    private let toolLocator: ToolLocator
    private let commandRunner: any CommandRunning
    private let defaults: UserDefaults
    private let diagnosticStore: DiagnosticStore
    @ObservationIgnored private var activeRefresh: (id: UUID, task: Task<Void, Never>)?
    @ObservationIgnored private var pendingOperationContext: PendingOperationContext?
    @ObservationIgnored private var pendingUpdateContext: PendingUpdateContext?
    @ObservationIgnored private var remainingEnrichmentGroups: [EnrichmentCandidateGroup] = []
    @ObservationIgnored private var enrichmentTotalCount = 0
    @ObservationIgnored private var completedEnrichmentCount = 0

    var refreshState: RefreshState = .idle
    var selection: SkillSelection?
    private(set) var snapshots: [SkillSnapshot] = []
    private(set) var authorizedRoots: [AuthorizedRootSnapshot] = []
    private(set) var rootsByID: [String: AuthorizedRootSnapshot] = [:]
    private(set) var agentDefinitions: [AgentDefinition]
    private(set) var customAgentDefinitions: [AgentDefinition]
    private(set) var toolStatuses: [ToolKind: ToolLocation] = [:]
    var pendingOperationPlan: FileOperationPlan?
    var operationError: String?
    private(set) var isOperating = false
    private(set) var isEnriching = false
    var pendingEnrichmentGroup: EnrichmentCandidateGroup?
    var enrichmentError: String?
    var pendingUpdateProposal: UpdateProposal?
    var updateError: String?
    private(set) var isUpdating = false
    var enrichMissingDescriptionsAfterRefresh: Bool {
        didSet {
            defaults.set(
                enrichMissingDescriptionsAfterRefresh,
                forKey: Self.enrichAfterRefreshDefaultsKey
            )
        }
    }
    var refreshOnLaunch: Bool {
        didSet { defaults.set(refreshOnLaunch, forKey: Self.refreshOnLaunchDefaultsKey) }
    }

    init(
        refresher: IndexRefresher,
        index: SkillIndex,
        bookmarks: BookmarkStore? = nil,
        registry: AgentRegistry,
        toolLocator: ToolLocator = ToolLocator(),
        commandRunner: any CommandRunning = ExternalCommandRunner(),
        defaults: UserDefaults = .standard,
        customAgentStore: (any AgentDefinitionStoring)? = nil,
        diagnosticStore: DiagnosticStore = .shared
    ) {
        self.refresher = refresher
        self.index = index
        self.bookmarks = bookmarks
        builtInAgentDefinitions = registry.definitions
        self.toolLocator = toolLocator
        self.commandRunner = commandRunner
        self.defaults = defaults
        self.diagnosticStore = diagnosticStore
        let store = customAgentStore ?? UserDefaultsAgentDefinitionStore(defaults: defaults)
        self.customAgentStore = store
        let storedCustomDefinitions = (try? store.definitions()) ?? []
        customAgentDefinitions = storedCustomDefinitions
        var effectiveRegistry = registry
        effectiveRegistry.merge(customDefinitions: storedCustomDefinitions)
        self.registry = effectiveRegistry
        enrichMissingDescriptionsAfterRefresh = defaults.bool(
            forKey: Self.enrichAfterRefreshDefaultsKey
        )
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

    func detectTools() async {
        async let gh = toolLocator.locate(ToolKind.gh.rawValue)
        async let npm = toolLocator.locate(ToolKind.npm.rawValue)
        let values = await [gh, npm]
        toolStatuses = Dictionary(uniqueKeysWithValues: values.map { ($0.kind, $0) })
        diagnosticStore.record(
            category: .commands,
            code: "TOOLS_CHECKED",
            message: "Checked gh and npm availability",
            redactor: currentRedactor()
        )
    }

    func discoverMCPConfigurations() throws -> [MCPServerConfiguration] {
        guard let bookmarks,
              let homeRoot = try bookmarks.roots().first(where: { $0.kind == .home }) else {
            return []
        }
        let access = try bookmarks.resolve(id: homeRoot.id)
        defer { access.lease.close() }
        return try MCPConfigDiscovery().discover(in: access.root.url)
    }

    func loadMCPTools(configuration: MCPServerConfiguration) async throws -> [MCPTool] {
        guard let bookmarks,
              let homeRoot = try bookmarks.roots().first(where: { $0.kind == .home }) else {
            throw MCPClientError.disabled
        }
        let access = try bookmarks.resolve(id: homeRoot.id)
        defer { access.lease.close() }
        let client: any MCPClient
        switch configuration.transport {
        case .stdio:
            client = StdioMCPClient(
                configuration: configuration,
                approval: CommandApproval(),
                authorizedHomeURL: access.root.url
            )
        case .streamableHTTP:
            client = HTTPMCPClient(configuration: configuration)
        case .legacySSE:
            throw MCPClientError.unsupportedTransport
        }
        do {
            let tools = try await client.listTools()
            await client.close()
            return tools
        } catch {
            await client.close()
            throw error
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

    func saveCustomAgent(
        displayName: String,
        globalRoots: [String],
        projectPatterns: [String],
        entryFilename: String
    ) throws {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let slug = name.lowercased().map { character -> Character in
            character.isLetter || character.isNumber ? character : "-"
        }
        let id = "custom-" + String(slug)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        let definition = AgentDefinition(
            id: id,
            displayName: name,
            globalRoots: normalizedLines(globalRoots),
            projectPatterns: normalizedLines(projectPatterns),
            entryFilename: entryFilename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "SKILL.md"
                : entryFilename.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        try customAgentStore.save(definition)
        try reloadAgentDefinitions()
    }

    func removeCustomAgent(id: String) throws {
        try customAgentStore.remove(id: id)
        try reloadAgentDefinitions()
    }

    func exportDiagnostics(to url: URL) async throws {
        if toolStatuses.isEmpty { await detectTools() }
        let input = DiagnosticExportInput(
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                ?? "development",
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            registryIDs: agentDefinitions.map(\.id),
            roots: diagnosticRootSummaries(),
            tools: ToolKind.allCases.map { kind in
                let status = toolStatuses[kind]
                return DiagnosticToolSummary(
                    kind: kind,
                    state: status?.state ?? .unavailable,
                    version: status?.version
                )
            },
            diagnostics: diagnosticStore.recent()
        )
        try DiagnosticExporter(redactor: currentRedactor()).write(input, to: url)
    }

    func refresh(_ trigger: RefreshTrigger) async {
        guard pendingOperationPlan == nil,
              !isOperating,
              !isEnriching,
              pendingEnrichmentGroup == nil else {
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
            || isEnriching
            || pendingEnrichmentGroup != nil
            || isUpdating
            || pendingUpdateProposal != nil
            || activeRefresh != nil
    }

    var enrichmentCommandsDisabled: Bool {
        isEnriching
            || pendingEnrichmentGroup != nil
            || isOperating
            || pendingOperationPlan != nil
            || isUpdating
            || pendingUpdateProposal != nil
            || activeRefresh != nil
    }

    var pendingEnrichmentPosition: (current: Int, total: Int) {
        (completedEnrichmentCount + 1, enrichmentTotalCount)
    }

    func enrich(_ skills: [SkillSnapshot]) async {
        await waitForActiveRefresh()
        guard !isEnriching,
              pendingEnrichmentGroup == nil,
              !isOperating,
              pendingOperationPlan == nil,
              !isUpdating,
              pendingUpdateProposal == nil else {
            return
        }
        await performEnrichment(for: skills)
    }

    func applyEnrichmentCandidate(_ candidate: MetadataCandidate, bindSource: Bool) {
        guard let group = pendingEnrichmentGroup else { return }
        do {
            let validatedSourceBinding: String?
            if bindSource, let binding = candidate.sourceBinding {
                validatedSourceBinding = try SkillSource.remembered(binding: binding).binding
            } else {
                validatedSourceBinding = nil
            }
            _ = try index.setEnrichedDescription(
                path: group.skillPath,
                value: candidate.description,
                provenance: "\(candidate.provider.rawValue):\(candidate.evidenceURL.absoluteString)"
            )
            if let validatedSourceBinding {
                _ = try index.setSourceBinding(
                    path: group.skillPath,
                    value: validatedSourceBinding
                )
            }
            try reloadSnapshot()
            advanceEnrichmentQueue()
            enrichmentError = nil
        } catch {
            enrichmentError = String(describing: error)
        }
    }

    func skipPendingEnrichmentCandidate() {
        advanceEnrichmentQueue()
    }

    func cancelPendingEnrichment() {
        pendingEnrichmentGroup = nil
        remainingEnrichmentGroups.removeAll()
        enrichmentTotalCount = 0
        completedEnrichmentCount = 0
    }

    func checkForUpdate(_ skill: SkillSnapshot) async {
        await waitForActiveRefresh()
        guard pendingUpdateProposal == nil,
              !isUpdating,
              !isOperating,
              pendingOperationPlan == nil,
              !isEnriching,
              pendingEnrichmentGroup == nil else {
            return
        }
        guard let binding = skill.sourceBinding,
              let digest = skill.digest,
              let bookmarks else {
            updateError = L10n.string("This Skill does not have a confirmed update source and indexed digest.")
            return
        }

        do {
            let source = try SkillSource.remembered(binding: binding)
            let documentAccess = try resolveDocumentAccess(for: skill)
            var heldUpdateLeases = documentAccess.leases
            var transfersDocumentLeases = false
            defer {
                if !transfersDocumentLeases {
                    heldUpdateLeases.forEach { $0.close() }
                }
            }
            let authorizationSnapshot = try bookmarks.roots()
            let actualTargetPath = (skill.resolvedTarget ?? skill.path)
            let aliasRootIDs = Set(snapshots
                .filter { $0.resolvedTarget == actualTargetPath }
                .flatMap(\.rootIDs))
            let knownRootIDs = Set(operationAccessRootIDs(for: skill, destinationRootURL: nil))
            for rootID in aliasRootIDs.subtracting(knownRootIDs).sorted() {
                heldUpdateLeases.append(try bookmarks.resolve(id: rootID).lease)
            }
            let updateRootIDs = (knownRootIDs.union(aliasRootIDs)).sorted()
            let ghAccess: ToolAccess?
            let fetcher: LiveSkillPackageFetcher
            if source.kind == .github {
                guard let homeRoot = authorizationSnapshot.first(where: { $0.kind == .home }) else {
                    throw AppModelOperationError.noAuthorizedRoot
                }
                let homeAccess = try bookmarks.resolve(id: homeRoot.id)
                let ghResult = await toolLocator.openAccess(.gh, authorizedHomeAccess: homeAccess)
                guard let access = ghResult.access else {
                    throw SkillUpdateError.unsupportedSource
                }
                ghAccess = access
                fetcher = LiveSkillPackageFetcher(toolAccess: access, runner: commandRunner)
            } else {
                ghAccess = nil
                fetcher = LiveSkillPackageFetcher()
            }
            var transfersToolAccess = false
            defer {
                if !transfersToolAccess { ghAccess?.close() }
            }
            let updater = SkillUpdater(
                fetcher: fetcher,
                aliasesProvider: { [snapshots] in
                    snapshots.map {
                        IndexedSkillAlias(
                            path: $0.path,
                            resolvedTarget: $0.resolvedTarget,
                            rootIDs: $0.rootIDs
                        )
                    }
                }
            )
            let proposal = try await updater.check(UpdateRequest(
                installationURL: documentAccess.request.installationURL,
                resolvedTargetURL: documentAccess.request.resolvedTargetURL,
                entryFilename: skill.entryFilename,
                requiredName: skill.name,
                source: source,
                indexedDigest: PackageDigest(value: digest),
                authorizedRootURLs: documentAccess.request.authorizedRootURLs,
                refreshRootIDs: operationAccessRootIDs(for: skill, destinationRootURL: nil)
            ))
            pendingUpdateContext = PendingUpdateContext(
                updater: updater,
                rootIDs: updateRootIDs,
                authorizedRoots: authorizationSnapshot,
                leases: heldUpdateLeases,
                toolAccess: ghAccess
            )
            pendingUpdateProposal = proposal
            transfersDocumentLeases = true
            transfersToolAccess = true
            updateError = nil
        } catch {
            updateError = localizedUpdateError(error)
        }
    }

    func cancelPendingUpdate() {
        guard !isUpdating else { return }
        closePendingUpdate()
    }

    func applyPendingUpdate(allowLocalChanges: Bool) async {
        guard let proposal = pendingUpdateProposal,
              let context = pendingUpdateContext,
              !isUpdating else { return }
        isUpdating = true
        defer { isUpdating = false }
        do {
            guard let bookmarks,
                  try bookmarks.roots() == context.authorizedRoots else {
                throw SkillFileOperatorError.authorizationChanged
            }
            let result = try await context.updater.apply(
                proposal.confirmed(allowLocalChanges: allowLocalChanges)
            )
            switch result {
            case .confirmationRequired:
                return
            case .localChangesRequireConfirmation(let warning):
                pendingUpdateProposal = warning
            case .updated:
                let summary = try await refresher.refresh(
                    .manual,
                    rootIDs: Set(result.affectedRootIDs)
                )
                try reloadSnapshot()
                refreshState = .finished(summary)
                updateError = nil
                diagnosticStore.record(
                    category: .updates,
                    code: "UPDATE_COMPLETED",
                    message: "Skill update completed",
                    redactor: currentRedactor()
                )
                closePendingUpdate()
            }
        } catch {
            updateError = localizedUpdateError(error)
            diagnosticStore.record(
                category: .updates,
                code: "UPDATE_FAILED",
                message: updateError ?? "Skill update failed",
                redactor: currentRedactor()
            )
            closePendingUpdate()
        }
    }

    func planFileOperation(
        _ operation: FileOperationKind,
        for skill: SkillSnapshot,
        destinationRootURL: URL? = nil,
        conflictPolicy: FileConflictPolicy = .keepBoth
    ) async {
        await waitForActiveRefresh()
        guard pendingOperationPlan == nil,
              !isOperating,
              !isEnriching,
              pendingEnrichmentGroup == nil else {
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
                    metadata: try index.appMetadata(path: skill.path)
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
              !isOperating,
              !isEnriching,
              pendingEnrichmentGroup == nil else {
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
        let access = try resolveDocumentAccess(for: skill)
        defer { access.leases.forEach { $0.close() } }
        let request = access.request

        let readTask = Task.detached(priority: .userInitiated) {
            try SkillDocumentReader().read(request)
        }
        return try await withTaskCancellationHandler {
            try await readTask.value
        } onCancel: {
            readTask.cancel()
        }
    }

    func revealDocumentInFinder(for skill: SkillSnapshot) throws {
        try withDocumentAccess(for: skill) { request in
            let fileURL = try SkillDocumentReader().validatedEntryURL(request)
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        }
    }

    func openDocumentInDefaultEditor(for skill: SkillSnapshot) throws {
        try withDocumentAccess(for: skill) { request in
            let fileURL = try SkillDocumentReader().validatedEntryURL(request)
            guard NSWorkspace.shared.open(fileURL) else {
                throw AppModelDocumentError.externalOpenFailed
            }
        }
    }

    func saveCustomDescription(path: String, value: String?) throws {
        _ = try index.setCustomDescription(path: path, value: value)
        try reloadSnapshot()
    }

    func restoreDefaultDescription(path: String) throws {
        try saveCustomDescription(path: path, value: nil)
    }

    func confirmDiscoveredSource(path: String, binding: String) {
        do {
            let source = try SkillSource.remembered(binding: binding)
            _ = try index.setSourceBinding(path: path, value: source.binding)
            try reloadSnapshot()
            updateError = nil
        } catch {
            updateError = localizedSourceBindingError(error)
        }
    }

    func confirmDirectPackageSource(path: String, value: String) {
        do {
            guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw SkillSourceError.invalidDirectPackageURL
            }
            let source = try SkillSource.userConfirmed(candidate: .directPackage(url))
            _ = try index.setSourceBinding(path: path, value: source.binding)
            try reloadSnapshot()
            updateError = nil
        } catch {
            updateError = localizedSourceBindingError(error)
        }
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
            if enrichMissingDescriptionsAfterRefresh {
                let refreshedSnapshots = snapshots
                let missing = refreshedSnapshots.filter {
                    Self.isMissingDescription($0.customDescription)
                        && Self.isMissingDescription($0.localDescription)
                        && Self.isMissingDescription($0.enrichedDescription)
                }
                if !missing.isEmpty {
                    await performEnrichment(for: missing)
                }
            }
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

    private func performEnrichment(for skills: [SkillSnapshot]) async {
        let eligible = skills.filter { $0.availability == .available }
        guard !eligible.isEmpty else {
            enrichmentError = L10n.string("No metadata candidates were found.")
            return
        }
        isEnriching = true
        defer { isEnriching = false }

        guard let bookmarks else {
            enrichmentError = L10n.string("No supported metadata tool is available.")
            return
        }
        let homeRoot: AuthorizedRootSnapshot
        do {
            guard let resolvedHomeRoot = try bookmarks.roots().first(where: { $0.kind == .home }) else {
                enrichmentError = L10n.string("No supported metadata tool is available.")
                return
            }
            homeRoot = resolvedHomeRoot
        } catch {
            enrichmentError = String(describing: error)
            return
        }
        let ghHomeAccess: AuthorizedRootAccess
        do {
            ghHomeAccess = try bookmarks.resolve(id: homeRoot.id)
        } catch {
            enrichmentError = String(describing: error)
            return
        }
        let gh = await toolLocator.openAccess(
            .gh,
            authorizedHomeAccess: ghHomeAccess
        )
        let npmHomeAccess: AuthorizedRootAccess
        do {
            npmHomeAccess = try bookmarks.resolve(id: homeRoot.id)
        } catch {
            gh.access?.close()
            enrichmentError = String(describing: error)
            return
        }
        let npm = await toolLocator.openAccess(
            .npm,
            authorizedHomeAccess: npmHomeAccess
        )
        let mcpHomeAccess = try? bookmarks.resolve(id: homeRoot.id)
        defer {
            gh.access?.close()
            npm.access?.close()
            mcpHomeAccess?.lease.close()
        }
        var providers: [any MetadataProvider] = []
        if let access = gh.access {
            providers.append(GitHubMetadataProvider(
                toolAccess: access,
                runner: commandRunner
            ))
        }
        if let access = npm.access {
            providers.append(NPMMetadataProvider(
                toolAccess: access,
                runner: commandRunner
            ))
        }
        if let mcpHomeAccess {
            let provider = MCPMetadataProvider(
                rootURL: mcpHomeAccess.root.url,
                authorizedHomeURL: mcpHomeAccess.root.url
            )
            if provider.hasEnabledConfiguration() {
                providers.append(provider)
            }
        }
        guard !providers.isEmpty else {
            enrichmentError = gh.location.state == .unauthenticated
                ? L10n.string("GitHub CLI is not authenticated and npm is unavailable.")
                : L10n.string("No supported metadata tool is available.")
            return
        }

        var candidateCache: [String: [MetadataCandidate]] = [:]
        var groups: [EnrichmentCandidateGroup] = []
        var firstError: Error?
        for skill in eligible {
            let candidates: [MetadataCandidate]
            if let cached = candidateCache[skill.name] {
                candidates = cached
            } else {
                var collected: [MetadataCandidate] = []
                for provider in providers {
                    do {
                        collected.append(contentsOf: try await provider.candidates(
                            for: MetadataQuery(name: skill.name)
                        ))
                    } catch {
                        firstError = firstError ?? error
                    }
                }
                candidates = collected
                candidateCache[skill.name] = collected
            }
            if !candidates.isEmpty {
                groups.append(EnrichmentCandidateGroup(
                    skillPath: skill.path,
                    skillName: skill.name,
                    candidates: candidates
                ))
            }
        }
        guard let first = groups.first else {
            enrichmentError = firstError.map(localizedEnrichmentError)
                ?? L10n.string("No metadata candidates were found.")
            return
        }
        pendingEnrichmentGroup = first
        remainingEnrichmentGroups = Array(groups.dropFirst())
        enrichmentTotalCount = groups.count
        completedEnrichmentCount = 0
        enrichmentError = nil
        diagnosticStore.record(
            category: .enrichment,
            code: "ENRICHMENT_READY",
            message: "Metadata candidates are ready",
            redactor: currentRedactor()
        )
    }

    private func advanceEnrichmentQueue() {
        completedEnrichmentCount += 1
        pendingEnrichmentGroup = remainingEnrichmentGroups.first
        if !remainingEnrichmentGroups.isEmpty {
            remainingEnrichmentGroups.removeFirst()
        }
        if pendingEnrichmentGroup == nil {
            enrichmentTotalCount = 0
            completedEnrichmentCount = 0
        }
    }

    private func localizedEnrichmentError(_ error: Error) -> String {
        guard let error = error as? MetadataProviderError else {
            return String(describing: error)
        }
        return switch error {
        case .invalidQuery:
            L10n.string("The Skill name cannot be used for metadata lookup.")
        case .invalidResponse:
            L10n.string("A metadata tool returned an invalid response.")
        case .rateLimited:
            L10n.string("The metadata service rate limit was reached.")
        case .unauthenticated:
            L10n.string("GitHub CLI is not authenticated.")
        case .commandFailed:
            L10n.string("The metadata command failed.")
        }
    }

    private static func isMissingDescription(_ value: String?) -> Bool {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
    }

    private static let enrichAfterRefreshDefaultsKey =
        "SkillSelector.enrichMissingDescriptionsAfterRefresh"
    private static let refreshOnLaunchDefaultsKey = "SkillSelector.refreshOnLaunch"

    private func reloadAgentDefinitions() throws {
        customAgentDefinitions = try customAgentStore.definitions()
        registry = AgentRegistry(
            definitions: builtInAgentDefinitions,
            customDefinitions: customAgentDefinitions
        )
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

    private func withDocumentAccess<Result>(
        for skill: SkillSnapshot,
        operation: (SkillDocumentRequest) throws -> Result
    ) throws -> Result {
        let access = try resolveDocumentAccess(for: skill)
        defer { access.leases.forEach { $0.close() } }
        return try operation(access.request)
    }

    private func resolveDocumentAccess(
        for skill: SkillSnapshot
    ) throws -> (request: SkillDocumentRequest, leases: [AccessLease]) {
        guard let bookmarks else {
            throw AppModelDocumentError.authorizationStorageUnavailable
        }

        var requiredRootIDs = Set(skill.rootIDs)
        if let resolvedTarget = skill.resolvedTarget.map(URL.init(fileURLWithPath:)) {
            requiredRootIDs.formUnion(rootIDs(containingResolvedURL: resolvedTarget))
        }
        var accesses: [AuthorizedRootAccess] = []
        var firstResolutionError: Error?
        for rootID in requiredRootIDs.sorted() {
            do {
                accesses.append(try bookmarks.resolve(id: rootID))
            } catch {
                firstResolutionError = firstResolutionError ?? error
            }
        }
        guard !accesses.isEmpty else {
            if let firstResolutionError { throw firstResolutionError }
            throw AppModelDocumentError.noAuthorizedRoot
        }
        let installationURL = URL(fileURLWithPath: skill.path)
        let logicalCovered = accesses.contains {
            Self.contains(installationURL, in: $0.root.url.standardizedFileURL)
        }
        let targetCovered = skill.resolvedTarget.map(URL.init(fileURLWithPath:)).map { target in
            accesses.contains {
                Self.contains(
                    target.standardizedFileURL,
                    in: $0.root.url.resolvingSymlinksInPath().standardizedFileURL
                )
            }
        } ?? true
        guard logicalCovered, targetCovered else {
            accesses.forEach { $0.lease.close() }
            if let firstResolutionError { throw firstResolutionError }
            throw AppModelDocumentError.noAuthorizedRoot
        }
        return (SkillDocumentRequest(
            installationURL: installationURL,
            resolvedTargetURL: skill.resolvedTarget.map(URL.init(fileURLWithPath:)),
            entryFilename: skill.entryFilename,
            authorizedRootURLs: accesses.map(\.root.url)
        ), accesses.map(\.lease))
    }

    private struct PendingOperationContext {
        let fileOperator: SkillFileOperator
        var request: FileOperationRequest
        let authorizedRoots: [AuthorizedRootSnapshot]
        let leases: [AccessLease]
    }

    private struct PendingUpdateContext {
        let updater: SkillUpdater
        let rootIDs: [String]
        let authorizedRoots: [AuthorizedRootSnapshot]
        let leases: [AccessLease]
        let toolAccess: ToolAccess?
    }

    private func closePendingOperation() {
        pendingOperationContext?.leases.forEach { $0.close() }
        pendingOperationContext = nil
        pendingOperationPlan = nil
    }

    private func closePendingUpdate() {
        pendingUpdateContext?.leases.forEach { $0.close() }
        pendingUpdateContext?.toolAccess?.close()
        pendingUpdateContext = nil
        pendingUpdateProposal = nil
    }

    private func operationAccessRootIDs(
        for skill: SkillSnapshot,
        destinationRootURL: URL?
    ) -> [String] {
        var ids = Set(skill.rootIDs)
        if let resolvedTarget = skill.resolvedTarget.map(URL.init(fileURLWithPath:)) {
            ids.formUnion(rootIDs(containingResolvedURL: resolvedTarget))
        }
        if let destinationRootURL {
            ids.formUnion(rootIDs(containingLogicalURL: destinationRootURL))
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
            Self.contains(source, in: $0.root.url.standardizedFileURL)
        }
        let resolvedSourceCovered = skill.resolvedTarget.map(URL.init(fileURLWithPath:)).map { target in
            accesses.contains {
                Self.contains(
                    target.standardizedFileURL,
                    in: $0.root.url.resolvingSymlinksInPath().standardizedFileURL
                )
            }
        } ?? true
        let destinationCovered = destinationRootURL.map { destination in
            accesses.contains {
                Self.contains(destination, in: $0.root.url.standardizedFileURL)
            }
        } ?? true
        return logicalSourceCovered && resolvedSourceCovered && destinationCovered
    }

    private func rootIDs(containingLogicalURL url: URL) -> Set<String> {
        Set(authorizedRoots.filter {
            Self.contains(url.standardizedFileURL, in: $0.url.standardizedFileURL)
        }.map(\.id))
    }

    private func rootIDs(containingResolvedURL url: URL) -> Set<String> {
        Set(authorizedRoots.filter {
            Self.contains(
                url.standardizedFileURL,
                in: $0.url.resolvingSymlinksInPath().standardizedFileURL
            )
        }.map(\.id))
    }

    private static func contains(_ candidate: URL, in root: URL) -> Bool {
        let candidateComponents = candidate.pathComponents
        let rootComponents = root.pathComponents
        return candidateComponents.count >= rootComponents.count
            && Array(candidateComponents.prefix(rootComponents.count)) == rootComponents
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

    private func localizedUpdateError(_ error: Error) -> String {
        if error is SkillFileOperatorError {
            return localizedOperationError(error)
        }
        if let error = error as? SkillUpdateError {
            return switch error {
            case .unsupportedSource: L10n.string("The update source or GitHub CLI is unavailable.")
            case .unauthorizedInstallation: L10n.string("The update target is not authorized.")
            case .resolvedTargetMismatch: L10n.string("The symbolic link target changed.")
            case .commandFailed: L10n.string("The GitHub update command failed.")
            case .invalidRemoteResponse, .truncatedRepositoryTree, .remotePackageTooLarge:
                L10n.string("The downloaded Skill package is invalid.")
            case .proposalExpired, .proposalAlreadyConsumed:
                L10n.string("This update confirmation is no longer valid.")
            case .stagedPackageChanged:
                L10n.string("The downloaded Skill package changed before installation.")
            }
        }
        if error is PackageValidationError {
            return L10n.string("The downloaded Skill package is invalid.")
        }
        return String(describing: error)
    }

    private func localizedSourceBindingError(_ error: Error) -> String {
        guard error is SkillSourceError else { return String(describing: error) }
        return L10n.string("The update source is invalid or cannot be verified.")
    }
}

private extension FileOperationMetadataTransfer {
    var isMove: Bool {
        if case .move = self { return true }
        return false
    }
}
