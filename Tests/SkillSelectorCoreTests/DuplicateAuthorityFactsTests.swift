import XCTest
@testable import SkillSelectorCore

/// The facts shown beside each copy of a duplicate group. Two properties
/// matter more than the values: a win always means a real distinction (a tie
/// claims nothing), and unknown data never wins by default.
final class DuplicateAuthorityFactsTests: XCTestCase {

    func testShallowestCopyWinsPathDepth() {
        let facts = DuplicateAuthorityFacts.facts(for: [
            snapshot("/a/b/c/d/tool"),
            snapshot("/tool"),
        ])
        // Components include the root: "/a/b/c/d/tool" is 6, "/tool" is 2.
        XCTAssertEqual(facts.map(\.pathDepth), [6, 2])
        XCTAssertEqual(won(facts[0]), [])
        XCTAssertEqual(won(facts[1]), [.pathDepth])
    }

    func testNewestCopyWinsModificationDate() {
        let older = Date(timeIntervalSince1970: 1_000)
        let newer = Date(timeIntervalSince1970: 2_000)
        let facts = DuplicateAuthorityFacts.facts(for: [
            snapshot("/tool", modified: older),
            snapshot("/tool", modified: newer),
        ])
        XCTAssertEqual(won(facts[0]), [])
        XCTAssertEqual(won(facts[1]), [.modificationDate])
    }

    func testMostReferencedCopyWinsReferencingAgents() {
        let facts = DuplicateAuthorityFacts.facts(for: [
            snapshot("/a/tool", agents: ["cursor"]),
            snapshot("/b/tool", agents: ["cursor", "codex", "cline"]),
        ])
        XCTAssertEqual(facts.map(\.referencingAgentCount), [1, 3])
        XCTAssertEqual(won(facts[0]), [])
        XCTAssertEqual(won(facts[1]), [.referencingAgents])
    }

    func testOneCopyCanWinEveryCriterion() {
        let facts = DuplicateAuthorityFacts.facts(for: [
            snapshot("/deep/nested/path/tool", agents: ["cursor"], modified: Date(timeIntervalSince1970: 1_000)),
            snapshot("/shared/tool",
                     agents: ["cursor", "codex", "cline"],
                     modified: Date(timeIntervalSince1970: 5_000)),
        ])
        XCTAssertEqual(won(facts[0]), [])
        XCTAssertEqual(won(facts[1]), [.pathDepth, .modificationDate, .referencingAgents])
        XCTAssertEqual(facts[1].winCount, 3)
    }

    /// Identical copies must claim nothing. Anything else would be a
    /// tie-break the app invented, which is exactly what this design refuses
    /// to do.
    func testIdenticalCopiesAreTiedAndWinNothing() {
        let same = Date(timeIntervalSince1970: 1_000)
        let facts = DuplicateAuthorityFacts.facts(for: [
            snapshot("/tool", agents: ["cursor"], modified: same),
            snapshot("/tool", agents: ["cursor"], modified: same),
        ])
        XCTAssertEqual(won(facts[0]), [])
        XCTAssertEqual(won(facts[1]), [])
        XCTAssertEqual(facts.map(\.winCount), [0, 0])
    }

    func testOnlyTheTiedCriterionIsUnclaimed() {
        let same = Date(timeIntervalSince1970: 1_000)
        let facts = DuplicateAuthorityFacts.facts(for: [
            snapshot("/a/tool", agents: ["cursor"], modified: same),
            snapshot("/a/tool", agents: ["cursor"], modified: same),
            snapshot("/a/deeper/tool", agents: ["cursor"], modified: same),
        ])
        // Depth 3, 3, 4 — the two shallow copies tie, so pathDepth is
        // claimed by nobody; modificationDate is tied across all three.
        XCTAssertEqual(facts.map(\.pathDepth), [3, 3, 4])
        XCTAssertEqual(facts.map(\.winCount), [0, 0, 0])
    }

    /// "Unknown" is not "oldest": a copy that never recorded a date must not
    /// collect the criterion by default.
    func testACopyWithNoDateCannotWinTheDateCriterion() {
        let facts = DuplicateAuthorityFacts.facts(for: [
            snapshot("/a/tool", modified: nil),
            snapshot("/b/tool", modified: Date(timeIntervalSince1970: 2_000)),
        ])
        XCTAssertNil(facts[0].modificationDate)
        XCTAssertEqual(won(facts[0]), [])
        XCTAssertEqual(won(facts[1]), [.modificationDate])
    }

    func testWhenNobodyHasADateTheCriterionIsUnclaimed() {
        let facts = DuplicateAuthorityFacts.facts(for: [
            snapshot("/a/tool", modified: nil),
            snapshot("/b/tool", modified: nil),
        ])
        XCTAssertTrue(facts.allSatisfy { $0.wonCriteria.isEmpty })
    }

    /// Synthetic owners mark the app's own scopes, not an Agent's use, so
    /// counting them would inflate copies equally and say nothing.
    func testSyntheticOwnersAreNotCountedAsReferencingAgents() {
        let facts = DuplicateAuthorityFacts.facts(for: [
            snapshot("/a/tool", agents: [SyntheticAgentID.system, SyntheticAgentID.custom]),
            snapshot("/b/tool", agents: ["cursor"]),
        ])
        XCTAssertEqual(facts.map(\.referencingAgentCount), [0, 1])
        XCTAssertEqual(won(facts[0]), [])
        XCTAssertEqual(won(facts[1]), [.referencingAgents])
    }

    func testFactsKeepTheOrderTheyWereGiven() {
        let facts = DuplicateAuthorityFacts.facts(for: [
            snapshot("/c/tool"),
            snapshot("/a/tool"),
            snapshot("/b/tool"),
        ])
        XCTAssertEqual(facts.map(\.snapshot.path), ["/c/tool", "/a/tool", "/b/tool"])
    }

    func testEmptyInputProducesNoFacts() {
        XCTAssertTrue(DuplicateAuthorityFacts.facts(for: []).isEmpty)
    }

    func testWinCountAgreesWithTheWonCriteriaSet() {
        let facts = DuplicateAuthorityFacts.facts(for: [
            snapshot("/a/tool", agents: ["cursor"]),
            snapshot("/b/tool", agents: ["cursor", "codex"]),
        ])
        for fact in facts {
            XCTAssertEqual(fact.winCount, fact.wonCriteria.count)
            XCTAssertTrue(
                fact.wonCriteria.isSubset(of: Set(DuplicateCriterion.allCases)),
                "a criterion outside the declared set would not be explainable"
            )
        }
    }

    // MARK: - Helpers

    private func won(_ facts: DuplicateMemberFacts) -> Set<DuplicateCriterion> {
        facts.wonCriteria
    }

    private func snapshot(
        _ path: String,
        agents: [String] = [],
        modified: Date? = nil
    ) -> SkillSnapshot {
        SkillSnapshot(
            path: path,
            resolvedTarget: nil,
            name: "tool",
            localDescription: nil,
            modificationDate: modified,
            agentIDs: agents,
            rootIDs: ["project"],
            entryFilename: "SKILL.md",
            parseDiagnostics: []
        )
    }
}
