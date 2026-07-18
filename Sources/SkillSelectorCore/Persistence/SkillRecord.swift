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
    public var unavailableDiagnosticData: Data?
    public var sourceBinding: String?
    // Optional preserves compatibility with stores created before source discovery existed.
    public var discoveredSourceBindingsData: Data?
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
        unavailableDiagnosticData: Data? = nil,
        sourceBinding: String? = nil,
        discoveredSourceBindingsData: Data? = nil,
        agentIDsByRootData: Data = Data("{}".utf8),
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
        self.unavailableDiagnosticData = unavailableDiagnosticData
        self.sourceBinding = sourceBinding
        self.discoveredSourceBindingsData = discoveredSourceBindingsData
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
    public var unavailableDiagnostic: StructuredDiagnostic? = nil
    public var discoveredSourceBindings: [String] = []
}
