import Foundation
import XCTest
@testable import SkillSelectorCore

final class SkillQueryTests: XCTestCase {
    private let rootsByID: [String: AuthorizedRootSnapshot] = [
        "home-root": AuthorizedRootSnapshot(
            id: "home-root",
            url: URL(fileURLWithPath: "/Users/tester"),
            kind: .home
        ),
        "system-root": AuthorizedRootSnapshot(
            id: "system-root",
            url: URL(fileURLWithPath: "/Library/AgentSkills"),
            kind: .system
        ),
        "custom-root": AuthorizedRootSnapshot(
            id: "custom-root",
            url: URL(fileURLWithPath: "/Volumes/Skills"),
            kind: .custom
        ),
        "project-alpha": AuthorizedRootSnapshot(
            id: "project-alpha",
            url: URL(fileURLWithPath: "/Work/alpha"),
            kind: .project
        ),
        "project-beta": AuthorizedRootSnapshot(
            id: "project-beta",
            url: URL(fileURLWithPath: "/Work/beta"),
            kind: .project
        ),
    ]

    func testAllSkillsDeduplicatesByInstallationPath() {
        let shared = snapshot(
            path: "/Users/tester/.agents/skills/shared",
            name: "Shared",
            agentIDs: [],
            rootIDs: ["home-root"]
        )
        let snapshots = [
            snapshot(path: "/a/one", name: "One"),
            shared,
            shared,
            snapshot(path: "/z/three", name: "Three"),
        ]

        let result = SkillQuery().apply(to: snapshots, rootsByID: rootsByID)

        XCTAssertEqual(result.map(\.path), ["/a/one", shared.path, "/z/three"])
    }

    func testSharedSkillsAppearGloballyButNotUnderAgentFilters() {
        let shared = snapshot(
            path: "/Users/tester/.agents/skills/shared",
            name: "Shared",
            agentIDs: [],
            rootIDs: ["home-root"]
        )
        let snapshots = [
            shared,
            snapshot(path: "/codex/only", name: "Codex Only", agentIDs: ["codex"], rootIDs: ["home-root"]),
            snapshot(path: "/claude/only", name: "Claude Only", agentIDs: ["claude-code"], rootIDs: ["home-root"]),
        ]

        let global = SkillQuery(scope: .global)
            .apply(to: snapshots, rootsByID: rootsByID)
        let codex = SkillQuery(agentID: "codex")
            .apply(to: snapshots, rootsByID: rootsByID)
        let claude = SkillQuery(agentID: "claude-code")
            .apply(to: snapshots, rootsByID: rootsByID)

        XCTAssertEqual(Set(global.map(\.path)), [shared.path])
        XCTAssertEqual(codex.map(\.path), ["/codex/only"])
        XCTAssertEqual(claude.map(\.path), ["/claude/only"])
    }

    func testGlobalScopeUsesRootKindAndNotPathSubstring() {
        let misleadingProject = snapshot(
            path: "/Users/tester/project/.cursor/skills/demo",
            name: "Project",
            rootIDs: ["project-alpha"]
        )
        let global = [
            snapshot(path: "/opaque/home", name: "Home", agentIDs: [], rootIDs: ["home-root"]),
            snapshot(path: "/opaque/system", name: "System", agentIDs: [], rootIDs: ["system-root"]),
            snapshot(path: "/opaque/custom", name: "Custom", agentIDs: [], rootIDs: ["custom-root"]),
        ]

        let result = SkillQuery(scope: .global)
            .apply(to: global + [misleadingProject], rootsByID: rootsByID)

        XCTAssertEqual(Set(result.map(\.name)), ["Home", "System", "Custom"])
    }

    func testProjectScopeMatchesOpaqueRootIDAndSpanningSkillAppearsOnceInEachScope() {
        let spanning = snapshot(
            path: "/shared/spanning",
            name: "Spanning",
            agentIDs: [],
            rootIDs: ["home-root", "project-alpha"]
        )
        let snapshots = [
            spanning,
            snapshot(path: "/alpha/only", name: "Alpha", rootIDs: ["project-alpha"]),
            snapshot(path: "/beta/only", name: "Beta", rootIDs: ["project-beta"]),
        ]

        let global = SkillQuery(scope: .global)
            .apply(to: snapshots, rootsByID: rootsByID)
        let alpha = SkillQuery(scope: .project(rootID: "project-alpha"))
            .apply(to: snapshots, rootsByID: rootsByID)
        let beta = SkillQuery(scope: .project(rootID: "project-beta"))
            .apply(to: snapshots, rootsByID: rootsByID)

        XCTAssertEqual(global.map(\.path), [spanning.path])
        XCTAssertEqual(Set(alpha.map(\.path)), [spanning.path, "/alpha/only"])
        XCTAssertEqual(alpha.filter { $0.path == spanning.path }.count, 1)
        XCTAssertEqual(beta.map(\.path), ["/beta/only"])
    }

    /// Free terms fuzzy-match the Skill name only: case- and
    /// diacritic-insensitive substring. Descriptions and paths are no
    /// longer searched by plain terms.
    func testFreeTermsFuzzyMatchNameOnly() {
        let snapshots = [
            snapshot(path: "/name", name: "Release Helper"),
            snapshot(path: "/custom", name: "Custom", localDescription: "CUSTOM summary"),
            snapshot(path: "/local", name: "Local", localDescription: "Local Documentation"),
            snapshot(path: "/remote", name: "Remote"),
        ]

        // Substring match on the name, case-insensitive.
        XCTAssertEqual(
            SkillQuery(searchText: "rElEaSe")
                .apply(to: snapshots, rootsByID: rootsByID).map(\.path),
            ["/name"]
        )
        XCTAssertEqual(
            SkillQuery(searchText: "help")
                .apply(to: snapshots, rootsByID: rootsByID).map(\.path),
            ["/name"]
        )
        // A description-only term finds nothing as a free term…
        XCTAssertTrue(
            SkillQuery(searchText: "SUMMARY")
                .apply(to: snapshots, rootsByID: rootsByID).isEmpty
        )
        XCTAssertTrue(
            SkillQuery(searchText: "documentation")
                .apply(to: snapshots, rootsByID: rootsByID).isEmpty
        )
    }

    /// Free terms never search descriptions; the `desc:` prefix still does.
    func testDescriptionOnlyMatchedWithPrefix() {
        let skill = snapshot(
            path: "/priority",
            name: "Priority",
            localDescription: "Hidden local text"
        )

        XCTAssertTrue(
            SkillQuery(searchText: "hidden")
                .apply(to: [skill], rootsByID: rootsByID).isEmpty
        )
        XCTAssertEqual(
            SkillQuery(searchText: "desc:hidden")
                .apply(to: [skill], rootsByID: rootsByID).map(\.path),
            [skill.path]
        )
        XCTAssertTrue(
            SkillQuery(searchText: "chosen")
                .apply(to: [skill], rootsByID: rootsByID).isEmpty
        )
    }

    /// Free terms never search paths; the `path:` prefix still does.
    func testPathOnlyMatchedWithPrefix() {
        let snapshots = [
            snapshot(path: "/Users/tester/.codex/skills/release", name: "Unrelated Name"),
            snapshot(path: "/plain/folder", name: "codex elsewhere"),
        ]

        XCTAssertTrue(
            SkillQuery(searchText: ".codex/skills")
                .apply(to: snapshots, rootsByID: rootsByID).isEmpty
        )
        XCTAssertEqual(
            SkillQuery(searchText: "path:.codex/skills")
                .apply(to: snapshots, rootsByID: rootsByID).map(\.path),
            ["/Users/tester/.codex/skills/release"]
        )
    }

    func testFieldPrefixesRestrictSearchToASingleField() {
        let snapshots = [
            snapshot(path: "/one", name: "Deploy", localDescription: "ships releases"),
            snapshot(path: "/two", name: "Other", localDescription: "Deploy tool"),
        ]
        let namesByID = ["cursor": "Cursor"]

        XCTAssertEqual(
            SkillQuery(searchText: "name:deploy")
                .apply(to: snapshots, rootsByID: rootsByID).map(\.path),
            ["/one"]
        )
        XCTAssertEqual(
            SkillQuery(searchText: "desc:ships")
                .apply(to: snapshots, rootsByID: rootsByID).map(\.path),
            ["/one"]
        )
        XCTAssertEqual(
            SkillQuery(searchText: "path:/two")
                .apply(to: snapshots, rootsByID: rootsByID).map(\.path),
            ["/two"]
        )
        XCTAssertEqual(
            SkillQuery(searchText: "agent:cursor")
                .apply(to: snapshots, rootsByID: rootsByID, agentNamesByID: namesByID).count,
            2
        )
        // Agent terms fall back to the raw ID when no display name exists.
        XCTAssertEqual(
            SkillQuery(searchText: "agent:cursor")
                .apply(to: snapshots, rootsByID: rootsByID).count,
            2
        )
        // An unrecognized prefix stays a literal free term — searching what
        // was typed rather than silently reinterpreting it.
        XCTAssertTrue(
            SkillQuery(searchText: "label:deploy")
                .apply(to: snapshots, rootsByID: rootsByID).isEmpty
        )
    }

    func testSearchTermsCombineWithAnd() {
        let snapshots = [
            snapshot(path: "/one", name: "Deploy Helper", localDescription: "ships things"),
            snapshot(path: "/two", name: "Deploy Other", localDescription: "unrelated"),
            snapshot(path: "/three", name: "Helper", localDescription: "for codex"),
        ]

        XCTAssertEqual(
            SkillQuery(searchText: "deploy helper")
                .apply(to: snapshots, rootsByID: rootsByID).map(\.path),
            ["/one"]
        )
        XCTAssertEqual(
            SkillQuery(searchText: "name:helper desc:codex")
                .apply(to: snapshots, rootsByID: rootsByID).map(\.path),
            ["/three"]
        )
    }

    func testProjectScopeFiltersToOwnSkillsOnly() {
        let snapshots = [
            snapshot(path: "/alpha/skill-a", name: "Skill A", rootIDs: ["project-alpha"]),
            snapshot(path: "/alpha/skill-b", name: "Skill B", rootIDs: ["project-alpha"]),
            snapshot(path: "/beta/skill-c", name: "Skill C", rootIDs: ["project-beta"]),
            snapshot(path: "/home/shared", name: "Shared", agentIDs: [], rootIDs: ["home-root"]),
        ]

        let alpha = SkillQuery(scope: .project(rootID: "project-alpha"))
            .apply(to: snapshots, rootsByID: rootsByID)
        let beta = SkillQuery(scope: .project(rootID: "project-beta"))
            .apply(to: snapshots, rootsByID: rootsByID)

        XCTAssertEqual(alpha.map(\.name).sorted(), ["Skill A", "Skill B"])
        XCTAssertEqual(beta.map(\.name), ["Skill C"])
    }

    func testProjectDisplayNameShowsFolderName() {
        let root = AuthorizedRootSnapshot(
            id: "proj-1",
            url: URL(fileURLWithPath: "/Work/my-project"),
            kind: .project
        )
        XCTAssertEqual(root.displayName, "my-project")
    }

    func testProjectDisplayNameRespectsCustomName() {
        var root = AuthorizedRootSnapshot(
            id: "proj-1",
            url: URL(fileURLWithPath: "/Work/my-project"),
            kind: .project
        )
        root.customName = "My Project"
        XCTAssertEqual(root.displayName, "My Project")
    }

    func testSortModesUsePathAscendingAsFinalTieBreaker() {
        let snapshots = [
            snapshot(path: "/z/alpha", name: "Alpha"),
            snapshot(path: "/b/same", name: "Same"),
            snapshot(path: "/a/same", name: "same"),
            snapshot(path: "/c/beta", name: "Beta"),
        ]

        let nameSorted = SkillQuery(sort: .name)
            .apply(to: snapshots, rootsByID: rootsByID)
        let pathSorted = SkillQuery(sort: .path)
            .apply(to: snapshots, rootsByID: rootsByID)
        let defaultSorted = SkillQuery(sort: .default)
            .apply(to: snapshots, rootsByID: rootsByID)

        XCTAssertEqual(nameSorted.map(\.path), ["/z/alpha", "/c/beta", "/a/same", "/b/same"])
        XCTAssertEqual(pathSorted.map(\.path), ["/a/same", "/b/same", "/c/beta", "/z/alpha"])
        XCTAssertEqual(defaultSorted.map(\.path), nameSorted.map(\.path))
    }

    private func snapshot(
        path: String,
        name: String,
        localDescription: String? = nil,
        agentIDs: [String] = ["cursor"],
        rootIDs: [String] = ["home-root"]
    ) -> SkillSnapshot {
        SkillSnapshot(
            path: path,
            resolvedTarget: nil,
            name: name,
            localDescription: localDescription,
            modificationDate: nil,
            agentIDs: agentIDs,
            rootIDs: rootIDs,
            entryFilename: "SKILL.md",
            parseDiagnostics: []
        )
    }
}
