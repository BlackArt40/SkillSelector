import XCTest
@testable import SkillSelector
@testable import SkillSelectorCore

final class AuthorizedRootKindPresentationTests: XCTestCase {
    func testSystemImagePerKind() {
        XCTAssertEqual(AuthorizedRootKind.home.systemImage, "house")
        XCTAssertEqual(AuthorizedRootKind.project.systemImage, "folder")
        XCTAssertEqual(AuthorizedRootKind.system.systemImage, "externaldrive")
        XCTAssertEqual(AuthorizedRootKind.custom.systemImage, "folder.badge.plus")
    }
}
