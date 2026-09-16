import XCTest
@testable import SkillSelectorCore

final class McpScopeConflictsTests: XCTestCase {

    func testNameOnlyInGlobalScopeIsNotAConflict() {
        let name = "filesystem"
        let conflicts = McpScopeConflicts.detect(in: [
            server(name: name, configFile: "/Users/me/.cursor/mcp.json")
        ])
        XCTAssertTrue(conflicts.isEmpty)
    }

    func testNameOnlyInProjectScopeIsNotAConflict() {
        let conflicts = McpScopeConflicts.detect(in: [
            server(name: "filesystem", configFile: "/work/app/.cursor/mcp.json", projectRootID: "app")
        ])
        XCTAssertTrue(conflicts.isEmpty)
    }

    func testSameNameInBothScopesIsAConflict() {
        let global = server(name: "filesystem", configFile: "/Users/me/.cursor/mcp.json")
        let project = server(
            name: "filesystem",
            configFile: "/work/app/.cursor/mcp.json",
            projectRootID: "app"
        )

        let conflicts = McpScopeConflicts.detect(in: [global, project])

        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(conflicts.first?.name, "filesystem")
        XCTAssertEqual(conflicts.first?.global.id, global.id)
        XCTAssertEqual(conflicts.first?.project.id, project.id)
    }

    /// Matching is by name, the identity an MCP client compares. A renamed
    /// copy is two servers, not a collision.
    func testDifferentNamesInBothScopesAreNotAConflict() {
        let conflicts = McpScopeConflicts.detect(in: [
            server(name: "filesystem", configFile: "/Users/me/.cursor/mcp.json"),
            server(name: "filesystem-prod", configFile: "/work/app/.cursor/mcp.json", projectRootID: "app"),
        ])
        XCTAssertTrue(conflicts.isEmpty)
    }

    /// Two project roots declaring the same name still produce exactly one
    /// conflict against the global declaration, and the same one every run —
    /// otherwise the reported pair would shuffle between scans.
    func testRepeatedNamesPickTheSameDeclarationDeterministically() {
        let input = [
            server(name: "filesystem", configFile: "/work/b/.cursor/mcp.json", projectRootID: "b"),
            server(name: "filesystem", configFile: "/work/a/.cursor/mcp.json", projectRootID: "a"),
            server(name: "filesystem", configFile: "/Users/me/.cursor/mcp.json"),
        ]

        let first = McpScopeConflicts.detect(in: input)
        let second = McpScopeConflicts.detect(in: input.reversed())

        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(
            first.first?.project.configFile,
            "/work/a/.cursor/mcp.json",
            "the lowest config path should win the tie-break"
        )
        XCTAssertEqual(first, second, "direction of the input must not change the verdict")
    }

    func testConflictsAreSortedByName() {
        let conflicts = McpScopeConflicts.detect(in: [
            server(name: "zebra", configFile: "/Users/me/.cursor/mcp.json"),
            server(name: "zebra", configFile: "/work/app/.cursor/mcp.json", projectRootID: "app"),
            server(name: "alpha", configFile: "/Users/me/.cursor/mcp.json"),
            server(name: "alpha", configFile: "/work/app/.cursor/mcp.json", projectRootID: "app"),
        ])
        XCTAssertEqual(conflicts.map(\.name), ["alpha", "zebra"])
    }

    func testConflictingIDsCoverBothSides() {
        let global = server(name: "filesystem", configFile: "/Users/me/.cursor/mcp.json")
        let project = server(
            name: "filesystem",
            configFile: "/work/app/.cursor/mcp.json",
            projectRootID: "app"
        )
        let unrelated = server(name: "other", configFile: "/Users/me/.cursor/mcp.json")

        let ids = McpScopeConflicts.conflictingIDs(
            in: McpScopeConflicts.detect(in: [global, project, unrelated])
        )

        XCTAssertEqual(ids, [global.id, project.id])
        XCTAssertFalse(ids.contains(unrelated.id))
    }

    func testDeclarationsAreOrderedGlobalFirst() throws {
        let global = server(name: "filesystem", configFile: "/Users/me/.cursor/mcp.json")
        let project = server(
            name: "filesystem",
            configFile: "/work/app/.cursor/mcp.json",
            projectRootID: "app"
        )
        let conflict = try XCTUnwrap(McpScopeConflicts.detect(in: [project, global]).first)
        XCTAssertEqual(conflict.declarations.map(\.id), [global.id, project.id])
    }

    func testEmptyInputProducesNoConflicts() {
        XCTAssertTrue(McpScopeConflicts.detect(in: []).isEmpty)
        XCTAssertTrue(McpScopeConflicts.conflictingIDs(in: []).isEmpty)
    }

    // MARK: - Helpers

    private func server(
        name: String,
        configFile: String,
        projectRootID: String? = nil
    ) -> McpServerDescriptor {
        McpServerDescriptor(
            name: name,
            agentID: "cursor",
            transport: .stdio,
            command: "npx",
            arguments: ["-y", "some-server"],
            url: nil,
            configFile: configFile,
            projectRootID: projectRootID
        )
    }
}
