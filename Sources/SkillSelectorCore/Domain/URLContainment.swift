import Foundation

public extension URL {
    /// Returns true if this URL's path is at or beneath the given root directory.
    ///
    /// Defensive by construction (audit F-03): both sides are standardized
    /// here and paths still containing "." or ".." components are rejected.
    /// Callers that already standardized get an idempotent no-op; callers
    /// that did not can no longer accidentally bless a path that lexically
    /// looks contained but resolves outside the root.
    func isContained(in root: URL) -> Bool {
        let candidate = standardizedFileURL
        let root = root.standardizedFileURL
        let candidateComponents = candidate.pathComponents
        let rootComponents = root.pathComponents
        guard !candidateComponents.contains(".."),
              !candidateComponents.contains("."),
              !rootComponents.contains(".."),
              !rootComponents.contains(".") else {
            return false
        }
        return candidateComponents.count >= rootComponents.count
            && Array(candidateComponents.prefix(rootComponents.count)) == rootComponents
    }

    /// Returns true if this URL's path is at or beneath any of the given root directories.
    func isContained(inAny roots: [URL]) -> Bool {
        roots.contains { isContained(in: $0) }
    }
}

public extension Array where Element == AuthorizedRootSnapshot {
    func rootIDs(containingLogicalURL url: URL) -> Set<String> {
        Set(filter {
            url.standardizedFileURL.isContained(in: $0.url.standardizedFileURL)
        }.map(\.id))
    }

    func rootIDs(containingResolvedURL url: URL) -> Set<String> {
        Set(filter {
            url.standardizedFileURL.isContained(
                in: $0.url.resolvingSymlinksInPath().standardizedFileURL
            )
        }.map(\.id))
    }
}
