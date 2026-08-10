import Foundation

public struct DocumentLoadIdentity: Hashable, Sendable {
    public let path: String
    public let entryFilename: String
    public let resolvedTarget: String?
    public let modificationDate: Date?
    public let rootIDs: [String]

    public init(snapshot: SkillSnapshot) {
        path = snapshot.path
        entryFilename = snapshot.entryFilename
        resolvedTarget = snapshot.resolvedTarget
        modificationDate = snapshot.modificationDate
        rootIDs = snapshot.rootIDs.sorted()
    }
}
