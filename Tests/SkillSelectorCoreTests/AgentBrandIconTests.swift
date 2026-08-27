import AppKit
import SkillSelectorCore
import XCTest
@testable import SkillSelector

@MainActor
final class AgentBrandIconTests: XCTestCase {
    /// The branded agents advertised in the sidebar must ship a valid
    /// template image — a missing or broken file silently falls back to the
    /// monogram, which regresses the feature without failing loudly.
    func testCoreAgentsHaveValidIcons() {
        for id in [
            "claude-code", "codex", "cursor", "windsurf",
            "gemini-cli", "github-copilot", "opencode", "cline",
        ] {
            XCTAssertTrue(AgentBrandIcon.hasIcon(for: id), "missing or broken icon for \(id)")
        }
    }

    /// Agent ids without a bundled mark report no icon, and the fallback
    /// monogram path stays intact.
    func testMissingIconFallsBackGracefully() {
        XCTAssertFalse(AgentBrandIcon.hasIcon(for: "no-such-agent"))
        XCTAssertEqual(AgentMonoView.monogram(for: "Claude Code"), "CC")
    }

    /// Every built-in agent either ships a brand mark or falls back — the
    /// sidebar row must never be left blank.
    func testEveryBuiltInAgentHasIconOrMonogram() {
        let agents = BuiltInAgentRegistry.make().definitions
        XCTAssertFalse(agents.isEmpty)
        for agent in agents {
            let monogram = AgentMonoView.monogram(for: agent.displayName)
            XCTAssertFalse(monogram.isEmpty, "empty monogram for \(agent.id)")
            // Agents without a bundled mark use the monogram by design;
            // this test only guarantees the fallback text is non-empty.
        }
    }
}