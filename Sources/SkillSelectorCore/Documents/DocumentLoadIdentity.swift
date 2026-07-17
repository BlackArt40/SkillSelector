import Foundation

public struct DocumentLoadIdentity: Hashable, Sendable {
    public let path: String
    public let entryFilename: String
    public let resolvedTarget: String?
    public let modificationDate: Date?
    public let availability: SkillAvailability
    public let rootIDs: [String]

    public init(snapshot: SkillSnapshot) {
        path = snapshot.path
        entryFilename = snapshot.entryFilename
        resolvedTarget = snapshot.resolvedTarget
        modificationDate = snapshot.modificationDate
        availability = snapshot.availability
        rootIDs = snapshot.rootIDs.sorted()
    }
}
