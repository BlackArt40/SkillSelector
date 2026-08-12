import Foundation

public enum AuthorizedAccessError: Error, Equatable, Sendable {
    case noAuthorizedRoot
}

/// Resolves the security-scoped root accesses that cover a Skill document and
/// (optionally) a file-operation destination, then verifies that the resolved
/// accesses actually cover the logical path, the resolved target, and the
/// destination.
///
/// Single implementation of the access-resolution decision shared by the
/// document reader and the file-operation planner. The returned accesses hold
/// open leases; the caller is responsible for closing them (the resolver
/// closes its own leases before throwing).
public struct AuthorizedAccessResolver: @unchecked Sendable {
    private let bookmarks: BookmarkStore

    public init(bookmarks: BookmarkStore) {
        self.bookmarks = bookmarks
    }

    public func resolveAccess(
        for skill: SkillSnapshot,
        destinationRootURL: URL? = nil,
        authorizedRoots: [AuthorizedRootSnapshot],
        destinationIsArbitrary: Bool = false
    ) throws -> [AuthorizedRootAccess] {
        var requiredRootIDs = Set(skill.rootIDs)
        if let resolvedTarget = skill.resolvedTarget.map(URL.init(fileURLWithPath:)) {
            requiredRootIDs.formUnion(authorizedRoots.rootIDs(containingResolvedURL: resolvedTarget))
        }
        if let destinationRootURL, !destinationIsArbitrary {
            requiredRootIDs.formUnion(authorizedRoots.rootIDs(containingLogicalURL: destinationRootURL))
        }

        var accesses: [AuthorizedRootAccess] = []
        var firstResolutionError: Error?
        for rootID in requiredRootIDs.sorted() {
            do {
                accesses.append(try bookmarks.resolve(id: rootID))
            } catch {
                firstResolutionError = firstResolutionError ?? error
            }
        }

        guard isCovered(
            skill: skill,
            destinationRootURL: destinationIsArbitrary ? nil : destinationRootURL,
            accesses: accesses
        ) else {
            accesses.forEach { $0.lease.close() }
            if let firstResolutionError { throw firstResolutionError }
            throw AuthorizedAccessError.noAuthorizedRoot
        }
        return accesses
    }

    private func isCovered(
        skill: SkillSnapshot,
        destinationRootURL: URL?,
        accesses: [AuthorizedRootAccess]
    ) -> Bool {
        let source = URL(fileURLWithPath: skill.path)
        let logicalSourceCovered = accesses.contains {
            source.isContained(in: $0.root.url.standardizedFileURL)
        }
        let resolvedSourceCovered = skill.resolvedTarget.map(URL.init(fileURLWithPath:)).map { target in
            accesses.contains {
                target.standardizedFileURL.isContained(
                    in: $0.root.url.resolvingSymlinksInPath().standardizedFileURL
                )
            }
        } ?? true
        let destinationCovered = destinationRootURL.map { destination in
            accesses.contains {
                destination.isContained(in: $0.root.url.standardizedFileURL)
            }
        } ?? true
        return logicalSourceCovered && resolvedSourceCovered && destinationCovered
    }
}
