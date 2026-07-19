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
}
