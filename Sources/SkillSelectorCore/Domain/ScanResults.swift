import Foundation

public enum ScanRootAvailability: Hashable, Sendable {
    case available
    case unavailable(reason: String)
}

public struct ScanIssue: Codable, Hashable, Sendable {
    public let message: String

    public init(message: String) {
        self.message = message
    }
}

public struct ScannedRoot: Hashable, Sendable {
    public let id: String
    public let url: URL
    public let availability: ScanRootAvailability
    public let issues: [ScanIssue]
    public let unavailableDiagnostic: StructuredDiagnostic?

    public init(
        id: String,
        url: URL,
        availability: ScanRootAvailability,
        issues: [ScanIssue] = [],
        unavailableDiagnostic: StructuredDiagnostic? = nil
    ) {
        self.id = id
        self.url = url.standardizedFileURL
        self.availability = availability
        self.issues = issues
        self.unavailableDiagnostic = unavailableDiagnostic
    }
}

public struct ScannedSkill: Hashable, Sendable {
    public var installation: SkillInstallation
    public var document: ParsedSkillDocument
    public var agentIDsByRoot: [String: Set<String>]
    public var entryFilename: String
    public var entryModificationDate: Date?

    public init(
        installation: SkillInstallation,
        document: ParsedSkillDocument,
        agentIDsByRoot: [String: Set<String>],
        entryFilename: String,
        entryModificationDate: Date? = nil,
    ) {
        var installation = installation
        installation.agentIDs = agentIDsByRoot.values.reduce(into: []) { result, agentIDs in
            result.formUnion(agentIDs)
        }
        self.installation = installation
        self.document = document
        self.agentIDsByRoot = agentIDsByRoot
        self.entryFilename = entryFilename
        self.entryModificationDate = entryModificationDate
    }

    public var path: URL { installation.path }
    public var resolvedTarget: URL? { installation.resolvedTarget }
    public var rootIDs: Set<String> { Set(agentIDsByRoot.keys) }
    public var agentIDs: Set<String> {
        agentIDsByRoot.values.reduce(into: []) { result, agentIDs in
            result.formUnion(agentIDs)
        }
    }
}

public struct ScanReport: Hashable, Sendable {
    public var installations: [ScannedSkill]
    public var roots: [ScannedRoot]

    public init(installations: [ScannedSkill] = [], roots: [ScannedRoot] = []) {
        self.installations = installations
        self.roots = roots
    }
}
