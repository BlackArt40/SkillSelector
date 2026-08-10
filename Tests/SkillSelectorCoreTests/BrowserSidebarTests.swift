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
            customDescription: nil,
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
}
