import XCTest
@testable import SkillSelectorCore

final class SmokeTests: XCTestCase {
    func testCoreReportsProductName() {
        XCTAssertEqual(SkillSelectorCore.productName, "SkillSelector")
    }
}
