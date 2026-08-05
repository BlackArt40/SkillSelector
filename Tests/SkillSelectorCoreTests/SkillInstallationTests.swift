import Foundation
import XCTest
@testable import SkillSelectorCore

final class SkillInstallationTests: XCTestCase {
    func testIdentityIsBasedOnNormalizedPath() {
        let plain = SkillInstallation(path: URL(fileURLWithPath: "/tmp/skills/demo"))
        let unnormalized = SkillInstallation(path: URL(fileURLWithPath: "/tmp/skills/../skills/demo"))

        XCTAssertEqual(plain.id, "/tmp/skills/demo")
        XCTAssertEqual(plain.path.path, "/tmp/skills/demo")
        XCTAssertEqual(plain, unnormalized)
        XCTAssertEqual(plain.hashValue, unnormalized.hashValue)
    }

    func testEqualityIgnoresResolvedTargetAndAgentIDs() {
        let base = SkillInstallation(path: URL(fileURLWithPath: "/tmp/skills/demo"))
        let enriched = SkillInstallation(
            path: URL(fileURLWithPath: "/tmp/skills/demo"),
            resolvedTarget: URL(fileURLWithPath: "/elsewhere/target"),
            agentIDs: ["codex", "claude-code"]
        )

        XCTAssertEqual(base, enriched)
    }

    func testDistinctPathsAreNotEqual() {
        let first = SkillInstallation(path: URL(fileURLWithPath: "/tmp/skills/one"))
        let second = SkillInstallation(path: URL(fileURLWithPath: "/tmp/skills/two"))

        XCTAssertNotEqual(first, second)
    }

    func testCopiesAtDifferentPathsRemainIndependentInstallations() {
        var installations = Set<SkillInstallation>()
        installations.insert(SkillInstallation(
            path: URL(fileURLWithPath: "/agent-a/skills/demo"),
            agentIDs: ["agent-a"]
        ))
        installations.insert(SkillInstallation(
            path: URL(fileURLWithPath: "/agent-b/skills/demo"),
            agentIDs: ["agent-b"]
        ))

        XCTAssertEqual(installations.count, 2)
    }

    func testDefaultsCarryNoTargetOrAgents() {
        let installation = SkillInstallation(path: URL(fileURLWithPath: "/tmp/skills/demo"))

        XCTAssertNil(installation.resolvedTarget)
        XCTAssertTrue(installation.agentIDs.isEmpty)
    }
}
