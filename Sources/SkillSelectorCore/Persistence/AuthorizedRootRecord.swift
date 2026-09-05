import Foundation
import GRDB

public struct AuthorizedRootRecord: Codable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "authorizedRootRecords"

    public var id: String
    public var path: String
    public var kindRawValue: String
    public var bookmarkData: Data

    public init(
        id: String = UUID().uuidString,
        path: String,
        kind: AuthorizedRootKind,
        bookmarkData: Data
    ) {
        self.id = id
        self.path = path
        self.kindRawValue = kind.rawValue
        self.bookmarkData = bookmarkData
    }
}
