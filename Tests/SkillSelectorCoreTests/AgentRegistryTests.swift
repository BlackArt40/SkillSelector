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

    func testBuiltInRegistrySeparatesOwnedAndSharedDeclarations() throws {
        let expectedOwned: [String: (Set<String>, Set<String>)] = [
            "claude-code": (["~/.claude/skills"], [".claude/skills"]),
            "codex": (["~/.codex/skills"], [".codex/skills"]),
            "qoder": (["~/.qoder/skills"], [".qoder/skills"]),
            "codebuddy": (["~/.codebuddy/skills"], [".codebuddy/skills"]),
            "opencode": (["~/.config/opencode/skills", "~/.opencode/skills"], [".opencode/skills"]),
            "cursor": (["~/.cursor/skills"], [".cursor/skills"]),
            "kilo-code": (["~/.kilo/skills"], [".kilo/skills"]),
            "cline": (["~/.cline/skills"], [".cline/skills", ".clinerules/skills"]),
            "roo-code": (["~/.roo/skills", "~/.roo/skills-{modeSlug}"], [".roo/skills", ".roo/skills-{modeSlug}"]),
            "windsurf": (["~/.codeium/windsurf/skills", "/Library/Application Support/Windsurf/skills"], [".windsurf/skills"]),
            "gemini-cli": (["~/.gemini/skills"], [".gemini/skills"]),
            "github-copilot": (["~/.copilot/skills"], [".github/skills"]),
        ]
        let registry = BuiltInAgentRegistry.make()
        let definitions = Dictionary(uniqueKeysWithValues: registry.definitions.map { ($0.id, $0) })

        XCTAssertEqual(Set(definitions.keys), Set(expectedOwned.keys))
        for (id, expected) in expectedOwned {
            let definition = try XCTUnwrap(definitions[id])
            XCTAssertEqual(Set(definition.globalRoots), expected.0, id)
            XCTAssertEqual(Set(definition.projectPatterns), expected.1, id)
        }
        XCTAssertEqual(
            Set(registry.globalDeclarations.filter { $0.agentID == nil }.map(\.value)),
            ["~/.agents/skills", "~/.agents/skills-{modeSlug}"]
        )
        XCTAssertEqual(
            Set(registry.projectDeclarations.filter { $0.agentID == nil }.map(\.value)),
            [".agents/skills", ".agents/skills-{modeSlug}"]
        )
    }

    func testRooCodeIsMarkedLegacy() throws {
        let definition = try XCTUnwrap(BuiltInAgentRegistry.make().definition(id: "roo-code"))
        XCTAssertTrue(definition.isLegacy)
    }

    func testRegistryDoesNotAssignAnOwnerToSharedGlobalRoot() {
        let matches = Set(BuiltInAgentRegistry.make().matchingGlobalRoot("~/.agents/skills").map(\.id))

        XCTAssertTrue(matches.isEmpty)
    }

    func testBundledDeclarationsWinOverCustomOverlap() {
        let base = AgentDefinition(
            id: "codex",
            displayName: "Codex",
            globalRoots: ["~/.codex/skills"],
            projectPatterns: [".codex/skills"]
        )
        let custom = AgentDefinition.custom(
            displayName: "Overlap",
            globalRoots: ["~/.codex/skills", "~/.agents/skills", "~/.mine/skills"],
            projectPatterns: [".codex/skills", ".agents/skills", ".mine/skills"]
        )
        let registry = AgentRegistry(
            definitions: [base],
            customDefinitions: [custom],
            sharedGlobalRoots: ["~/.agents/skills"],
            sharedProjectPatterns: [".agents/skills"]
        )

        XCTAssertEqual(registry.globalDeclarations.first { $0.value == "~/.codex/skills" }?.agentID, "codex")
        XCTAssertNil(registry.globalDeclarations.first { $0.value == "~/.agents/skills" }?.agentID)
        XCTAssertEqual(registry.globalDeclarations.first { $0.value == "~/.mine/skills" }?.agentID, custom.id)
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

    func testCustomAgentStoreRoundTripsAndRemovesDefinitions() throws {
        let suite = "AgentDefinitionStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsAgentDefinitionStore(defaults: defaults, key: "agents")
        let definition = AgentDefinition(
            id: "custom-local-agent",
            displayName: "Local Agent",
            globalRoots: ["~/.local-agent/skills"],
            projectPatterns: [".local-agent/skills"]
        )

        try store.save(definition)
        XCTAssertEqual(try store.definitions(), [definition])

        try store.remove(id: definition.id)
        XCTAssertTrue(try store.definitions().isEmpty)
    }

    func testCustomAgentsUsePersistentUUIDIdentifiersAndRejectLegacyInsertionCollisions() throws {
        let first = AgentDefinition.custom(
            displayName: "A B",
            globalRoots: [],
            projectPatterns: []
        )
        let second = AgentDefinition.custom(
            displayName: "A-B",
            globalRoots: [],
            projectPatterns: []
        )
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertNotNil(UUID(uuidString: String(first.id.dropFirst("custom-".count))))
        XCTAssertNotNil(UUID(uuidString: String(second.id.dropFirst("custom-".count))))

        let suite = "AgentDefinitionStoreCollisionTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsAgentDefinitionStore(defaults: defaults, key: "agents")
        let legacy = AgentDefinition(
            id: "custom-a-b",
            displayName: "A B",
            globalRoots: [],
            projectPatterns: []
        )
        try store.insert(legacy)
        XCTAssertThrowsError(try store.insert(AgentDefinition(
            id: legacy.id,
            displayName: "A-B",
            globalRoots: [],
            projectPatterns: []
        ))) { error in
            XCTAssertEqual(error as? AgentDefinitionStoreError, .duplicateIdentifier(legacy.id))
        }

        var edited = legacy
        edited.displayName = "Renamed"
        try store.save(edited)
        XCTAssertEqual(try store.definitions().map(\.id), [legacy.id])
        XCTAssertEqual(try store.definitions().first?.displayName, "Renamed")
    }

}
