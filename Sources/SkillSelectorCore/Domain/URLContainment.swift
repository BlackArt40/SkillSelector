import Foundation

public extension URL {
    /// Returns true if this URL's path is at or beneath the given root directory.
    func isContained(in root: URL) -> Bool {
        let candidateComponents = pathComponents
        let rootComponents = root.pathComponents
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
