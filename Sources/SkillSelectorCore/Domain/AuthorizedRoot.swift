import Foundation

public enum AuthorizedRootKind: String, Codable, CaseIterable, Hashable, Sendable {
    case home
    case project
    case system
    case custom

    public var localizedName: String {
        switch self {
        case .home: "Home Directory"
        case .project: "Project Directory"
        case .system: "System Skill Directory"
        case .custom: "Custom Skill Directory"
        }
    }

    public var systemImage: String {
        switch self {
        case .home: "house"
        case .project: "folder"
        case .system: "externaldrive"
        case .custom: "folder.badge.plus"
        }
    }
}

public struct AuthorizedRootSnapshot: Identifiable, Hashable, Sendable {
    public let id: String
    public let url: URL
    public let kind: AuthorizedRootKind
    public var customName: String?

    public var displayName: String {
        customName ?? url.lastPathComponent
    }
}
