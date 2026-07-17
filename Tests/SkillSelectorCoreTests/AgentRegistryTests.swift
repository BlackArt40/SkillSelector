import Foundation
import XCTest
@testable import SkillSelectorCore

final class AgentRegistryTests: XCTestCase {
    func testBuiltInRegistryContainsConfirmedAgents() {
        let ids = Set(BuiltInAgentRegistry.make().definitions.map(\.id))
        XCTAssertEqual(ids, Set([
            "claude-code", "codex", "qoder", "codebuddy", "opencode",
            "cursor", "kilo-code", "cline", "roo-code", "windsurf",
            "gemini-cli", "github-copilot",
        ]))
    }

    func testOnePathCanAccumulateAgentAssociations() {
        var skill = SkillInstallation(path: URL(fileURLWithPath: "/tmp/shared/demo"))
        skill.agentIDs.formUnion(["cursor", "gemini-cli"])
        XCTAssertEqual(skill.agentIDs.count, 2)
        XCTAssertEqual(skill.id, "/tmp/shared/demo")
    }

    func testInstallationIdentityUsesStandardizedPathInsteadOfResolvedTarget() {
        let skill = SkillInstallation(
            path: URL(fileURLWithPath: "/tmp/shared/../shared/demo"),
            resolvedTarget: URL(fileURLWithPath: "/tmp/target/demo")
        )

        XCTAssertEqual(skill.id, "/tmp/shared/demo")
        XCTAssertEqual(skill.path.path, "/tmp/shared/demo")
        XCTAssertEqual(skill.resolvedTarget?.path, "/tmp/target/demo")
    }

    func testInstallationsWithTheSameNormalizedPathHaveTheSameHashableIdentity() {
        let first = SkillInstallation(
            path: URL(fileURLWithPath: "/tmp/shared/../shared/demo"),
            resolvedTarget: URL(fileURLWithPath: "/tmp/first-target"),
            agentIDs: ["cursor"]
        )
        let second = SkillInstallation(
            path: URL(fileURLWithPath: "/tmp/shared/demo"),
            resolvedTarget: URL(fileURLWithPath: "/tmp/second-target"),
            agentIDs: ["gemini-cli"]
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(Set([first, second]).count, 1)
    }

    func testBuiltInDefinitionsContainEveryConfirmedPath() throws {
        let expectedPaths: [String: (globalRoots: Set<String>, projectPatterns: Set<String>)] = [
            "claude-code": (["~/.claude/skills"], [".claude/skills"]),
            "codex": (["~/.codex/skills"], [".codex/skills", ".agents/skills"]),
            "qoder": (["~/.qoder/skills"], [".qoder/skills"]),
            "codebuddy": (["~/.codebuddy/skills"], [".codebuddy/skills"]),
            "opencode": (["~/.config/opencode/skills", "~/.opencode/skills"], [".opencode/skills", ".agents/skills"]),
            "cursor": (["~/.cursor/skills", "~/.agents/skills", "~/.claude/skills", "~/.codex/skills"], [".cursor/skills", ".agents/skills", ".claude/skills", ".codex/skills"]),
            "kilo-code": (["~/.kilo/skills"], [".kilo/skills", ".agents/skills"]),
            "cline": (["~/.cline/skills", "~/.agents/skills"], [".cline/skills", ".clinerules/skills", ".claude/skills", ".agents/skills"]),
            "roo-code": (["~/.roo/skills", "~/.agents/skills", "~/.roo/skills-{modeSlug}", "~/.agents/skills-{modeSlug}"], [".roo/skills", ".agents/skills", ".roo/skills-{modeSlug}", ".agents/skills-{modeSlug}"]),
            "windsurf": (["~/.codeium/windsurf/skills", "~/.agents/skills", "~/.claude/skills", "/Library/Application Support/Windsurf/skills"], [".windsurf/skills", ".agents/skills", ".claude/skills"]),
            "gemini-cli": (["~/.gemini/skills", "~/.agents/skills"], [".gemini/skills", ".agents/skills"]),
            "github-copilot": (["~/.copilot/skills", "~/.claude/skills", "~/.agents/skills"], [".github/skills", ".claude/skills", ".agents/skills"]),
        ]

        let definitions = Dictionary(
            uniqueKeysWithValues: BuiltInAgentRegistry.make().definitions.map { ($0.id, $0) }
        )

        XCTAssertEqual(Set(definitions.keys), Set(expectedPaths.keys))
        for (id, expected) in expectedPaths {
            let definition = try XCTUnwrap(definitions[id])
            XCTAssertEqual(Set(definition.globalRoots), expected.globalRoots, id)
            XCTAssertEqual(Set(definition.projectPatterns), expected.projectPatterns, id)
            XCTAssertEqual(definition.entryFilename, "SKILL.md", id)
        }
    }

    func testRooCodeIsMarkedLegacy() throws {
        let definition = try XCTUnwrap(BuiltInAgentRegistry.make().definition(id: "roo-code"))
        XCTAssertTrue(definition.isLegacy)
    }

    func testRegistryFindsAllDefinitionsForSharedGlobalRoot() {
        let matches = Set(BuiltInAgentRegistry.make().matchingGlobalRoot("~/.agents/skills").map(\.id))

        XCTAssertEqual(matches, ["cursor", "cline", "roo-code", "windsurf", "gemini-cli", "github-copilot"])
    }

    func testCustomDefinitionsReplaceSameIdentifierAndAppendNewDefinitions() throws {
        let customCodex = AgentDefinition(
            id: "codex",
            displayName: "Custom Codex",
            globalRoots: ["~/custom/codex/skills"],
            projectPatterns: [".custom-codex/skills"]
        )
        let customAgent = AgentDefinition(
            id: "local-agent",
            displayName: "Local Agent",
            globalRoots: ["~/local-agent/skills"],
            projectPatterns: [".local-agent/skills"]
        )

        let registry = AgentRegistry(
            definitions: BuiltInAgentRegistry.make().definitions,
            customDefinitions: [customCodex, customAgent]
        )

        XCTAssertEqual(registry.definitions.count, 13)
        XCTAssertEqual(try XCTUnwrap(registry.definition(id: "codex")).displayName, "Custom Codex")
        XCTAssertEqual(try XCTUnwrap(registry.definition(id: "local-agent")).displayName, "Local Agent")
    }
}
