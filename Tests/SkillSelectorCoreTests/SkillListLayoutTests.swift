import Foundation
import XCTest

final class SkillListLayoutTests: XCTestCase {
    func testSkillListRootFillsColumnAndPinsControlsToTop() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/SkillSelector/Browser/SkillListView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(
            source.contains(".frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)"),
            "SkillListView must fill the navigation column so its controls stay pinned to the top"
        )
    }
}
