import Foundation
import XCTest
@testable import SkillSelectorCore

final class URLContainmentTests: XCTestCase {
    func testExactMatchIsContained() {
        let url = URL(fileURLWithPath: "/Users/alice/skills")
        let root = URL(fileURLWithPath: "/Users/alice/skills")
        XCTAssertTrue(url.isContained(in: root))
    }

    func testChildIsContained() {
        let url = URL(fileURLWithPath: "/Users/alice/skills/demo/SKILL.md")
        let root = URL(fileURLWithPath: "/Users/alice/skills")
        XCTAssertTrue(url.isContained(in: root))
    }

    func testSiblingIsNotContained() {
        let url = URL(fileURLWithPath: "/Users/bob/skills/demo")
        let root = URL(fileURLWithPath: "/Users/alice/skills")
        XCTAssertFalse(url.isContained(in: root))
    }

    func testPartialPrefixIsNotContained() {
        let url = URL(fileURLWithPath: "/Users/alice-other/skills")
        let root = URL(fileURLWithPath: "/Users/alice/skills")
        XCTAssertFalse(url.isContained(in: root))
    }

    func testShorterPathIsNotContained() {
        let url = URL(fileURLWithPath: "/Users/alice")
        let root = URL(fileURLWithPath: "/Users/alice/skills")
        XCTAssertFalse(url.isContained(in: root))
    }

    func testMultipleRootsChecksAny() {
        let url = URL(fileURLWithPath: "/Users/alice/skills/demo")
        let roots = [
            URL(fileURLWithPath: "/Users/bob/skills"),
            URL(fileURLWithPath: "/Users/alice/skills"),
        ]
        XCTAssertTrue(url.isContained(inAny: roots))
    }

    func testMultipleRootsFailsWhenNoneMatch() {
        let url = URL(fileURLWithPath: "/Users/carol/skills/demo")
        let roots = [
            URL(fileURLWithPath: "/Users/alice/skills"),
            URL(fileURLWithPath: "/Users/bob/skills"),
        ]
        XCTAssertFalse(url.isContained(inAny: roots))
    }

    func testEmptyRootsReturnsFalse() {
        let url = URL(fileURLWithPath: "/Users/alice/skills/demo")
        XCTAssertFalse(url.isContained(inAny: []))
    }

    func testParentTraversalIsNotContainedEvenWhenLexicallyInside() {
        // /a/b/../c lexically sits "inside" /a/b but resolves to /a/c, which
        // is outside. isContained must not bless it (audit F-03). The
        // internal standardization resolves the ".." before the comparison.
        let url = URL(fileURLWithPath: "/a/b/../c")
        let root = URL(fileURLWithPath: "/a/b")
        XCTAssertFalse(url.isContained(in: root))
    }

    func testTraversalInRootIsResolvedBeforeComparison() {
        // The root's own ".." is resolved by standardization; the comparison
        // then works on the canonical root, which is the safe behavior.
        let url = URL(fileURLWithPath: "/a/b/c")
        let root = URL(fileURLWithPath: "/a/x/../b")
        XCTAssertTrue(url.isContained(in: root))
    }

    func testStandardizationStillAcceptsNormalChild() {
        // Callers that standardized already must see no behavior change.
        let url = URL(fileURLWithPath: "/a/b/c").standardizedFileURL
        let root = URL(fileURLWithPath: "/a/b").standardizedFileURL
        XCTAssertTrue(url.isContained(in: root))
    }

    func testStandaloneDotInChildIsResolvedAndStillContained() {
        // "/a/b/./c" is the same directory as "/a/b/c"; standardization
        // makes the containment decision on the canonical path.
        let url = URL(fileURLWithPath: "/a/b/./c")
        let root = URL(fileURLWithPath: "/a/b")
        XCTAssertTrue(url.isContained(in: root))
    }
}
