import XCTest
@testable import SkillSelectorCore

/// The paragraph-level comparison behind cross-file rules drift.
///
/// The property that carries the feature is that a small edit stays a small
/// report: an inserted or reworded paragraph must not make every paragraph
/// after it look changed. Several tests below exist only to pin that.
final class RulesStructuralDiffTests: XCTestCase {

    /// Six blocks: a heading and a paragraph for each of three sections.
    private let base = [
        "# Alpha", "Body text for Alpha.", "",
        "# Beta", "Body text for Beta.", "",
        "# Gamma", "Body text for Gamma.", "",
    ]

    func testIdenticalBodiesReportNothing() {
        let result = RulesStructuralDiff.compare(base, base)
        XCTAssertTrue(result.isIdentical)
        XCTAssertTrue(result.isAligned)
        XCTAssertTrue(result.divergences.isEmpty)
        XCTAssertEqual(result.firstBlockCount, 6)
        XCTAssertEqual(result.secondBlockCount, 6)
    }

    /// Trailing whitespace is not content — two files that differ only there
    /// have not drifted.
    func testTrailingWhitespaceAloneIsNotDrift() {
        let padded = base.map { $0.isEmpty ? $0 : $0 + "   " }
        let result = RulesStructuralDiff.compare(base, padded)
        XCTAssertTrue(result.isIdentical)
        XCTAssertTrue(result.divergences.isEmpty)
    }

    func testRewordedParagraphIsOneChangedBlock() {
        var reworded = base
        reworded[4] = "Body text for Beta, reworded."
        let result = RulesStructuralDiff.compare(base, reworded)

        XCTAssertFalse(result.isIdentical)
        XCTAssertEqual(result.divergences.count, 1)
        let divergence = result.divergences[0]
        XCTAssertEqual(divergence.kind, .changed)
        XCTAssertEqual(divergence.firstBlock, 4)
        XCTAssertEqual(divergence.secondBlock, 4)
        XCTAssertEqual(divergence.firstText, "Body text for Beta.")
        XCTAssertEqual(divergence.secondText, "Body text for Beta, reworded.")
    }

    /// The regression guard for the whole design: editing one paragraph must
    /// not shift the alignment and report every later paragraph as changed.
    ///
    /// Index 1 is the paragraph itself — index 2 is the blank line after it,
    /// and overwriting that would merge two blocks instead of rewording one.
    func testEditingTheMiddleDoesNotCascade() {
        var reworded = base
        reworded[1] = "Body text for Alpha, reworded."
        let result = RulesStructuralDiff.compare(base, reworded)

        XCTAssertEqual(result.divergences.count, 1)
        XCTAssertEqual(result.divergences.first?.firstBlock, 2)
        XCTAssertEqual(result.divergences.first?.kind, .changed)
        XCTAssertEqual(
            result.firstBlockCount,
            result.secondBlockCount,
            "a reworded paragraph must not change how many blocks there are"
        )
    }

    func testInsertedParagraphIsReportedAsAdditionsOnly() {
        var inserted = base
        inserted.insert(contentsOf: ["# Beta-two", "Extra paragraph.", ""], at: 3)
        let result = RulesStructuralDiff.compare(base, inserted)

        XCTAssertEqual(result.divergences.count, 2)
        XCTAssertTrue(result.divergences.allSatisfy { $0.kind == .onlyInSecond })
        XCTAssertEqual(result.divergences.map(\.secondBlock), [3, 4])
        XCTAssertEqual(result.firstBlockCount, 6)
        XCTAssertEqual(result.secondBlockCount, 8)
    }

    func testRemovedParagraphIsReportedAsRemovalsOnly() {
        var removed = base
        removed.removeSubrange(3..<6)
        let result = RulesStructuralDiff.compare(base, removed)

        XCTAssertEqual(result.divergences.count, 2)
        XCTAssertTrue(result.divergences.allSatisfy { $0.kind == .onlyInFirst })
        // "# Beta" is block 3 — blocks 1 and 2 are the "# Alpha" heading and
        // its paragraph, and the empty strings between pages are not blocks.
        XCTAssertEqual(result.divergences.map(\.firstBlock), [3, 4])
    }

    func testAppendedParagraphLandsAtTheEnd() {
        let result = RulesStructuralDiff.compare(base, base + ["# Zeta", "Tail paragraph.", ""])

        XCTAssertEqual(result.divergences.count, 2)
        XCTAssertEqual(result.divergences.map(\.secondBlock), [7, 8])
        XCTAssertTrue(result.divergences.allSatisfy { $0.kind == .onlyInSecond })
    }

    func testEveryBlockChangedWhenNothingMatches() {
        let other = [
            "# One", "Body text for One.", "",
            "# Two", "Body text for Two.", "",
            "# Three", "Body text for Three.", "",
        ]
        let result = RulesStructuralDiff.compare(base, other)

        XCTAssertEqual(result.divergences.count, 6)
        XCTAssertTrue(result.divergences.allSatisfy { $0.kind == .changed })
    }

    func testEmptyOnBothSides() {
        let result = RulesStructuralDiff.compare([], [])
        XCTAssertTrue(result.isIdentical)
        XCTAssertTrue(result.divergences.isEmpty)
        XCTAssertEqual(result.firstBlockCount, 0)
    }

    func testEmptyOnOneSide() {
        let result = RulesStructuralDiff.compare(base, [])
        XCTAssertFalse(result.isIdentical)
        XCTAssertEqual(result.divergences.count, 6)
        XCTAssertTrue(result.divergences.allSatisfy { $0.kind == .onlyInFirst })
    }

    // MARK: - Block splitting

    func testHeadingStandsAloneAsItsOwnBlock() {
        let blocks = RulesStructuralDiff.blocks(
            in: ["# Title", "Prose under the title.", "", "Second paragraph."]
        )
        XCTAssertEqual(
            blocks,
            ["# Title", "Prose under the title.", "Second paragraph."],
            "a heading must not be glued to the prose beneath it"
        )
    }

    func testConsecutiveNonBlankLinesFormOneBlock() {
        let blocks = RulesStructuralDiff.blocks(in: ["line one", "line two", "", "line three"])
        XCTAssertEqual(blocks, ["line one\nline two", "line three"])
    }

    func testBlankLinePaddingIsDropped() {
        let blocks = RulesStructuralDiff.blocks(in: ["", "", "# Title", "", "", "Prose.", "", ""])
        XCTAssertEqual(blocks, ["# Title", "Prose."])
    }

    // MARK: - Bound

    /// A megabyte of one-line paragraphs is not a rules file, but the reader
    /// will hand it to us, so the comparison has to stay bounded instead of
    /// allocating an O(n·m) table for it.
    func testOversizedBodiesFallBackToIdentityWithoutAligning() {
        let big = (0..<900).flatMap { ["Paragraph \($0).", ""] }

        let same = RulesStructuralDiff.compare(big, big)
        XCTAssertFalse(same.isAligned)
        XCTAssertTrue(same.isIdentical)
        XCTAssertTrue(same.divergences.isEmpty)
        XCTAssertEqual(same.firstBlockCount, 900)

        let differs = RulesStructuralDiff.compare(big, big + ["Extra."])
        XCTAssertFalse(differs.isAligned)
        XCTAssertFalse(
            differs.isIdentical,
            "an unaligned comparison still knows the files differ, it just cannot say where"
        )
        XCTAssertTrue(differs.divergences.isEmpty)
    }

    func testBodiesExactlyAtTheCapStillAlign() {
        let atCap = (0..<RulesStructuralDiff.maximumAlignedBlocks)
            .flatMap { ["P\($0).", ""] }
        let result = RulesStructuralDiff.compare(atCap, atCap)
        XCTAssertTrue(result.isAligned)
        XCTAssertEqual(result.firstBlockCount, RulesStructuralDiff.maximumAlignedBlocks)
    }
}
