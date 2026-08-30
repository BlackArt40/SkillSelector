import Foundation
import SkillSelectorCore

/// Roots that carry user-level or project-level configs, flattened
/// (home/system first, then project roots).
func scopedRoots(of roots: [AuthorizedRootSnapshot]) -> [AuthorizedRootSnapshot] {
    [roots.homeRoot].compactMap(\.self) + roots.projectRoots
}

/// Resolves the scoped roots' leases — the one shared ingestion for every
/// submodel reload. Callers defer-close the leases.
func resolveScopedAuthorizedAccesses(
    in roots: [AuthorizedRootSnapshot],
    through bookmarks: BookmarkStore?
) -> [AuthorizedRootAccess] {
    guard let bookmarks else { return [] }
    return scopedRoots(of: roots).compactMap { try? bookmarks.resolve(id: $0.id) }
}

/// Shared root-partitioning predicates for the state submodels: the single
/// user-level `.home`/`.system` root (optional) and the project roots.
extension Array where Element == AuthorizedRootSnapshot {
    var homeRoot: AuthorizedRootSnapshot? {
        first { $0.kind == .home || $0.kind == .system }
    }

    var projectRoots: [AuthorizedRootSnapshot] {
        filter { $0.kind == .project }
    }
}