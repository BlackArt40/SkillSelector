import Foundation

public struct SkillInstallation: Identifiable, Hashable, Sendable {
    public let id: String
    public let path: URL
    public var resolvedTarget: URL?
    public var agentIDs: Set<String>

    public init(path: URL, resolvedTarget: URL? = nil, agentIDs: Set<String> = []) {
        let normalized = path.standardizedFileURL.path
        self.id = normalized
        self.path = URL(fileURLWithPath: normalized)
        self.resolvedTarget = resolvedTarget
        self.agentIDs = agentIDs
    }
}
