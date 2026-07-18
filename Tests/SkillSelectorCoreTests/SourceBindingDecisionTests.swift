import XCTest
@testable import SkillSelectorCore

final class SourceBindingDecisionTests: XCTestCase {
    func testBindingConfirmationRequiresASelectedCandidateWithSourceBinding() {
        XCTAssertTrue(SourceBindingDecision.shouldRequestConfirmation(
            bindAsUpdateSource: true,
            sourceBinding: "github:acme/skills:demo"
        ))
        XCTAssertFalse(SourceBindingDecision.shouldRequestConfirmation(
            bindAsUpdateSource: true,
            sourceBinding: nil
        ))
        XCTAssertFalse(SourceBindingDecision.shouldRequestConfirmation(
            bindAsUpdateSource: false,
            sourceBinding: "github:acme/skills:demo"
        ))
    }
}
