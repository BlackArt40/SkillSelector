import XCTest
@testable import SkillSelector
@testable import SkillSelectorCore

@MainActor
final class BrowserSidebarTests: XCTestCase {
    private func snapshot(
        path: String = "/tmp/skills/demo",
        availability: SkillAvailability,
        agentIDs: [String]
    ) -> SkillSnapshot {
        SkillSnapshot(
            path: path,
            resolvedTarget: nil,
            name: "demo",
            localDescription: nil,
            customDescription: nil,
            modificationDate: nil,
            availability: availability,
            unavailableReason: nil,
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

    func testDetectedAgentIDsRequireAuthorizationAndAvailableRecords() {
        let availableCodex = snapshot(availability: .available, agentIDs: ["codex"])
        let availableOpencode = snapshot(availability: .available, agentIDs: ["opencode"])
        let staleCodex = snapshot(path: "/stale/codex", availability: .unavailable, agentIDs: ["codex"])

        // Never imported: nothing shows even if the store has records.
        XCTAssertTrue(BrowserSidebar.detectedAgentIDs(
            from: [availableCodex],
            hasAuthorization: false
        ).isEmpty)
        // Stale (revoked / missing) records do not contribute agents.
        XCTAssertTrue(BrowserSidebar.detectedAgentIDs(
            from: [staleCodex],
            hasAuthorization: true
        ).isEmpty)
        // Only agents owned by currently available Skills are detected.
        XCTAssertEqual(
            BrowserSidebar.detectedAgentIDs(
                from: [availableCodex, staleCodex, availableOpencode],
                hasAuthorization: true
            ),
            ["codex", "opencode"]
        )
    }
}
