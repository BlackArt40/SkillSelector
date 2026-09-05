import Foundation
import GRDB

/// Optional fields preserve compatibility notes from the SwiftData era:
/// fields added later stay optional so older on-disk rows (had any future
/// migration run) could decode — the fresh-state policy makes this moot for
/// users, but the decoders stay total.
public struct SkillRecord: Codable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "skillRecords"

    public var path: String
    public var resolvedTarget: String?
    public var name: String
    public var localDescription: String?
    public var modificationDate: Date?
    public var agentIDsByRootData: Data
    public var entryFilename: String
    public var parseDiagnosticsData: Data
    public var contentFingerprint: String?
    public var similarityFingerprint: String?
    public var ignoredDuplicateGroup: String?
    public var ignoredNearDuplicateGroup: String?
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
