import Foundation

public struct ParseIssue: Codable, Hashable, Sendable {
    public let line: Int?
    public let message: String

    public init(line: Int? = nil, message: String) {
        self.line = line
        self.message = message
    }
}

public struct ParsedSkillDocument: Codable, Hashable, Sendable {
    public var name: String?
    public var description: String?
    public var title: String?
    public var firstDescriptiveParagraph: String?
    public var fields: [String: String]
    public var issues: [ParseIssue]

    public init(
        name: String? = nil,
        description: String? = nil,
        title: String? = nil,
        firstDescriptiveParagraph: String? = nil,
        fields: [String: String] = [:],
        issues: [ParseIssue] = []
    ) {
        self.name = name
        self.description = description
        self.title = title
        self.firstDescriptiveParagraph = firstDescriptiveParagraph
        self.fields = fields
        self.issues = issues
    }
}

public enum ScanRootKind: Sendable {
    case skillDirectory(agentIDs: Set<String>, entryFilename: String)
    case project(registry: AgentRegistry)
}

public struct ScanRoot: Sendable {
    public let id: String
    public let url: URL
    public let kind: ScanRootKind

    public init(id: String, url: URL, kind: ScanRootKind) {
        self.id = id
        self.url = url.standardizedFileURL
        self.kind = kind
    }

    public static func skillDirectory(
        id: String,
        url: URL,
        agentIDs: Set<String>,
        entryFilename: String = "SKILL.md"
    ) -> ScanRoot {
        ScanRoot(
            id: id,
            url: url,
            kind: .skillDirectory(agentIDs: agentIDs, entryFilename: entryFilename)
        )
    }

    public static func project(id: String, url: URL, registry: AgentRegistry) -> ScanRoot {
        ScanRoot(id: id, url: url, kind: .project(registry: registry))
    }
}

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

    public init(
        id: String,
        url: URL,
        availability: ScanRootAvailability,
        issues: [ScanIssue] = []
    ) {
        self.id = id
        self.url = url.standardizedFileURL
        self.availability = availability
        self.issues = issues
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
        entryModificationDate: Date? = nil
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
