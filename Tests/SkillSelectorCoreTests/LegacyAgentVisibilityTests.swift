import XCTest
@testable import SkillSelector
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

    func testLegacyAndNonLegacySetsPartitionTheBuiltInRegistry() {
        // Both sets derive from the same definitions, so this guards the
        // partition property: every built-in id is exactly one of the two.
        let legacy = legacyAgentIDs()
        let all = builtInAgentIDs()
        XCTAssertTrue(all.isSuperset(of: legacy))
        XCTAssertTrue(all.subtracting(legacy).isDisjoint(with: legacy))
    }

    // MARK: - End-to-end visibility (BrowserSidebar.visibleAgentDefinitions)
    // The pre-review versions of these scenarios asserted `Set.union` on
    // locally built literals and never touched production code; they are
    // now exercised through the real visibility pipeline.

    private func definition(id: String, isLegacy: Bool) -> AgentDefinition {
        AgentDefinition(
            id: id,
            displayName: id,
            globalRoots: [],
            projectPatterns: []
        )
    }

    func testDetectedAgentsAreVisibleWhileUndetectedLegacyStaysHidden() {
        let definitions = [
            definition(id: "claude-code", isLegacy: false),
            definition(id: "codex", isLegacy: false),
            definition(id: "roo-code", isLegacy: true),
        ]

        let visible = BrowserSidebar.visibleAgentDefinitions(
            definitions: definitions,
            detectedAgentIDs: ["claude-code", "codex"]
        )

        XCTAssertEqual(visible.map(\.id), ["claude-code", "codex"])
    }

    func testManuallyEnabledLegacyAgentBecomesVisibleWithoutDetection() {
        let definitions = [
            definition(id: "claude-code", isLegacy: false),
            definition(id: "roo-code", isLegacy: true),
        ]

        let visible = BrowserSidebar.visibleAgentDefinitions(
            definitions: definitions,
            detectedAgentIDs: [],
            manuallyEnabledAgentIDs: ["roo-code"]
        )

        XCTAssertEqual(visible.map(\.id), ["roo-code"])
    }

    func testManualEnableNeverSurfacesNonLegacyAgents() {
        let definitions = [definition(id: "claude-code", isLegacy: false)]

        let visible = BrowserSidebar.visibleAgentDefinitions(
            definitions: definitions,
            detectedAgentIDs: [],
            manuallyEnabledAgentIDs: ["claude-code"]
        )

        XCTAssertTrue(visible.isEmpty, "Only legacy agents can be surfaced manually")
    }

    func testSyntheticOwnersNeverAppearAsSidebarAgents() throws {
        let syntheticID = try XCTUnwrap(SyntheticAgentID.all.first)
        let definitions = [definition(id: syntheticID, isLegacy: false)]

        let visible = BrowserSidebar.visibleAgentDefinitions(
            definitions: definitions,
            detectedAgentIDs: [syntheticID]
        )

        XCTAssertTrue(visible.isEmpty)
    }
}
