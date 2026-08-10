import XCTest
@testable import SkillSelectorCore

final class DescriptionResolverTests: XCTestCase {
    func testPriorityCustomLocalFallback() {
        let all = DescriptionCandidates(
            custom: " Custom ",
            local: " Local ",
            fallback: " Fallback "
        )

        XCTAssertEqual(DescriptionResolver.resolve(all), "Custom")
        XCTAssertEqual(
            DescriptionResolver.resolve(
                DescriptionCandidates(custom: nil, local: all.local, fallback: all.fallback)
            ),
            "Local"
        )
        XCTAssertEqual(
            DescriptionResolver.resolve(
                DescriptionCandidates(custom: nil, local: nil, fallback: all.fallback)
            ),
            "Fallback"
        )
    }

    func testWhitespaceCandidatesAreIgnoredAndFallbackMayBeEmpty() {
        XCTAssertEqual(
            DescriptionResolver.resolve(
                DescriptionCandidates(custom: " \n ", local: "\t", fallback: "")
            ),
            ""
        )
    }

    func testRemovingCustomizationRestoresDeterministicLocalFallback() {
        let candidates = DescriptionCandidates(
            custom: "Personal summary",
            local: nil,
            fallback: "demo"
        )

        XCTAssertEqual(DescriptionResolver.resolve(candidates), "Personal summary")
        XCTAssertEqual(
            DescriptionResolver.resolve(
                DescriptionCandidates(custom: nil, local: nil, fallback: candidates.fallback)
            ),
            "demo"
        )
    }
}
