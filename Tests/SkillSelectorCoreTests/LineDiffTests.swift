import XCTest
@testable import SkillSelectorCore

final class LineDiffTests: XCTestCase {
    func testIdenticalTextsAreAllContext() {
        let diff = LineDiff.compute(["a", "b", "c"], ["a", "b", "c"])
        XCTAssertEqual(diff.rows.map(\.kind), [.same, .same, .same])
        XCTAssertTrue(diff.rows.allSatisfy { $0.kind == .same })
        XCTAssertEqual(diff.addedCount, 0)
        XCTAssertEqual(diff.removedCount, 0)
    }

    func testPureInsertion() {
        let diff = LineDiff.compute(["a", "c"], ["a", "b", "c"])
        XCTAssertEqual(diff.rows.map(\.kind), [.same, .added, .same])
        XCTAssertEqual(diff.rows[1].text, "b")
        XCTAssertEqual(diff.addedCount, 1)
    }

    func testPureDeletion() {
        let diff = LineDiff.compute(["a", "b", "c"], ["a", "c"])
        XCTAssertEqual(diff.rows.map(\.kind), [.same, .removed, .same])
        XCTAssertEqual(diff.rows[1].text, "b")
        XCTAssertEqual(diff.removedCount, 1)
    }

    func testReplacementShowsRemovedThenAdded() {
        let diff = LineDiff.compute(["a", "old", "c"], ["a", "new", "c"])
        XCTAssertEqual(diff.rows.map(\.kind), [.same, .removed, .added, .same])
        XCTAssertEqual(diff.rows[1].text, "old")
        XCTAssertEqual(diff.rows[2].text, "new")
    }

    func testEmptyInputs() {
        XCTAssertTrue(LineDiff.compute([], []).rows.isEmpty)
        XCTAssertEqual(LineDiff.compute([], ["x"]).rows.map(\.kind), [.added])
        XCTAssertEqual(LineDiff.compute(["x"], []).rows.map(\.kind), [.removed])
    }

    func testPrefixAndSuffixAreKeptAsContext() {
        let diff = LineDiff.compute(
            ["head", "old", "tail"],
            ["head", "new", "tail"]
        )
        XCTAssertEqual(diff.rows.first?.kind, .same)
        XCTAssertEqual(diff.rows.first?.text, "head")
        XCTAssertEqual(diff.rows.last?.kind, .same)
        XCTAssertEqual(diff.rows.last?.text, "tail")
    }

    /// The DP guard: a pathological middle degrades to a replace block
    /// instead of allocating a giant table.
    func testHugeUnrelatedMiddlesDegradeToReplaceBlock() {
        let left = (0..<3000).map { "left \($0)" }
        let right = (0..<3000).map { "right \($0)" }
        let diff = LineDiff.compute(left, right)
        XCTAssertEqual(diff.addedCount, 3000)
        XCTAssertEqual(diff.removedCount, 3000)
        XCTAssertTrue(diff.rows.allSatisfy { $0.kind != .same })
    }
}
