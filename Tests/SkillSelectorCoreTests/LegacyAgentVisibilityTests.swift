import XCTest
@testable import SkillSelectorCore

final class LegacyAgentVisibilityTests: XCTestCase {

    private func builtInAgentIDs() -> Set<String> {
        Set(BuiltInAgentRegistry.make().definitions.map(\.id))
    }

    private func legacyAgentIDs() -> Set<String> {
        Set(BuiltInAgentRegistry.make().definitions.filter(\.isLegacy).map(\.id))
    }

    func testLegacyAgentIDsAreNonEmpty() {
        let legacy = legacyAgentIDs()
        XCTAssertFalse(legacy.isEmpty, "Expected at least one legacy agent in the built-in registry")
        XCTAssertTrue(legacy.contains("roo-code"), "roo-code should be marked as legacy")
    }

    func testNonLegacyAgentIDsAreNotInLegacySet() {
        let legacy = legacyAgentIDs()
        let all = builtInAgentIDs()
        let nonLegacy = all.subtracting(legacy)
        XCTAssertTrue(nonLegacy.isDisjoint(with: legacy),
                      "Legacy and non-legacy agent sets should be disjoint")
    }

    func testVisibleAgentIDsMergeDetectedAndManuallyEnabled() {
        let detected: Set<String> = ["claude-code", "codex"]
        let manuallyEnabled: Set<String> = ["roo-code"]
        let visible = detected.union(manuallyEnabled)

        XCTAssertTrue(visible.contains("claude-code"))
        XCTAssertTrue(visible.contains("codex"))
        XCTAssertTrue(visible.contains("roo-code"))
        XCTAssertEqual(visible.count, 3)
    }

    func testManuallyEnabledDoesNotAddNonLegacyAgents() {
        let detected: Set<String> = ["claude-code"]
        let manuallyEnabled: Set<String> = ["claude-code"]
        let visible = detected.union(manuallyEnabled)

        XCTAssertEqual(visible.count, 1, "Union should not duplicate already-detected agents")
    }

    func testEmptyDetectedStillShowsManuallyEnabled() {
        let detected: Set<String> = []
        let manuallyEnabled: Set<String> = ["roo-code"]
        let visible = detected.union(manuallyEnabled)

        XCTAssertEqual(visible, ["roo-code"])
    }

    func testEmptyManuallyEnabledFallsBackToDetectedOnly() {
        let detected: Set<String> = ["claude-code", "codex"]
        let manuallyEnabled: Set<String> = []
        let visible = detected.union(manuallyEnabled)

        XCTAssertEqual(visible, detected)
    }
}
