import XCTest
@testable import SkillSelectorCore

final class DescriptionResolverTests: XCTestCase {
    func testPriorityLocalFallback() {
        let all = DescriptionCandidates(local: " Local ", fallback: " Fallback ")

        XCTAssertEqual(DescriptionResolver.resolve(all), "Local")
        XCTAssertEqual(
            DescriptionResolver.resolve(DescriptionCandidates(local: nil, fallback: all.fallback)),
            "Fallback"
        )
    }

    func testWhitespaceCandidatesAreIgnoredAndFallbackMayBeEmpty() {
        XCTAssertEqual(
            DescriptionResolver.resolve(DescriptionCandidates(local: " \t", fallback: "")),
            ""
        )
    }

    func testSnapshotCandidatesUseLocalDescriptionThenName() {
        let snapshot = SkillSnapshot(
            path: "/tmp/demo",
            resolvedTarget: nil,
            name: "demo",
            localDescription: "From frontmatter",
            modificationDate: nil,
            agentIDs: [],
            rootIDs: [],
            entryFilename: "SKILL.md",
            parseDiagnostics: []
        )

        XCTAssertEqual(
            DescriptionResolver.resolve(DescriptionCandidates(snapshot: snapshot)),
            "From frontmatter"
        )

        let bare = SkillSnapshot(
            path: "/tmp/bare",
            resolvedTarget: nil,
            name: "bare",
            localDescription: nil,
            modificationDate: nil,
            agentIDs: [],
            rootIDs: [],
            entryFilename: "SKILL.md",
            parseDiagnostics: []
        )
        XCTAssertEqual(
            DescriptionResolver.resolve(DescriptionCandidates(snapshot: bare)),
            "bare"
        )
    }
}
