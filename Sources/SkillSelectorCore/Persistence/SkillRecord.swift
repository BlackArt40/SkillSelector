import Foundation
import SwiftData

public enum SkillAvailability: String, Codable, Hashable, Sendable {
    case available
    case unavailable
}

@Model
public final class SkillRecord {
    @Attribute(.unique) public var path: String
    public var resolvedTarget: String?
    public var name: String
    public var localDescription: String?
    public var enrichedDescription: String?
    public var enrichedDescriptionProvenance: String?
    public var customDescription: String?
    public var digest: String?
    public var modificationDate: Date?
    public var availabilityRawValue: String
    public var unavailableReason: String?
    public var sourceBinding: String?
    public var agentIDsByRootData: Data
    public var entryFilename: String
    public var parseDiagnosticsData: Data

    public init(
        path: String,
        resolvedTarget: String? = nil,
        name: String,
        localDescription: String? = nil,
        enrichedDescription: String? = nil,
        enrichedDescriptionProvenance: String? = nil,
        customDescription: String? = nil,
        digest: String? = nil,
        modificationDate: Date? = nil,
        availability: SkillAvailability = .available,
        unavailableReason: String? = nil,
        sourceBinding: String? = nil,
        agentIDsByRootData: Data = Data(),
        entryFilename: String,
        parseDiagnosticsData: Data = Data()
    ) {
        self.path = path
        self.resolvedTarget = resolvedTarget
        self.name = name
        self.localDescription = localDescription
        self.enrichedDescription = enrichedDescription
        self.enrichedDescriptionProvenance = enrichedDescriptionProvenance
        self.customDescription = customDescription
        self.digest = digest
        self.modificationDate = modificationDate
        self.availabilityRawValue = availability.rawValue
        self.unavailableReason = unavailableReason
        self.sourceBinding = sourceBinding
        self.agentIDsByRootData = agentIDsByRootData
        self.entryFilename = entryFilename
        self.parseDiagnosticsData = parseDiagnosticsData
    }
}

public struct SkillSnapshot: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public let resolvedTarget: String?
    public let name: String
    public let localDescription: String?
    public let enrichedDescription: String?
    public let enrichedDescriptionProvenance: String?
    public let customDescription: String?
    public let digest: String?
    public let modificationDate: Date?
    public let availability: SkillAvailability
    public let unavailableReason: String?
    public let sourceBinding: String?
    public let agentIDs: [String]
    public let rootIDs: [String]
    public let entryFilename: String
    public let parseDiagnostics: [ParseIssue]
}
