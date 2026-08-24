import Foundation
import SwiftData

@Model
public final class SkillRecord {
    @Attribute(.unique) public var path: String
    public var resolvedTarget: String?
    public var name: String
    public var localDescription: String?
    public var modificationDate: Date?
    // Optional preserves compatibility with stores created before source discovery existed.
    public var agentIDsByRootData: Data
    public var entryFilename: String
    public var parseDiagnosticsData: Data
    // Optional so stores created before duplicate grouping open unchanged.
    public var contentFingerprint: String?
    /// The content fingerprint of the duplicate group the user chose to
    /// ignore; nil while the Skill participates in duplicate grouping
    /// normally. Persisted with SwiftData, so the choice survives restarts.
    public var ignoredDuplicateGroup: String?
    // JSON-encoded ScannedSkillCacheEntry for incremental scans; nil on
    // records never scanned fresh (or whose scan could not be trusted).
    public var scanStateData: Data?

    public init(
        path: String,
        resolvedTarget: String? = nil,
        name: String,
        localDescription: String? = nil,
        modificationDate: Date? = nil,
        agentIDsByRootData: Data = Data("{}".utf8),
        entryFilename: String,
        parseDiagnosticsData: Data = Data(),
        contentFingerprint: String? = nil,
        ignoredDuplicateGroup: String? = nil,
        scanStateData: Data? = nil
    ) {
        self.path = path
        self.resolvedTarget = resolvedTarget
        self.name = name
        self.localDescription = localDescription
        self.modificationDate = modificationDate
        self.agentIDsByRootData = agentIDsByRootData
        self.entryFilename = entryFilename
        self.parseDiagnosticsData = parseDiagnosticsData
        self.contentFingerprint = contentFingerprint
        self.ignoredDuplicateGroup = ignoredDuplicateGroup
        self.scanStateData = scanStateData
    }
}
