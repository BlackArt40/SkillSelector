import XCTest
@testable import SkillSelectorCore

/// The consistency list reuses the existing checkers rather than detecting
/// anything itself, so these tests are mostly about the assembly: which
/// category an item lands in, that a clean class still shows up as clean,
/// and that the headline number counts work rather than snapshots.
final class SkillHealthReportTests: XCTestCase {

    func testEmptyCorpusStillListsEveryCategory() {
        let sections = SkillHealthReport.sections(for: [])

        XCTAssertEqual(
            sections.map(\.category),
            [.exactDuplicates, .nearDuplicates, .unreachableLinks, .rulesDrift],
            "every category is listed, in declaration order, even when clean"
        )
        XCTAssertTrue(sections.allSatisfy { $0.items.isEmpty })
        XCTAssertEqual(SkillHealthReport.totalItemCount(in: sections), 0)
    }

    // MARK: - Rules drift

    func testRulesDriftFindingsBecomeItems() {
        let sections = SkillHealthReport.sections(
            for: [],
            rulesDrift: [drift(first: "/p/CLAUDE.md", second: "/p/AGENTS.md", paragraphs: 3)]
        )
        let items = section(.rulesDrift, in: sections).items

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].rulesDrift?.divergenceCount, 3)
        XCTAssertEqual(items[0].rulesDrift?.secondFilename, "AGENTS.md")
    }

    /// The drift case describes files, not skills — the snapshot list is
    /// empty rather than carrying an unrelated payload.
    func testRulesDriftItemCarriesNoSnapshots() {
        let sections = SkillHealthReport.sections(
            for: [snapshot("/work/a/tool", content: "same"), snapshot("/work/b/tool", content: "same")],
            rulesDrift: [drift(first: "/p/CLAUDE.md", second: "/p/AGENTS.md", paragraphs: 1)]
        )
        let item = section(.rulesDrift, in: sections).items[0]

        XCTAssertTrue(item.snapshots.isEmpty)
        XCTAssertNotNil(item.rulesDrift)
        XCTAssertEqual(section(.exactDuplicates, in: sections).count, 1)
        XCTAssertEqual(SkillHealthReport.totalItemCount(in: sections), 2)
    }

    func testRulesDriftIsCountedInTheHeadline() {
        let sections = SkillHealthReport.sections(
            for: [snapshot("/work/a/tool", content: "same"), snapshot("/work/b/tool", content: "same")],
            rulesDrift: [
                drift(first: "/p/CLAUDE.md", second: "/p/AGENTS.md", paragraphs: 1),
                drift(first: "/p/CLAUDE.md", second: "/p/.cursorrules", paragraphs: 2),
            ]
        )
        XCTAssertEqual(SkillHealthReport.totalItemCount(in: sections), 3)
    }

    func testRulesDriftItemsAreOrderedStably() {
        let findings = [
            drift(first: "/p/AGENTS.md", second: "/p/.cursorrules", paragraphs: 1),
            drift(first: "/p/CLAUDE.md", second: "/p/AGENTS.md", paragraphs: 1),
        ]
        let forward = SkillHealthReport.sections(for: [], rulesDrift: findings)
            .flatMap(\.items).map(\.id)
        let backward = SkillHealthReport.sections(for: [], rulesDrift: findings.reversed())
            .flatMap(\.items).map(\.id)

        XCTAssertEqual(forward, backward)
        XCTAssertEqual(forward, forward.sorted())
    }

    /// A pair too large to align reports zero divergences; the flag is what
    /// stops that being read as "no differences".
    func testUnalignedRulesDriftKeepsItsFlag() throws {
        let sections = SkillHealthReport.sections(
            for: [],
            rulesDrift: [drift(first: "/p/CLAUDE.md", second: "/p/AGENTS.md", paragraphs: 0, aligned: false)]
        )
        let finding = try XCTUnwrap(section(.rulesDrift, in: sections).items[0].rulesDrift)

        XCTAssertFalse(finding.isAligned)
        XCTAssertEqual(finding.divergenceCount, 0)
    }

    /// The headline acceptance case: one duplicate group plus one broken
    /// link is two things to look at.
    func testOneDuplicateGroupPlusOneBrokenLinkCountsAsTwo() {
        let sections = SkillHealthReport.sections(for: [
            snapshot("/work/a/tool", content: "same"),
            snapshot("/work/b/tool", content: "same"),
            snapshot("/work/c/ghost", resolvedTarget: Self.absentPath),
        ])

        XCTAssertEqual(section(.exactDuplicates, in: sections).count, 1)
        XCTAssertEqual(section(.unreachableLinks, in: sections).count, 1)
        XCTAssertEqual(SkillHealthReport.totalItemCount(in: sections), 2)
    }

    func testDuplicateItemCarriesEveryMember() throws {
        let members = [
            snapshot("/work/a/tool", content: "same"),
            snapshot("/work/b/tool", content: "same"),
            snapshot("/work/c/tool", content: "same"),
        ]
        let sections = SkillHealthReport.sections(for: members)
        let item = try XCTUnwrap(section(.exactDuplicates, in: sections).items.first)

        XCTAssertEqual(item.snapshots.count, 3)
        XCTAssertEqual(Set(item.snapshots.map(\.path)), Set(members.map(\.path)))
        XCTAssertEqual(item.category, .exactDuplicates)
    }

    func testFewerThanTwoCopiesIsNotADuplicateGroup() {
        let sections = SkillHealthReport.sections(for: [
            snapshot("/work/a/tool", content: "unique"),
        ])
        XCTAssertTrue(section(.exactDuplicates, in: sections).items.isEmpty)
    }

    /// Built from real SimHash fingerprints, because near-duplicate
    /// membership depends on the threshold the production code applies.
    func testNearDuplicatePairBecomesOneItem() throws {
        let wide = Self.repeatedRules(lines: 40)
        let drifted = wide.replacingOccurrences(of: "Rule 20:", with: "Rule twenty:")
        let a = try XCTUnwrap(SkillSimilarityFingerprint.compute(body: wide))
        let b = try XCTUnwrap(SkillSimilarityFingerprint.compute(body: drifted))
        XCTAssertTrue(
            SkillSimilarityFingerprint.areNearDuplicates(a, b),
            "fixture bodies no longer clear the near-duplicate threshold"
        )

        let sections = SkillHealthReport.sections(for: [
            snapshot("/work/a/notes", name: "notes", content: "near-a", similarity: a),
            snapshot("/work/b/notes", name: "notes", content: "near-b", similarity: b),
        ])
        let item = try XCTUnwrap(section(.nearDuplicates, in: sections).items.first)

        XCTAssertEqual(section(.nearDuplicates, in: sections).count, 1)
        XCTAssertEqual(item.snapshots.count, 2)
        // Distinct content fingerprints, so this is not also an exact pair.
        XCTAssertTrue(section(.exactDuplicates, in: sections).items.isEmpty)
    }

    func testSettledSymlinkAndPlainDirectoryAreNotReported() {
        let sections = SkillHealthReport.sections(for: [
            // A real path that exists, so the link resolves.
            snapshot("/work/live", resolvedTarget: "/usr"),
            snapshot("/work/plain"),
        ])
        XCTAssertTrue(section(.unreachableLinks, in: sections).items.isEmpty)
    }

    func testBrokenLinksAreListedInPathOrder() {
        let sections = SkillHealthReport.sections(for: [
            snapshot("/work/z/ghost", resolvedTarget: Self.absentPath),
            snapshot("/work/a/ghost", resolvedTarget: Self.absentPath),
        ])
        let paths = section(.unreachableLinks, in: sections).items.map { $0.snapshots[0].path }
        XCTAssertEqual(paths, ["/work/a/ghost", "/work/z/ghost"])
    }

    /// An ignored group means "stop telling me", and the list honours that
    /// because it delegates to the same grouper the duplicates view uses.
    func testIgnoredDuplicateGroupDropsOutOfTheList() {
        let ignoredKey = "same"
        let sections = SkillHealthReport.sections(for: [
            snapshot("/work/a/tool", content: ignoredKey, ignoredDuplicateGroup: ignoredKey),
            snapshot("/work/b/tool", content: ignoredKey, ignoredDuplicateGroup: ignoredKey),
        ])
        XCTAssertTrue(section(.exactDuplicates, in: sections).items.isEmpty)
    }

    /// The headline counts work, not snapshots: one copy that is both a
    /// duplicate and a broken link is two separate things to deal with, and
    /// collapsing them would understate the list.
    func testOneSnapshotCanContributeToTwoCategories() {
        let sections = SkillHealthReport.sections(for: [
            snapshot("/work/a/tool", content: "same"),
            snapshot("/work/b/tool", content: "same"),
            snapshot("/work/c/tool", content: "same", resolvedTarget: Self.absentPath),
        ])

        XCTAssertEqual(section(.exactDuplicates, in: sections).count, 1)
        XCTAssertEqual(section(.unreachableLinks, in: sections).count, 1)
        XCTAssertEqual(SkillHealthReport.totalItemCount(in: sections), 2)
        XCTAssertEqual(
            Set(sections.flatMap { $0.items.flatMap { $0.snapshots.map(\.path) } }).count,
            3,
            "three distinct snapshots, but only two items — the counts differ on purpose"
        )
    }

    func testItemIdentifiersAreStableAcrossRescans() {
        let members = [
            snapshot("/work/a/tool", content: "same"),
            snapshot("/work/b/tool", content: "same"),
        ]
        let first = SkillHealthReport.sections(for: members)
            .flatMap(\.items).map(\.id).sorted()
        let second = SkillHealthReport.sections(for: members.reversed())
            .flatMap(\.items).map(\.id).sorted()
        XCTAssertEqual(first, second)
    }

    // MARK: - Helpers

    /// A path that is not expected to exist, so `linkTargetIsUnreachable`
    /// reports the link as broken without depending on the test host.
    private static let absentPath = "/skillselector-tests/absent-target"

    /// Every category is always present — `sections(for:)` emits one per
    /// case, and `testEmptyCorpusStillListsEveryCategory` is what keeps that
    /// true. A miss would mean that test is already red, so returning an
    /// empty section here keeps `try` out of every assertion below.
    private func section(
        _ category: SkillHealthCategory,
        in sections: [SkillHealthSection]
    ) -> SkillHealthSection {
        sections.first { $0.category == category }
            ?? SkillHealthSection(category: category, items: [])
    }

    private static func repeatedRules(lines: Int) -> String {
        (0..<lines)
            .map { "Rule \($0): prefer the smallest change that solves the problem at hand." }
            .joined(separator: "\n")
    }

    private func drift(
        first: String,
        second: String,
        paragraphs: Int,
        aligned: Bool = true
    ) -> RulesDriftFinding {
        RulesDriftFinding(
            firstPath: first,
            firstFilename: (first as NSString).lastPathComponent,
            secondPath: second,
            secondFilename: (second as NSString).lastPathComponent,
            divergenceCount: paragraphs,
            isAligned: aligned
        )
    }

    private func snapshot(
        _ path: String,
        name: String = "demo",
        agents: [String] = [],
        content: String? = nil,
        similarity: String? = nil,
        resolvedTarget: String? = nil,
        modified: Date? = nil,
        ignoredDuplicateGroup: String? = nil
    ) -> SkillSnapshot {
        SkillSnapshot(
            path: path,
            resolvedTarget: resolvedTarget,
            name: name,
            localDescription: nil,
            modificationDate: modified,
            agentIDs: agents,
            rootIDs: ["project"],
            entryFilename: "SKILL.md",
            parseDiagnostics: [],
            contentFingerprint: content,
            similarityFingerprint: similarity,
            ignoredDuplicateGroup: ignoredDuplicateGroup
        )
    }
}
