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

    // An Agent wired only through MCP configs (no Skills on disk) still
    // appears in the sidebar: its servers are indexed config declarations.
    func testAgentsWithOnlyMcpServersRemainVisible() {
        let definitions = BuiltInAgentRegistry.make().definitions
        let mcpServers = [
            McpServerDescriptor(
                name: "context7",
                agentID: "codex",
                transport: .stdio,
                command: "npx",
                arguments: [],
                url: nil,
                configFile: "/tmp/config.toml",
                projectRootID: nil
            )
        ]

        let agentIDs = BrowserSidebar.detectedAgentIDs(from: [], hasAuthorization: true)
            .union(BrowserSidebar.mcpAgentIDs(from: mcpServers))
        XCTAssertEqual(agentIDs, ["codex"])
        XCTAssertEqual(
            BrowserSidebar.visibleAgentDefinitions(
                definitions: definitions,
                detectedAgentIDs: agentIDs
            ).map(\.id),
            ["codex"]
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
        XCTAssertEqual(
            BrowserDestination.fallback(afterRemoving: "root-1", from: .links),
            .links
        )
    }

    // AC-33/AC-35: system-directory entries appear only when their scan
    // found Skills; empty authorized directories show nothing.
    func testSystemDirectoryEntriesAppearOnlyWithSkills() {
        let home = AuthorizedRootSnapshot(
            id: "home-1",
            url: URL(fileURLWithPath: "/Users/me"),
            kind: .home
        )
        let emptySystem = AuthorizedRootSnapshot(
            id: "sys-1",
            url: URL(fileURLWithPath: "/etc/empty"),
            kind: .system
        )
        let counts: [BrowserDestination: Int] = [
            .system(rootID: "home-1"): 3,
            .system(rootID: "sys-1"): 0,
        ]
        XCTAssertEqual(
            BrowserSidebar.visibleSystemRoots([home, emptySystem], counts: counts).map(\.id),
            ["home-1"]
        )
        XCTAssertTrue(BrowserSidebar.visibleSystemRoots([emptySystem], counts: counts).isEmpty)
    }

    // AC-34: project entries appear only when the project holds Skills.
    func testProjectDirectoryEntriesAppearOnlyWithSkills() {
        let withSkills = AuthorizedRootSnapshot(
            id: "p-1",
            url: URL(fileURLWithPath: "/Users/me/demo-webapp"),
            kind: .project
        )
        let empty = AuthorizedRootSnapshot(
            id: "p-2",
            url: URL(fileURLWithPath: "/Users/me/empty-repo"),
            kind: .project
        )
        let counts: [BrowserDestination: Int] = [
            .project(rootID: "p-1"): 2,
            .project(rootID: "p-2"): 0,
        ]
        XCTAssertEqual(
            BrowserSidebar.visibleProjectRoots([withSkills, empty], counts: counts).map(\.id),
            ["p-1"]
        )
        XCTAssertTrue(BrowserSidebar.visibleProjectRoots([empty], counts: counts).isEmpty)
    }
}
