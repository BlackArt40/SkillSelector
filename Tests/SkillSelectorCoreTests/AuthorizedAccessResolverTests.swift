import Foundation
import GRDB
import XCTest
@testable import SkillSelectorCore

/// Coverage for the access-resolution decision matrix of
/// `AuthorizedAccessResolver` (previously untested — the highest-risk gap
/// found by the 2026-09 review). All path logic runs on URL strings; the
/// bookmark adapter is a stub, so no real filesystem access happens.
final class AuthorizedAccessResolverTests: XCTestCase {
    /// Round-trips the URL through the bookmark data so every root resolves
    /// back to its own path, and records start/stop calls for lease checks.
    /// Paths use the /private/tmp spelling (no symlink component) so the
    /// resolved-target containment comparisons are stable.
    private final class RoundTripAdapter: BookmarkDataCreating, @unchecked Sendable {
        private(set) var startedURLs: [URL] = []
        private(set) var stoppedURLs: [URL] = []

        func createBookmarkData(for url: URL) throws -> Data {
            Data(url.standardizedFileURL.path.utf8)
        }

        func resolveBookmarkData(_ data: Data) throws -> BookmarkResolution {
            let path = String(decoding: data, as: UTF8.self)
            return BookmarkResolution(url: URL(fileURLWithPath: path), isStale: false)
        }

        func startAccessing(_ url: URL) -> Bool {
            startedURLs.append(url)
            return true
        }

        func stopAccessing(_ url: URL) {
            stoppedURLs.append(url)
        }
    }

    private func makeRoots(
        _ paths: [String]
    ) throws -> (AuthorizedAccessResolver, RoundTripAdapter, [AuthorizedRootSnapshot]) {
        let adapter = RoundTripAdapter()
        let store = BookmarkStore(database: try SkillStore.inMemory(), adapter: adapter)
        var roots: [AuthorizedRootSnapshot] = []
        for path in paths {
            roots.append(try store.save(url: URL(fileURLWithPath: path), kind: .project))
        }
        return (AuthorizedAccessResolver(bookmarks: store), adapter, roots)
    }

    private func skill(
        path: String,
        rootIDs: [String],
        resolvedTarget: String? = nil
    ) -> SkillSnapshot {
        SkillSnapshot(
            path: path,
            resolvedTarget: resolvedTarget,
            name: "demo",
            localDescription: nil,
            modificationDate: nil,
            agentIDs: ["claude-code"],
            rootIDs: rootIDs,
            entryFilename: "SKILL.md",
            parseDiagnostics: []
        )
    }

    func testResolvesLeasesForSkillCoveredByItsRoot() throws {
        let (resolver, _, roots) = try makeRoots(["/private/tmp/root-1"])
        let demo = skill(path: "/private/tmp/root-1/skills/demo/SKILL.md", rootIDs: [roots[0].id])

        let accesses = try resolver.resolveAccess(for: demo, authorizedRoots: roots)

        XCTAssertEqual(accesses.map(\.root.id), [roots[0].id])
        accesses.forEach { $0.lease.close() }
    }

    func testThrowsNoAuthorizedRootWhenSkillPathEscapesItsRoots() throws {
        let (resolver, adapter, roots) = try makeRoots(["/private/tmp/root-1"])
        // Inconsistent bookkeeping: the skill claims root-1 but lives outside.
        let demo = skill(path: "/elsewhere/demo/SKILL.md", rootIDs: [roots[0].id])

        XCTAssertThrowsError(try resolver.resolveAccess(for: demo, authorizedRoots: roots)) { error in
            XCTAssertEqual(error as? AuthorizedAccessError, .noAuthorizedRoot)
        }
        // The resolver closes its own leases before throwing.
        XCTAssertEqual(adapter.stoppedURLs, [roots[0].url.standardizedFileURL])
    }

    func testDestinationOutsideRootsFailsUnlessMarkedArbitrary() throws {
        let (resolver, adapter, roots) = try makeRoots(["/private/tmp/root-1"])
        let demo = skill(path: "/private/tmp/root-1/skills/demo/SKILL.md", rootIDs: [roots[0].id])

        XCTAssertThrowsError(try resolver.resolveAccess(
            for: demo,
            destinationRootURL: URL(fileURLWithPath: "/private/tmp/other"),
            authorizedRoots: roots
        )) { error in
            XCTAssertEqual(error as? AuthorizedAccessError, .noAuthorizedRoot)
        }
        XCTAssertEqual(adapter.stoppedURLs, [roots[0].url.standardizedFileURL])

        let arbitrary = try resolver.resolveAccess(
            for: demo,
            destinationRootURL: URL(fileURLWithPath: "/private/tmp/other"),
            authorizedRoots: roots,
            destinationIsArbitrary: true
        )
        XCTAssertEqual(arbitrary.map(\.root.id), [roots[0].id])
        arbitrary.forEach { $0.lease.close() }
    }

    func testResolvedTargetPullsInTheRootContainingTheRealTarget() throws {
        let (resolver, _, roots) = try makeRoots(["/private/tmp/root-1", "/private/tmp/root-2"])
        // The skill lives in root-1 but is a symlink into root-2; rootIDs
        // only knows root-1, so the resolved-target lookup must add root-2 —
        // otherwise the covered check would fail and the resolve would throw.
        let demo = skill(
            path: "/private/tmp/root-1/skills/demo/SKILL.md",
            rootIDs: [roots[0].id],
            resolvedTarget: "/private/tmp/root-2/real/demo/SKILL.md"
        )

        let accesses = try resolver.resolveAccess(for: demo, authorizedRoots: roots)

        XCTAssertEqual(Set(accesses.map(\.root.id)), Set(roots.map(\.id)))
        accesses.forEach { $0.lease.close() }
    }

    func testAllReferencedRootsGetLeasesWhenCovered() throws {
        let (resolver, adapter, roots) = try makeRoots(["/private/tmp/root-1", "/private/tmp/root-2"])
        let demo = skill(
            path: "/private/tmp/root-1/skills/demo/SKILL.md",
            rootIDs: [roots[0].id, roots[1].id]
        )

        let accesses = try resolver.resolveAccess(for: demo, authorizedRoots: roots)

        XCTAssertEqual(Set(accesses.map(\.root.id)), Set(roots.map(\.id)))
        XCTAssertEqual(adapter.startedURLs.count, 2)
        accesses.forEach { $0.lease.close() }
        XCTAssertEqual(adapter.stoppedURLs.count, 2)
    }
}
