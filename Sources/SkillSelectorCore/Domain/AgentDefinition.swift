import Foundation

public struct AgentDefinition: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public var displayName: String
    public var globalRoots: [String]
    public var projectPatterns: [String]
    public var entryFilename: String
    public var isLegacy: Bool

    public init(
        id: String,
        displayName: String,
        globalRoots: [String],
        projectPatterns: [String],
        entryFilename: String = "SKILL.md",
        isLegacy: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.globalRoots = globalRoots
        self.projectPatterns = projectPatterns
        self.entryFilename = entryFilename
        self.isLegacy = isLegacy
    }
}
