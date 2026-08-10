import SkillSelectorCore

extension AuthorizedRootKind {
    /// SF Symbol name for the kind's sidebar and settings row icon.
    ///
    /// Kept in the app layer: SF Symbol names are SwiftUI presentation
    /// vocabulary and do not belong in `SkillSelectorCore`.
    var systemImage: String {
        switch self {
        case .home: "house"
        case .project: "folder"
        case .system: "externaldrive"
        case .custom: "folder.badge.plus"
        }
    }
}
