import Foundation
import XCTest
@testable import SkillSelectorCore

final class BuiltInAgentRegistryTests: XCTestCase {
    private let registry = BuiltInAgentRegistry.make()

    func testContainsExpectedBuiltInAgents() {
        XCTAssertEqual(
            Set(registry.definitions.map(\.id)),
            [
                "claude-code", "codex", "qoder", "codebuddy", "opencode",
                "cursor", "kilo-code", "cline", "roo-code", "windsurf",
                "gemini-cli", "github-copilot",
            ]
        )
    }

    func testIdentifiersAreUnique() {
        let ids = registry.definitions.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testEveryDefinitionHasDisplayNameAndRoots() {
        for definition in registry.definitions {
            XCTAssertFalse(definition.displayName.isEmpty, definition.id)
            XCTAssertFalse(definition.globalRoots.isEmpty, definition.id)
            XCTAssertFalse(definition.projectPatterns.isEmpty, definition.id)
        }
    }

    func testOnlyRooCodeIsMarkedLegacy() {
        XCTAssertEqual(
            registry.definitions.filter(\.isLegacy).map(\.id),
            ["roo-code"]
        )
    }

    func testSharedRootsCoverAgentsDirectory() {
        XCTAssertEqual(
            registry.sharedGlobalRoots,
            ["~/.agents/skills", "~/.agents/skills-{modeSlug}"]
        )
        XCTAssertEqual(
            registry.sharedProjectPatterns,
            [".agents/skills", ".agents/skills-{modeSlug}"]
        )
    }

    func testSharedRootsAreNotAttributedToAnyAgent() {
        for declaration in registry.globalDeclarations
        where declaration.value.hasPrefix("~/.agents/") {
            XCTAssertNil(declaration.agentID)
        }
        for declaration in registry.projectDeclarations
        where declaration.value.hasPrefix(".agents/") {
            XCTAssertNil(declaration.agentID)
        }
    }

    func testAgentAttributedDeclarationsCarryAgentID() {
        let codexDeclarations = registry.globalDeclarations.filter {
            $0.value == "~/.codex/skills"
        }
        XCTAssertEqual(codexDeclarations.map(\.agentID), ["codex"])
    }

    func testDefinitionLookupFindsBuiltInAgent() {
        XCTAssertEqual(registry.definition(id: "claude-code")?.displayName, "Claude Code")
        XCTAssertNil(registry.definition(id: "not-an-agent"))
    }

    func testDeclarationsUseDefaultEntryFilename() {
        for declaration in registry.globalDeclarations + registry.projectDeclarations {
            XCTAssertEqual(declaration.entryFilename, "SKILL.md")
        }
    }
}
