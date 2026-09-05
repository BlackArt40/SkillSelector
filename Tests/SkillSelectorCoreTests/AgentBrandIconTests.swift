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

    /// Direct `Bundle.module` use is forbidden in app sources: the SwiftPM
    /// accessor resolves against the .app root and the build machine's
    /// absolute path, so it works for tests and `swift run` but fatals in a
    /// packaged install (the macOS 12 real-device smoke caught a SIGILL in
    /// AgentIconView from exactly this). App code resolves resources through
    /// `Bundle.appResources` / L10n's lookup, whose only `Bundle.module`
    /// fallbacks live in the two files below.
    func testNoDirectBundleModuleUseInAppSources() throws {
        let sanctionedFiles: Set<String> = ["L10n.swift", "BrandViews.swift"]
        let sourcesRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources", isDirectory: true)
            .appendingPathComponent("SkillSelector", isDirectory: true)

        guard let enumerator = FileManager.default.enumerator(
            at: sourcesRoot, includingPropertiesForKeys: nil
        ) else {
            XCTFail("cannot enumerate \(sourcesRoot.path)")
            return
        }

        var offenders: [String] = []
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
            guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            if text.contains("Bundle.module"), !sanctionedFiles.contains(fileURL.lastPathComponent) {
                offenders.append(fileURL.lastPathComponent)
            }
        }
        XCTAssertEqual(offenders, [], "direct Bundle.module use must go through Bundle.appResources/L10n")
    }
}