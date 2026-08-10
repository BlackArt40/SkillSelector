import Foundation

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
