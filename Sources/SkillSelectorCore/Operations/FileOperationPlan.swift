import Foundation

public enum FileOperationKind: String, Codable, Hashable, Sendable {
    case copy
    case move
    case delete
    case createSymbolicLink
}

public enum FileConflictPolicy: String, Codable, CaseIterable, Hashable, Sendable {
    case fail
    case keepBoth
    case replace
    case cancel
}

public enum FileOperationLinkForm: String, Codable, Hashable, Sendable {
    case regularDirectory
    case symbolicLink
}

public enum LinkTargetForm: String, Codable, Hashable, Sendable {
    case relative
    case absolute
}

public struct ConfirmationToken: Codable, Hashable, Sendable {
    fileprivate let value: UUID

    public init() {
        value = UUID()
    }
}

public struct IndexedSkillAlias: Codable, Hashable, Sendable {
    public let path: String
    public let resolvedTarget: String?
    public let rootIDs: [String]

    public init(path: String, resolvedTarget: String?, rootIDs: [String] = []) {
        self.path = URL(fileURLWithPath: path).standardizedFileURL.path
        self.resolvedTarget = resolvedTarget.map {
            URL(fileURLWithPath: $0).standardizedFileURL.path
        }
        self.rootIDs = rootIDs.sorted()
    }
}

public struct FileOperationRequest: Hashable, Sendable {
    public let operation: FileOperationKind
    public let sourceURL: URL
    public let resolvedSourceURL: URL?
    public let sourceEntryFilename: String
    public let destinationRootURL: URL?
    public let proposedName: String?
    public let conflictPolicy: FileConflictPolicy
    /// True when the destination folder was picked from an open panel and is
    /// not a registered Skill root — copy/move then target the folder as-is
    /// instead of mapping it through the Agent registry.
    public let destinationIsArbitrary: Bool

    public init(
        operation: FileOperationKind,
        sourceURL: URL,
        resolvedSourceURL: URL? = nil,
        sourceEntryFilename: String,
        destinationRootURL: URL? = nil,
        proposedName: String? = nil,
        conflictPolicy: FileConflictPolicy = .fail,
        destinationIsArbitrary: Bool = false
    ) {
        self.operation = operation
        self.sourceURL = sourceURL.standardizedFileURL
        self.resolvedSourceURL = resolvedSourceURL?.standardizedFileURL
        self.sourceEntryFilename = sourceEntryFilename
        self.destinationRootURL = destinationRootURL?.standardizedFileURL
        self.proposedName = proposedName
        self.conflictPolicy = conflictPolicy
        self.destinationIsArbitrary = destinationIsArbitrary
    }
}

public struct FileOperationPlan: Hashable, Identifiable, Sendable {
    public let id: UUID
    public let operation: FileOperationKind
    public let logicalSourceURL: URL
    public let resolvedSourceURL: URL
    public let destinationRootURL: URL?
    public let destinationURL: URL?
    public let destinationRootID: String?
    public let destinationAgentIDs: [String]
    public let entryFilename: String
    public let authorizationSnapshotFingerprint: String
    public let registrySnapshotFingerprint: String
    public let conflictPolicy: FileConflictPolicy
    public let hadDestinationConflict: Bool
    public let movesExistingDestinationToTrash: Bool
    public let linkForm: FileOperationLinkForm
    public let linkTarget: String?
    public let linkTargetForm: LinkTargetForm?
    public let affectedIndexedAliases: [String]
    public let affectedIndexedRootIDs: [String]
    public let confirmationToken: ConfirmationToken
    public let replacementConfirmationToken: ConfirmationToken?

    let issuerID: UUID
    let sourceSnapshot: FileOperationItemSnapshot
    let destinationRootSnapshot: FileOperationItemSnapshot?
    let destinationSnapshot: FileOperationItemSnapshot?

    init(
        id: UUID,
        issuerID: UUID,
        operation: FileOperationKind,
        logicalSourceURL: URL,
        resolvedSourceURL: URL,
        destinationRootURL: URL?,
        destinationURL: URL?,
        destinationRootID: String?,
        destinationAgentIDs: [String],
        entryFilename: String,
        authorizationSnapshotFingerprint: String,
        registrySnapshotFingerprint: String,
        conflictPolicy: FileConflictPolicy,
        hadDestinationConflict: Bool,
        movesExistingDestinationToTrash: Bool,
        linkForm: FileOperationLinkForm,
        linkTarget: String?,
        linkTargetForm: LinkTargetForm?,
        affectedIndexedAliases: [String],
        affectedIndexedRootIDs: [String],
        confirmationToken: ConfirmationToken,
        replacementConfirmationToken: ConfirmationToken?,
        sourceSnapshot: FileOperationItemSnapshot,
        destinationRootSnapshot: FileOperationItemSnapshot?,
        destinationSnapshot: FileOperationItemSnapshot?
    ) {
        self.id = id
        self.issuerID = issuerID
        self.operation = operation
        self.logicalSourceURL = logicalSourceURL
        self.resolvedSourceURL = resolvedSourceURL
        self.destinationRootURL = destinationRootURL
        self.destinationURL = destinationURL
        self.destinationRootID = destinationRootID
        self.destinationAgentIDs = destinationAgentIDs
        self.entryFilename = entryFilename
        self.authorizationSnapshotFingerprint = authorizationSnapshotFingerprint
        self.registrySnapshotFingerprint = registrySnapshotFingerprint
        self.conflictPolicy = conflictPolicy
        self.hadDestinationConflict = hadDestinationConflict
        self.movesExistingDestinationToTrash = movesExistingDestinationToTrash
        self.linkForm = linkForm
        self.linkTarget = linkTarget
        self.linkTargetForm = linkTargetForm
        self.affectedIndexedAliases = affectedIndexedAliases
        self.affectedIndexedRootIDs = affectedIndexedRootIDs
        self.confirmationToken = confirmationToken
        self.replacementConfirmationToken = replacementConfirmationToken
        self.sourceSnapshot = sourceSnapshot
        self.destinationRootSnapshot = destinationRootSnapshot
        self.destinationSnapshot = destinationSnapshot
    }
}

public enum FileOperationOutcome: String, Codable, Hashable, Sendable {
    case completed
    case cancelled
}

public struct FileOperationResult: Hashable, Sendable {
    public let outcome: FileOperationOutcome
    public let sourceURL: URL
    public let destinationURL: URL?
    public let refreshRootIDs: [String]

    public init(
        outcome: FileOperationOutcome,
        sourceURL: URL,
        destinationURL: URL?,
        refreshRootIDs: [String]
    ) {
        self.outcome = outcome
        self.sourceURL = sourceURL
        self.destinationURL = destinationURL
        self.refreshRootIDs = refreshRootIDs
    }
}

struct FileOperationItemSnapshot: Hashable, Sendable {
    enum Kind: String, Hashable, Sendable {
        case directory
        case symbolicLink
    }

    let kind: Kind
    let resolvedURL: URL
    let fingerprint: String
}
