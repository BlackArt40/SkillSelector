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

        XCTAssertEqual(Set(global.map(\.path)), [shared.path, "/codex/only", "/claude/only"])
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
            snapshot(path: "/opaque/home", name: "Home", rootIDs: ["home-root"]),
            snapshot(path: "/opaque/system", name: "System", rootIDs: ["system-root"]),
            snapshot(path: "/opaque/custom", name: "Custom", rootIDs: ["custom-root"]),
        ]

        let result = SkillQuery(scope: .global)
            .apply(to: global + [misleadingProject], rootsByID: rootsByID)

        XCTAssertEqual(Set(result.map(\.name)), ["Home", "System", "Custom"])
    }

    func testProjectScopeMatchesOpaqueRootIDAndSpanningSkillAppearsOnceInEachScope() {
        let spanning = snapshot(
            path: "/shared/spanning",
            name: "Spanning",
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

    func testStatusFiltersAvailableAndUnavailableSkills() {
        let available = snapshot(path: "/available", name: "Available")
        let unavailable = snapshot(
            path: "/unavailable",
            name: "Unavailable",
            availability: .unavailable,
            unavailableReason: "Permission denied"
        )

        XCTAssertEqual(
            SkillQuery(status: .available)
                .apply(to: [unavailable, available], rootsByID: rootsByID)
                .map(\.path),
            [available.path]
        )
        XCTAssertEqual(
            SkillQuery(status: .unavailable)
                .apply(to: [unavailable, available], rootsByID: rootsByID)
                .map(\.path),
            [unavailable.path]
        )
    }

    func testSearchIsCaseInsensitiveAcrossNameAndEffectiveDescription() {
        let snapshots = [
            snapshot(path: "/name", name: "Release Helper"),
            snapshot(path: "/custom", name: "Custom", customDescription: "CUSTOM summary"),
            snapshot(path: "/local", name: "Local", localDescription: "Local Documentation"),
            snapshot(path: "/remote", name: "Remote", enrichedDescription: "Remote Metadata"),
        ]

        XCTAssertEqual(
            SkillQuery(searchText: "rElEaSe")
                .apply(to: snapshots, rootsByID: rootsByID).map(\.path),
            ["/name"]
        )
        XCTAssertEqual(
            SkillQuery(searchText: "SUMMARY")
                .apply(to: snapshots, rootsByID: rootsByID).map(\.path),
            ["/custom"]
        )
        XCTAssertEqual(
            SkillQuery(searchText: "documentation")
                .apply(to: snapshots, rootsByID: rootsByID).map(\.path),
            ["/local"]
        )
        XCTAssertEqual(
            SkillQuery(searchText: "metadata")
                .apply(to: snapshots, rootsByID: rootsByID).map(\.path),
            ["/remote"]
        )
    }

    func testEffectiveDescriptionSearchHonorsPriority() {
        let skill = snapshot(
            path: "/priority",
            name: "Priority",
            customDescription: "Chosen text",
            localDescription: "Hidden local text",
            enrichedDescription: "Hidden remote text"
        )

        XCTAssertEqual(
            SkillQuery(searchText: "chosen")
                .apply(to: [skill], rootsByID: rootsByID).map(\.path),
            [skill.path]
        )
        XCTAssertTrue(
            SkillQuery(searchText: "hidden")
                .apply(to: [skill], rootsByID: rootsByID).isEmpty
        )
    }

    func testSortModesUsePathAscendingAsFinalTieBreaker() {
        let snapshots = [
            snapshot(path: "/z/alpha", name: "Alpha", availability: .unavailable),
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
        XCTAssertEqual(defaultSorted.map(\.path), ["/c/beta", "/a/same", "/b/same", "/z/alpha"])
    }

    private func snapshot(
        path: String,
        name: String,
        customDescription: String? = nil,
        localDescription: String? = nil,
        enrichedDescription: String? = nil,
        agentIDs: [String] = ["cursor"],
        rootIDs: [String] = ["home-root"],
        availability: SkillAvailability = .available,
        unavailableReason: String? = nil
    ) -> SkillSnapshot {
        SkillSnapshot(
            path: path,
            resolvedTarget: nil,
            name: name,
            localDescription: localDescription,
            enrichedDescription: enrichedDescription,
            enrichedDescriptionProvenance: nil,
            customDescription: customDescription,
            digest: nil,
            modificationDate: nil,
            availability: availability,
            unavailableReason: unavailableReason,
            sourceBinding: nil,
            agentIDs: agentIDs,
            rootIDs: rootIDs,
            entryFilename: "SKILL.md",
            parseDiagnostics: []
        )
    }
}
