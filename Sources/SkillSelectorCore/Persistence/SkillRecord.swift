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
    /// SimHash-64 of the body (`s1:`), nil for short bodies; optional so
    /// stores created before near-duplicate grouping open unchanged.
    public var similarityFingerprint: String?
    /// The content fingerprint of the duplicate group the user chose to
    /// ignore; nil while the Skill participates in duplicate grouping
    /// normally. Persisted with SwiftData, so the choice survives restarts.
    public var ignoredDuplicateGroup: String?
    /// The near-duplicate cluster key the user chose to ignore; nil while
    /// the Skill participates in near-duplicate grouping normally.
    public var ignoredNearDuplicateGroup: String?
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
        similarityFingerprint: String? = nil,
        ignoredDuplicateGroup: String? = nil,
        ignoredNearDuplicateGroup: String? = nil,
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
        self.similarityFingerprint = similarityFingerprint
        self.ignoredDuplicateGroup = ignoredDuplicateGroup
        self.ignoredNearDuplicateGroup = ignoredNearDuplicateGroup
        self.scanStateData = scanStateData
    }
}
