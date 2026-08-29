import Foundation
import XCTest
@testable import SkillSelectorCore

final class NearDuplicateSkillGrouperTests: XCTestCase {
    private func longBody(_ filler: String = "The assistant deploys review stacks and summarizes pull requests before handing them back. ") -> String {
        String(repeating: filler, count: 10)
    }

    private func snapshot(
        path: String,
        name: String,
        similarity: String?,
        content: String? = nil,
        ignoredNearGroup: String? = nil
    ) -> SkillSnapshot {
        SkillSnapshot(
            path: path,
            resolvedTarget: nil,
            name: name,
            localDescription: nil,
            modificationDate: nil,
            agentIDs: ["cursor"],
            rootIDs: ["home-root"],
            entryFilename: "SKILL.md",
            parseDiagnostics: [],
            contentFingerprint: content,
            similarityFingerprint: similarity,
            ignoredDuplicateGroup: nil,
            ignoredNearDuplicateGroup: ignoredNearGroup
        )
    }

    func testNearCopiesGroupWithSimilarityPercentages() {
        let original = SkillSimilarityFingerprint.compute(body: longBody())!
        let edited = SkillSimilarityFingerprint.compute(
            body: longBody().replacingOccurrences(of: "pull requests", with: "merge requests")
        )!
        let groups = NearDuplicateSkillGrouper.groups([
            snapshot(path: "/a", name: "Alpha", similarity: original),
            snapshot(path: "/b", name: "Beta", similarity: edited),
        ])

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].members.count, 2)
        XCTAssertEqual(groups[0].members.map(\.snapshot.path), ["/a", "/b"])
        XCTAssertTrue(groups[0].members.allSatisfy { $0.similarityPercent >= 80 })
    }

    func testUnrelatedSkillsDoNotGroup() {
        let first = SkillSimilarityFingerprint.compute(body: longBody())!
        let second = SkillSimilarityFingerprint.compute(
            body: longBody("Zebra migrations cross the savanna while satellites photograph river deltas at dawn. ")
        )!
        let groups = NearDuplicateSkillGrouper.groups([
            snapshot(path: "/a", name: "Alpha", similarity: first),
            snapshot(path: "/b", name: "Beta", similarity: second),
        ])
        XCTAssertTrue(groups.isEmpty)
    }

    /// Byte-identical copies belong to the exact-duplicates view; the near
    /// view must not re-report them.
    func testExactDuplicatesAreExcluded() {
        let body = longBody()
        let similarity = SkillSimilarityFingerprint.compute(body: body)!
        let content = "v2:shared"
        let groups = NearDuplicateSkillGrouper.groups([
            snapshot(path: "/a", name: "Alpha", similarity: similarity, content: content),
            snapshot(path: "/b", name: "Beta", similarity: similarity, content: content),
        ])
        XCTAssertTrue(groups.isEmpty)
    }

    func testSkillsWithoutSimilarityFingerprintsNeverGroup() {
        let groups = NearDuplicateSkillGrouper.groups([
            snapshot(path: "/a", name: "Alpha", similarity: nil, content: "v2:x"),
            snapshot(path: "/b", name: "Beta", similarity: nil, content: "v2:y"),
        ])
        XCTAssertTrue(groups.isEmpty)
    }

    func testIgnoredClusterDisappearsUntilMembershipChanges() {
        let original = SkillSimilarityFingerprint.compute(body: longBody())!
        let edited = SkillSimilarityFingerprint.compute(
            body: longBody().replacingOccurrences(of: "pull requests", with: "merge requests")
        )!
        let members = [
            snapshot(path: "/a", name: "Alpha", similarity: original),
            snapshot(path: "/b", name: "Beta", similarity: edited),
        ]
        let key = ["/a", "/b"].joined(separator: "\u{1f}")

        XCTAssertTrue(
            NearDuplicateSkillGrouper.groups(members.map {
                var copy = $0
                copy.ignoredNearDuplicateGroup = key
                return copy
            }).isEmpty,
            "an ignored cluster must leave the near view"
        )

        // A membership change (a new copy) produces a new key: the old
        // ignore goes stale and the cluster reappears.
        let third = SkillSimilarityFingerprint.compute(
            body: longBody().replacingOccurrences(of: "review stacks", with: "review boards")
        )!
        let expanded = members + [snapshot(path: "/c", name: "Gamma", similarity: third)]
        let regrouped = NearDuplicateSkillGrouper.groups(expanded.map {
            var copy = $0
            if copy.path == "/a" || copy.path == "/b" { copy.ignoredNearDuplicateGroup = key }
            return copy
        })
        XCTAssertEqual(regrouped.count, 1)
        XCTAssertEqual(regrouped[0].members.count, 3)
    }

    /// Transitive chaining: two copies each near the original land in one
    /// cluster together, even if they differ from each other more than the
    /// threshold allows.
    func testChainedSimilarityLandsInOneCluster() {
        let original = longBody()
        let left = original.replacingOccurrences(of: "pull requests", with: "merge requests")
        let right = original.replacingOccurrences(of: "review stacks", with: "review boards")
        let a = SkillSimilarityFingerprint.compute(body: original)!
        let b = SkillSimilarityFingerprint.compute(body: left)!
        let c = SkillSimilarityFingerprint.compute(body: right)!
        // Both edits are small enough to link through the original.
        XCTAssertTrue(SkillSimilarityFingerprint.areNearDuplicates(a, b))
        XCTAssertTrue(SkillSimilarityFingerprint.areNearDuplicates(a, c))

        let groups = NearDuplicateSkillGrouper.groups([
            snapshot(path: "/a", name: "Alpha", similarity: a),
            snapshot(path: "/b", name: "Beta", similarity: b),
            snapshot(path: "/c", name: "Gamma", similarity: c),
        ])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].members.count, 3)
    }
}
