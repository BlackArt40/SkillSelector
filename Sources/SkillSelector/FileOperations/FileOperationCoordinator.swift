import Foundation
import Observation
import SkillSelectorCore

/// Supplies the live app state and callbacks the file-operation state machine
/// needs without coupling it back to `AppModel`'s full surface.
@MainActor
protocol FileOperationCoordinatorOwner: AnyObject {
    var authorizedRoots: [AuthorizedRootSnapshot] { get }
    var snapshots: [SkillSnapshot] { get }
    var registry: AgentRegistry { get }
    func reloadSnapshot() throws
    func updateSelection(to path: String?)
    func setRefreshState(_ state: RefreshState)
    func makeRedactor() -> Redactor
}

/// One planned item inside a pending batch: the skill, its plan, and the
/// request the plan was issued from.
struct BatchOperationEntry {
    let skill: SkillSnapshot
    let plan: FileOperationPlan
    let request: FileOperationRequest
}

/// A multi-select operation awaiting one confirmation. Copy/move batches
/// always use `.keepBoth` — per-item replacement needs the single-item flow
/// with its explicit second confirmation.
struct PendingBatchOperation: Identifiable {
    let id = UUID()
    let operation: FileOperationKind
    let entries: [BatchOperationEntry]
    let destinationURL: URL?
    let authorizedRoots: [AuthorizedRootSnapshot]
    let leases: [AccessLease]
    let fileOperator: SkillFileOperator
}

/// Owns the plan → confirm → execute state machine for file operations.
///
/// Extracted from `AppModel` so the operation lifecycle (planning, conflict
/// policy changes, confirmation, execution, refresh, diagnostics) can grow
/// without expanding the model's already-large surface. The observable state
/// (`pendingOperationPlan`, `operationError`, `isOperating`) is forwarded
/// through `AppModel` so views keep binding to the model.
@MainActor
@Observable
final class FileOperationCoordinator {
    var pendingOperationPlan: FileOperationPlan?
    var pendingBatch: PendingBatchOperation?
    var operationError: String?
    private(set) var isOperating = false

    weak var owner: FileOperationCoordinatorOwner?

    private let bookmarks: BookmarkStore?
    private let refresher: IndexRefresher
    private let index: SkillIndex
    private let diagnosticStore: DiagnosticStore
    @ObservationIgnored private var pendingContext: PendingOperationContext?

    init(
        bookmarks: BookmarkStore?,
        refresher: IndexRefresher,
        index: SkillIndex,
        diagnosticStore: DiagnosticStore
    ) {
        self.bookmarks = bookmarks
        self.refresher = refresher
        self.index = index
        self.diagnosticStore = diagnosticStore
    }

    func plan(
        _ operation: FileOperationKind,
        for skill: SkillSnapshot,
        destinationRootURL: URL? = nil,
        conflictPolicy: FileConflictPolicy = .keepBoth,
        destinationIsArbitrary: Bool = false
    ) async {
        guard pendingOperationPlan == nil,
              pendingBatch == nil,
              !isOperating else {
            operationError = L10n.string("Finish the current file operation first.")
            return
        }
        guard let bookmarks else {
            operationError = L10n.string("Authorization storage is unavailable")
            return
        }
        guard let owner else { return }

        var accesses: [AuthorizedRootAccess] = []
        do {
            accesses = try AuthorizedAccessResolver(bookmarks: bookmarks)
                .resolveAccess(
                    for: skill,
                    destinationRootURL: destinationRootURL,
                    authorizedRoots: owner.authorizedRoots,
                    destinationIsArbitrary: destinationIsArbitrary
                )
            let currentRoots = try bookmarks.roots()
            let currentAliases = owner.snapshots.map {
                IndexedSkillAlias(
                    path: $0.path,
                    resolvedTarget: $0.resolvedTarget,
                    rootIDs: $0.rootIDs
                )
            }
            let registry = owner.registry
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
                destinationIsArbitrary: destinationIsArbitrary
            )
            let plan = try fileOperator.plan(request)
            pendingContext = PendingOperationContext(
                fileOperator: fileOperator,
                request: request,
                authorizedRoots: currentRoots,
                leases: accesses.map(\.lease)
            )
            pendingOperationPlan = plan
            operationError = nil
        } catch {
            accesses.forEach { $0.lease.close() }
            operationError = localizedError(error)
        }
    }

    /// Plans one operation per skill against a shared destination. Only
    /// copy, move, and delete are offered in batch; each item plans with
    /// `.keepBoth` so a name conflict resolves by keeping both instead of
    /// asking for a per-item replacement decision.
    func planBatch(
        _ operation: FileOperationKind,
        for skills: [SkillSnapshot],
        destinationRootURL: URL? = nil,
        destinationIsArbitrary: Bool = false
    ) async {
        guard pendingOperationPlan == nil,
              pendingBatch == nil,
              !isOperating else {
            operationError = L10n.string("Finish the current file operation first.")
            return
        }
        guard !skills.isEmpty else { return }
        guard operation == .copy || operation == .move || operation == .delete else {
            operationError = L10n.string("Batch operations support copy, move, and delete.")
            return
        }
        guard let bookmarks else {
            operationError = L10n.string("Authorization storage is unavailable")
            return
        }
        guard let owner else { return }

        var accesses: [AuthorizedRootAccess] = []
        do {
            let currentRoots = try bookmarks.roots()
            let currentAliases = owner.snapshots.map {
                IndexedSkillAlias(
                    path: $0.path,
                    resolvedTarget: $0.resolvedTarget,
                    rootIDs: $0.rootIDs
                )
            }
            let registry = owner.registry
            let fileOperator = SkillFileOperator(
                registryProvider: { [registry] in registry },
                authorizedRootsProvider: { [currentRoots] in currentRoots },
                indexedAliasesProvider: { [currentAliases] in currentAliases }
            )
            var entries: [BatchOperationEntry] = []
            for skill in skills {
                let skillAccesses = try AuthorizedAccessResolver(bookmarks: bookmarks)
                    .resolveAccess(
                        for: skill,
                        destinationRootURL: destinationRootURL,
                        authorizedRoots: owner.authorizedRoots,
                        destinationIsArbitrary: destinationIsArbitrary
                    )
                accesses.append(contentsOf: skillAccesses)
                let request = FileOperationRequest(
                    operation: operation,
                    sourceURL: URL(fileURLWithPath: skill.path),
                    resolvedSourceURL: skill.resolvedTarget.map(URL.init(fileURLWithPath:)),
                    sourceEntryFilename: skill.entryFilename,
                    destinationRootURL: destinationRootURL,
                    proposedName: nil,
                    conflictPolicy: operation == .delete ? .fail : .keepBoth,
                    destinationIsArbitrary: destinationIsArbitrary
                )
                entries.append(BatchOperationEntry(
                    skill: skill,
                    plan: try fileOperator.plan(request),
                    request: request
                ))
            }
            pendingBatch = PendingBatchOperation(
                operation: operation,
                entries: entries,
                destinationURL: destinationRootURL,
                authorizedRoots: currentRoots,
                leases: accesses.map(\.lease),
                fileOperator: fileOperator
            )
            operationError = nil
        } catch {
            accesses.forEach { $0.lease.close() }
            operationError = localizedError(error)
        }
    }

    func cancelPendingBatch() {
        closePendingBatch()
    }

    /// Executes the batch item by item, stopping at the first failure with
    /// everything already completed left in place and refreshed.
    func executePendingBatch() async {
        guard let batch = pendingBatch,
              pendingOperationPlan == nil,
              !isOperating else {
            return
        }
        isOperating = true
        defer {
            isOperating = false
            closePendingBatch()
        }
        var refreshRootIDs = Set<String>()
        var completed = 0
        do {
            guard let bookmarks,
                  try bookmarks.roots() == batch.authorizedRoots else {
                throw SkillFileOperatorError.authorizationChanged
            }
            for (index, entry) in batch.entries.enumerated() {
                // Only the first item validates the shared destination root's
                // fingerprint: every successful item mutates that root, so
                // later items would otherwise always fail destinationChanged
                // (audit #2: batch orchestration had zero tests and this
                // defect shipped with batch copy/move). Registration and
                // authorization are still re-validated per item inside
                // execute; only the root-content fingerprint is skipped.
                let result = try await batch.fileOperator.execute(
                    entry.plan,
                    confirmation: entry.plan.confirmationToken,
                    replacementConfirmation: nil,
                    validateDestinationRootFingerprint: index == 0
                )
                guard result.outcome == .completed else { continue }
                refreshRootIDs.formUnion(result.refreshRootIDs)
                completed += 1
            }
            let summary = try await refresher.refresh(rootIDs: refreshRootIDs)
            try owner?.reloadSnapshot()
            if batch.operation != .copy {
                owner?.updateSelection(to: nil)
            }
            owner?.setRefreshState(.finished(summary))
            operationError = nil
            diagnosticStore.record(
                category: .operations,
                code: "BATCH_OPERATION_COMPLETED",
                message: "Batch \(batch.operation.rawValue) completed for \(completed) of \(batch.entries.count) Skills",
                redactor: owner?.makeRedactor() ?? Redactor()
            )
        } catch {
            if !refreshRootIDs.isEmpty {
                // Keep the finished half of the batch visible and consistent.
                if let summary = try? await refresher.refresh(rootIDs: refreshRootIDs) {
                    try? owner?.reloadSnapshot()
                    owner?.setRefreshState(.finished(summary))
                }
            }
            if batch.operation != .copy {
                owner?.updateSelection(to: nil)
            }
            operationError = localizedError(error)
            diagnosticStore.record(
                category: .operations,
                code: "BATCH_OPERATION_FAILED",
                message: "Batch stopped after \(completed) of \(batch.entries.count): \(operationError ?? "")",
                redactor: owner?.makeRedactor() ?? Redactor()
            )
        }
    }

    func updateConflictPolicy(_ policy: FileConflictPolicy) {        guard let context = pendingContext,
              context.request.operation != .delete else { return }
        let request = FileOperationRequest(
            operation: context.request.operation,
            sourceURL: context.request.sourceURL,
            resolvedSourceURL: context.request.resolvedSourceURL,
            sourceEntryFilename: context.request.sourceEntryFilename,
            destinationRootURL: context.request.destinationRootURL,
            proposedName: context.request.proposedName,
            conflictPolicy: policy,
            destinationIsArbitrary: context.request.destinationIsArbitrary
        )
        do {
            pendingOperationPlan = try context.fileOperator.plan(request)
            pendingContext?.request = request
            operationError = nil
        } catch {
            operationError = localizedError(error)
        }
    }

    func cancelPending() {
        closePending()
    }

    func execute(replacementConfirmed: Bool) async {
        guard let plan = pendingOperationPlan,
              let context = pendingContext,
              !isOperating else {
            return
        }
        isOperating = true
        defer {
            isOperating = false
            closePending()
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
                rootIDs: Set(result.refreshRootIDs)
            )
            try owner?.reloadSnapshot()
            if let destinationPath = result.destinationURL?.path,
               context.request.operation == .move {
                owner?.updateSelection(to: destinationPath)
            }
            owner?.setRefreshState(.finished(summary))
            operationError = nil
            diagnosticStore.record(
                category: .operations,
                code: "OPERATION_COMPLETED",
                message: "File operation completed",
                redactor: owner?.makeRedactor() ?? Redactor()
            )
        } catch {
            operationError = localizedError(error)
            diagnosticStore.record(
                category: .operations,
                code: "OPERATION_FAILED",
                message: operationError ?? "File operation failed",
                redactor: owner?.makeRedactor() ?? Redactor()
            )
        }
    }

    private struct PendingOperationContext {
        let fileOperator: SkillFileOperator
        var request: FileOperationRequest
        let authorizedRoots: [AuthorizedRootSnapshot]
        let leases: [AccessLease]
    }

    private func closePending() {
        pendingContext?.leases.forEach { $0.close() }
        pendingContext = nil
        pendingOperationPlan = nil
    }

    private func closePendingBatch() {
        pendingBatch?.leases.forEach { $0.close() }
        pendingBatch = nil
    }

    private func localizedError(_ error: Error) -> String {
        if let error = error as? AuthorizedAccessError {
            return switch error {
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

