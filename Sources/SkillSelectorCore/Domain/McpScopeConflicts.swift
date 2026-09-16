import Foundation

/// One server name declared in both scopes: once user-level (global, whose
/// descriptor carries `projectRootID == nil`) and once inside an authorized
/// project.
///
/// **What this deliberately does not say.** It does not claim which of the
/// two declarations an Agent actually uses. Scope precedence differs per
/// client and has changed between client versions, and this project has no
/// verified evidence for any of them — asserting one would be worse than
/// pointing at both files and letting the user check. The collision itself
/// is a fact, and that is all this type reports.
public struct McpScopeConflict: Hashable, Sendable {
    public let name: String
    /// The user-level declaration.
    public let global: McpServerDescriptor
    /// The project-scoped declaration.
    public let project: McpServerDescriptor

    /// Both declarations, global first — the order the UI presents them in.
    public var declarations: [McpServerDescriptor] { [global, project] }
}

/// Finds MCP server names that exist in more than one scope. Read-only and
/// pure: it reasons about the descriptors the scanner already produced and
/// touches no files.
public enum McpScopeConflicts {
    /// Every name declared both globally and inside a project.
    ///
    /// Matching is by exact name, because that is the identity an MCP client
    /// compares when deciding which servers exist. A renamed copy is
    /// therefore *not* a conflict — it is simply two servers, and reporting
    /// it as one would be noise.
    public static func detect(in servers: [McpServerDescriptor]) -> [McpScopeConflict] {
        var globals: [String: McpServerDescriptor] = [:]
        var projects: [String: McpServerDescriptor] = [:]

        // A name can repeat within a scope (two project roots, say). The
        // first in a stable order wins so repeated scans report the same
        // pair rather than shuffling between runs.
        for server in servers.sorted(by: isOrderedBefore) {
            if server.projectRootID == nil {
                if globals[server.name] == nil { globals[server.name] = server }
            } else if projects[server.name] == nil {
                projects[server.name] = server
            }
        }

        return globals.keys
            .compactMap { name -> McpScopeConflict? in
                guard let global = globals[name], let project = projects[name] else { return nil }
                return McpScopeConflict(name: name, global: global, project: project)
            }
            .sorted { $0.name < $1.name }
    }

    /// The ids of every server taking part in a conflict, so a list row can
    /// decide whether to flag itself without scanning the conflict array.
    public static func conflictingIDs(in conflicts: [McpScopeConflict]) -> Set<String> {
        Set(conflicts.flatMap { [$0.global.id, $0.project.id] })
    }

    /// Deterministic tie-break: config path, then id (which itself embeds
    /// the config path, so the two only disagree for same-file duplicates).
    private static func isOrderedBefore(_ lhs: McpServerDescriptor, _ rhs: McpServerDescriptor) -> Bool {
        lhs.configFile == rhs.configFile ? lhs.id < rhs.id : lhs.configFile < rhs.configFile
    }
}
