import XCTest
@testable import SkillSelector
@testable import SkillSelectorCore

@MainActor
final class BrowserSidebarTests: XCTestCase {
    private func snapshot(
        path: String = "/tmp/skills/demo",
        agentIDs: [String]
    ) -> SkillSnapshot {
        SkillSnapshot(
            path: path,
            resolvedTarget: nil,
            name: "demo",
            localDescription: nil,
            modificationDate: nil,
            agentIDs: agentIDs,
            rootIDs: ["root-1"],
            entryFilename: "SKILL.md",
            parseDiagnostics: []
        )
    }

    func testSidebarShowsOnlyAgentsWithOwnedSkillAssociations() {
        let definitions = BuiltInAgentRegistry.make().definitions

        XCTAssertTrue(BrowserSidebar.visibleAgentDefinitions(
            definitions: definitions,
            detectedAgentIDs: []
        ).isEmpty)
        XCTAssertEqual(BrowserSidebar.visibleAgentDefinitions(
            definitions: definitions,
            detectedAgentIDs: ["codex"]
        ).map(\.id), ["codex"])
        XCTAssertTrue(BrowserSidebar.visibleAgentDefinitions(
            definitions: definitions,
            detectedAgentIDs: ["shared"]
        ).isEmpty)
    }

    func testManuallyEnabledLegacyAgentsStayVisibleWithoutDetection() {
        let definitions = BuiltInAgentRegistry.make().definitions

        XCTAssertEqual(BrowserSidebar.visibleAgentDefinitions(
            definitions: definitions,
            detectedAgentIDs: [],
            manuallyEnabledAgentIDs: ["roo-code"]
        ).map(\.id), ["roo-code"])
        // Manual enable only applies to legacy agents; a non-legacy ID
        // enabled this way gains no sidebar row.
        XCTAssertTrue(BrowserSidebar.visibleAgentDefinitions(
            definitions: definitions,
            detectedAgentIDs: [],
            manuallyEnabledAgentIDs: ["codex"]
        ).isEmpty)
    }

    func testDetectedAgentIDsRequireAuthorizationAndUseIndexedSkills() {
        let codex = snapshot(agentIDs: ["codex"])
        let opencode = snapshot(path: "/opencode/demo", agentIDs: ["opencode"])

        // Never imported: nothing shows even if the store has records.
        XCTAssertTrue(BrowserSidebar.detectedAgentIDs(
            from: [codex],
            hasAuthorization: false
        ).isEmpty)
        // With authorization, every indexed Skill (the index only holds
        // Skills that exist on disk) contributes its agent IDs.
        XCTAssertEqual(
            BrowserSidebar.detectedAgentIDs(
                from: [codex, opencode],
                hasAuthorization: true
            ),
            ["codex", "opencode"]
        )
    }

    func testDestinationFallsBackToAllOnlyWhenBrowsedRootIsRemoved() {
        // Removing the browsed system or project root falls back to All.
        XCTAssertEqual(
            BrowserDestination.fallback(afterRemoving: "root-1", from: .system(rootID: "root-1")),
            .all
        )
        XCTAssertEqual(
            BrowserDestination.fallback(afterRemoving: "root-1", from: .project(rootID: "root-1")),
            .all
        )
        // Removing some other root leaves the destination untouched.
        XCTAssertEqual(
            BrowserDestination.fallback(afterRemoving: "root-2", from: .project(rootID: "root-1")),
            .project(rootID: "root-1")
        )
        // Root-scoped destinations are the only ones affected by a removal.
        XCTAssertEqual(
            BrowserDestination.fallback(afterRemoving: "root-1", from: .all),
            .all
        )
        XCTAssertEqual(
            BrowserDestination.fallback(afterRemoving: "root-1", from: .global),
            .global
        )
        XCTAssertEqual(
            BrowserDestination.fallback(afterRemoving: "root-1", from: .agent(id: "codex")),
            .agent(id: "codex")
        )
        XCTAssertEqual(
            BrowserDestination.fallback(afterRemoving: "root-1", from: .duplicates),
            .duplicates
        )
    }
}
