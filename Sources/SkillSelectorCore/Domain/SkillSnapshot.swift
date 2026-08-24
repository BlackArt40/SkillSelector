import Foundation

public struct SkillSnapshot: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public let resolvedTarget: String?
    public let name: String
    public let localDescription: String?
    public let modificationDate: Date?
    public let agentIDs: [String]
    public let rootIDs: [String]
    public let entryFilename: String
    public let parseDiagnostics: [ParseIssue]
    public var contentFingerprint: String? = nil
    /// Set to the group's fingerprint when the user ignored this duplicate
    /// group; excluded from the duplicates view while set.
    public var ignoredDuplicateGroup: String? = nil

    /// Whether this Skill is a symbolic link whose target is no longer
    /// reachable (moved or deleted target). Checked at read time — the scan
    /// does not watch the file system.
    public var linkTargetIsUnreachable: Bool {
        guard let resolvedTarget else { return false }
        let url = URL(fileURLWithPath: resolvedTarget)
        return !FileManager.default.fileExists(atPath: url.path)
    }

    /// Display names of the agents associated with this Skill, excluding
    /// the synthetic owners, sorted by name.
    public func agentDisplayNames(by namesByID: [String: String]) -> [String] {
        agentIDs
            .filter { !SyntheticAgentID.all.contains($0) }
            .map { namesByID[$0] ?? $0 }
            .sorted()
    }
}
