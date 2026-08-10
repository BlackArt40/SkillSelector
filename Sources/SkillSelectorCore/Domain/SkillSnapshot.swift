import Foundation

public enum SkillAvailability: String, Codable, Hashable, Sendable {
    case available
    case unavailable
}

public struct SkillSnapshot: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public let resolvedTarget: String?
    public let name: String
    public let localDescription: String?
    public let customDescription: String?
    public let modificationDate: Date?
    public let availability: SkillAvailability
    public let unavailableReason: String?
    public let agentIDs: [String]
    public let rootIDs: [String]
    public let entryFilename: String
    public let parseDiagnostics: [ParseIssue]
    public var unavailableDiagnostic: StructuredDiagnostic? = nil

    /// Display names of the agents associated with this Skill, excluding the
    /// synthetic `system` and `custom` owners, sorted by name.
    public func agentDisplayNames(by namesByID: [String: String]) -> [String] {
        agentIDs
            .filter { $0 != "system" && $0 != "custom" }
            .map { namesByID[$0] ?? $0 }
            .sorted()
    }
}
