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

    /// Display names of the agents associated with this Skill, excluding
    /// the synthetic owners, sorted by name.
    public func agentDisplayNames(by namesByID: [String: String]) -> [String] {
        agentIDs
            .filter { !SyntheticAgentID.all.contains($0) }
            .map { namesByID[$0] ?? $0 }
            .sorted()
    }
}
