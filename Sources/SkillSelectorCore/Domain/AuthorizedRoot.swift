import Foundation

public enum AuthorizedRootKind: String, Codable, CaseIterable, Hashable, Sendable {
    case home
    case project
    case system
    case custom

    /// Localization key for this kind's user-facing name. Core deliberately
    /// exposes only the key — never English display text — so callers must
    /// route it through their localization layer (review P2-7).
    public var localizationKey: String {
        switch self {
        case .home: "Home Directory"
        case .project: "Project Directory"
        case .system: "System Skill Directory"
        case .custom: "Custom Skill Directory"
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
