import Foundation
import SwiftData

@Model
public final class SkillRecord {
    @Attribute(.unique) public var path: String
    public var resolvedTarget: String?
    public var name: String
    public var localDescription: String?
    public var customDescription: String?
    public var modificationDate: Date?
    // Optional preserves compatibility with stores created before source discovery existed.
    public var agentIDsByRootData: Data
    public var entryFilename: String
    public var parseDiagnosticsData: Data

    public init(
        path: String,
        resolvedTarget: String? = nil,
        name: String,
        localDescription: String? = nil,
        customDescription: String? = nil,
        modificationDate: Date? = nil,
        agentIDsByRootData: Data = Data("{}".utf8),
        entryFilename: String,
        parseDiagnosticsData: Data = Data()
    ) {
        self.path = path
        self.resolvedTarget = resolvedTarget
        self.name = name
        self.localDescription = localDescription
        self.customDescription = customDescription
        self.modificationDate = modificationDate
        self.agentIDsByRootData = agentIDsByRootData
        self.entryFilename = entryFilename
        self.parseDiagnosticsData = parseDiagnosticsData
    }
}
