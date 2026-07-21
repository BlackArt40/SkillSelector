import XCTest
@testable import SkillSelectorCore

final class DescriptionResolverTests: XCTestCase {
    func testPriorityAndProvenance() {
        let all = DescriptionCandidates(
            custom: " Custom ",
            local: " Local ",
            fallback: " Fallback "
        )

        XCTAssertEqual(
            DescriptionResolver.resolve(all),
            EffectiveDescription(text: "Custom", source: .custom)
        )
        XCTAssertEqual(
            DescriptionResolver.resolve(
                DescriptionCandidates(custom: nil, local: all.local, fallback: all.fallback)
            ),
            EffectiveDescription(text: "Local", source: .local)
        )
        XCTAssertEqual(
            DescriptionResolver.resolve(
                DescriptionCandidates(custom: nil, local: nil, fallback: all.fallback)
            ),
            EffectiveDescription(text: "Fallback", source: .fallback)
        )
        XCTAssertEqual(
            DescriptionResolver.resolve(
                DescriptionCandidates(custom: nil, local: nil, fallback: all.fallback)
            ),
            EffectiveDescription(text: "Fallback", source: .fallback)
        )
    }

    func testWhitespaceCandidatesAreIgnoredAndFallbackMayBeEmpty() {
        XCTAssertEqual(
            DescriptionResolver.resolve(
                DescriptionCandidates(custom: " \n ", local: "\t", fallback: "")
            ),
            EffectiveDescription(text: "", source: .fallback)
        )
    }

    func testRemovingCustomizationRestoresDeterministicLocalFallback() {
        let candidates = DescriptionCandidates(
            custom: "Personal summary",
            local: nil,
            
            fallback: "demo"
        )

        XCTAssertEqual(DescriptionResolver.resolve(candidates).source, .custom)
        XCTAssertEqual(
            DescriptionResolver.resolve(
                DescriptionCandidates(custom: nil, local: nil, fallback: candidates.fallback)
            ),
            EffectiveDescription(text: "demo", source: .fallback)
        )
    }
}
