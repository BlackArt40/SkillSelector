import Foundation
import SwiftData

public enum AuthorizedRootKind: String, Codable, CaseIterable, Hashable, Sendable {
    case home
    case project
    case system
    case custom
}

@Model
public final class AuthorizedRootRecord {
    @Attribute(.unique) public var id: String
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

public struct AuthorizedRootSnapshot: Identifiable, Hashable, Sendable {
    public let id: String
    public let url: URL
    public let kind: AuthorizedRootKind
}
