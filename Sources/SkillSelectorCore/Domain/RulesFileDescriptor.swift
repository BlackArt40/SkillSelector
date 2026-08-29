import Foundation

/// A rules file found on disk: a plain markdown instruction file
/// (`CLAUDE.md`, `AGENTS.md`, `.cursorrules`, …) that an Agent reads.
/// Read-only discovery — the app never edits these, exactly like Skills
/// and MCP configs.
public struct RulesFileDescriptor: Identifiable, Hashable, Sendable {
    /// The absolute path is the unique identity (paths are deduplicated).
    public let id: String
    public let path: String
    /// Last path component, for display ("CLAUDE.md").
    public let filename: String
    /// The Agent that declared this rules file (first declaration wins
    /// when several Agents share a path, e.g. a project CLAUDE.md).
    public let agentID: String?
    /// The project root the file belongs to; nil for global (user-level)
    /// files under the home root.
    public let projectRootID: String?
    public let fileSize: Int?
    public let modificationDate: Date?

    public init(
        path: String,
        filename: String,
        agentID: String?,
        projectRootID: String?,
        fileSize: Int?,
        modificationDate: Date?
    ) {
        self.id = path
        self.path = path
        self.filename = filename
        self.agentID = agentID
        self.projectRootID = projectRootID
        self.fileSize = fileSize
        self.modificationDate = modificationDate
    }
}
