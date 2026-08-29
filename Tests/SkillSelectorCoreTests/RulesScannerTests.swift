import Foundation
import XCTest
@testable import SkillSelectorCore

final class RulesScannerTests: XCTestCase {
    private func makeDirectory(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func testFindsGlobalAndProjectRulesFiles() throws {
        let home = try makeDirectory("RulesHome")
        let project = try makeDirectory("RulesProject")
        try write("# Claude\n", to: home.appending(path: ".claude/CLAUDE.md"))
        try write("# Codex\n", to: home.appending(path: ".codex/AGENTS.md"))
        try write("# Project Claude\n", to: project.appending(path: "CLAUDE.md"))
        try write("# Project Agents\n", to: project.appending(path: "AGENTS.md"))
        try write("# Cursor\n", to: project.appending(path: ".cursorrules"))

        let files = RulesScanner().scan(
            homeRoot: AuthorizedRootSnapshot(id: "home", url: home, kind: .home),
            projectRoots: [
                AuthorizedRootSnapshot(id: "proj", url: project, kind: .project),
            ]
        )

        XCTAssertEqual(files.count, 5)
        XCTAssertEqual(Set(files.map(\.filename)), ["CLAUDE.md", "AGENTS.md", ".cursorrules"])

        // Global files carry no project root and the declaring agent.
        let claudeGlobal = files.first { $0.path == home.appending(path: ".claude/CLAUDE.md").path }
        XCTAssertEqual(claudeGlobal?.agentID, "claude-code")
        XCTAssertNil(claudeGlobal?.projectRootID)

        // Project files carry the project root id; CLAUDE.md resolves to the
        // first declaring agent (Claude Code) after path dedup.
        let claudeProject = files.first { $0.path == project.appending(path: "CLAUDE.md").path }
        XCTAssertEqual(claudeProject?.agentID, "claude-code")
        XCTAssertEqual(claudeProject?.projectRootID, "proj")
        XCTAssertEqual(
            files.first { $0.path == project.appending(path: ".cursorrules").path }?.agentID,
            "cursor"
        )
        // Sizes are captured for display.
        XCTAssertEqual(claudeProject?.fileSize, "# Project Claude\n".utf8.count)
        XCTAssertNotNil(claudeProject?.modificationDate)
    }

    func testMissingFilesAreSkipped() {
        let home = try? makeDirectory("RulesHomeEmpty")
        let project = try? makeDirectory("RulesProjectEmpty")
        let files = RulesScanner().scan(
            homeRoot: home.map { AuthorizedRootSnapshot(id: "home", url: $0, kind: .home) },
            projectRoots: project.map {
                [AuthorizedRootSnapshot(id: "proj", url: $0, kind: .project)]
            } ?? []
        )
        XCTAssertTrue(files.isEmpty)
    }

    func testWithoutHomeRootOnlyProjectFilesAreFound() throws {
        let project = try makeDirectory("RulesProjectOnly")
        try write("# Project\n", to: project.appending(path: "CLAUDE.md"))
        let files = RulesScanner().scan(homeRoot: nil, projectRoots: [
            AuthorizedRootSnapshot(id: "proj", url: project, kind: .project),
        ])
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files.first?.filename, "CLAUDE.md")
    }

    func testDirectoriesNamedLikeRulesAreIgnored() throws {
        let project = try makeDirectory("RulesProjectDir")
        try FileManager.default.createDirectory(
            at: project.appending(path: "CLAUDE.md"),
            withIntermediateDirectories: true
        )
        let files = RulesScanner().scan(homeRoot: nil, projectRoots: [
            AuthorizedRootSnapshot(id: "proj", url: project, kind: .project),
        ])
        XCTAssertTrue(files.isEmpty, "a directory named CLAUDE.md is not a rules file")
    }

    func testOversizedRulesFilesAreSkipped() throws {
        let project = try makeDirectory("RulesProjectBig")
        let huge = Data(repeating: 0x41, count: RulesScanner.maximumRulesFileBytes + 1)
        try huge.write(to: project.appending(path: "CLAUDE.md"))
        let files = RulesScanner().scan(homeRoot: nil, projectRoots: [
            AuthorizedRootSnapshot(id: "proj", url: project, kind: .project),
        ])
        XCTAssertTrue(files.isEmpty, "an oversized rules file must be skipped, not read")
    }

    func testNestedProjectRulesAreFound() throws {
        let project = try makeDirectory("RulesProjectNested")
        try write("# Copilot\n", to: project.appending(path: ".github/copilot-instructions.md"))
        let files = RulesScanner().scan(homeRoot: nil, projectRoots: [
            AuthorizedRootSnapshot(id: "proj", url: project, kind: .project),
        ])
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files.first?.filename, "copilot-instructions.md")
        XCTAssertEqual(files.first?.agentID, "github-copilot")
    }

    // MARK: Directory sources (.cursor/rules, .claude/rules)

    func testCursorRulesDirectoryMdcFilesAreFound() throws {
        let project = try makeDirectory("RulesCursorDir")
        try write("# API\n", to: project.appending(path: ".cursor/rules/api.mdc"))
        try write("RULE.MDC upper\n", to: project.appending(path: ".cursor/rules/UPPER.MDC"))
        // Wrong extension, stray file type: not rules.
        try write("# Not rules\n", to: project.appending(path: ".cursor/rules/notes.md"))
        try write("text", to: project.appending(path: ".cursor/rules/data.txt"))
        // Nested files are out of scope: one level only.
        try write("# Nested\n", to: project.appending(path: ".cursor/rules/sub/inner.mdc"))

        let files = RulesScanner().scan(homeRoot: nil, projectRoots: [
            AuthorizedRootSnapshot(id: "proj", url: project, kind: .project),
        ])
        XCTAssertEqual(Set(files.map(\.path)), [
            project.appending(path: ".cursor/rules/api.mdc").path,
            project.appending(path: ".cursor/rules/UPPER.MDC").path,
        ])
        XCTAssertTrue(files.allSatisfy { $0.agentID == "cursor" && $0.projectRootID == "proj" })
    }

    func testClaudeRulesDirectoriesAreFoundInHomeAndProject() throws {
        let home = try makeDirectory("RulesClaudeHome")
        let project = try makeDirectory("RulesClaudeProject")
        try write("# Global style\n", to: home.appending(path: ".claude/rules/style.md"))
        try write("# Testing\n", to: project.appending(path: ".claude/rules/testing.md"))
        // .mdc belongs to Cursor's directory, not Claude's.
        try write("# Wrong kind\n", to: project.appending(path: ".claude/rules/nope.mdc"))

        let files = RulesScanner().scan(
            homeRoot: AuthorizedRootSnapshot(id: "home", url: home, kind: .home),
            projectRoots: [
                AuthorizedRootSnapshot(id: "proj", url: project, kind: .project),
            ]
        )
        XCTAssertEqual(Set(files.map(\.path)), [
            home.appending(path: ".claude/rules/style.md").path,
            project.appending(path: ".claude/rules/testing.md").path,
        ])
        XCTAssertTrue(files.allSatisfy { $0.agentID == "claude-code" })
        XCTAssertEqual(
            files.first { $0.path.contains(".claude/rules/style.md") }?.projectRootID,
            nil
        )
        XCTAssertEqual(
            files.first { $0.path.contains(".claude/rules/testing.md") }?.projectRootID,
            "proj"
        )
    }

    func testClaudeLocalMdIsFound() throws {
        let project = try makeDirectory("RulesClaudeLocal")
        try write("# Local\n", to: project.appending(path: "CLAUDE.local.md"))
        let files = RulesScanner().scan(homeRoot: nil, projectRoots: [
            AuthorizedRootSnapshot(id: "proj", url: project, kind: .project),
        ])
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files.first?.agentID, "claude-code")
        XCTAssertEqual(files.first?.filename, "CLAUDE.local.md")
    }

    func testOversizedFileInsideRulesDirectoryIsSkipped() throws {
        let project = try makeDirectory("RulesCursorBig")
        let rulesDir = project.appending(path: ".cursor/rules", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: rulesDir, withIntermediateDirectories: true)
        let huge = Data(repeating: 0x41, count: RulesScanner.maximumRulesFileBytes + 1)
        try huge.write(to: rulesDir.appending(path: "huge.mdc"))
        try write("# Fine\n", to: rulesDir.appending(path: "fine.mdc"))

        let files = RulesScanner().scan(homeRoot: nil, projectRoots: [
            AuthorizedRootSnapshot(id: "proj", url: project, kind: .project),
        ])
        XCTAssertEqual(files.map(\.filename), ["fine.mdc"])
    }

    func testMissingRulesDirectoryIsSkipped() throws {
        let project = try makeDirectory("RulesCursorMissing")
        try FileManager.default.createDirectory(
            at: project.appending(path: ".cursor"),
            withIntermediateDirectories: true
        )
        let files = RulesScanner().scan(homeRoot: nil, projectRoots: [
            AuthorizedRootSnapshot(id: "proj", url: project, kind: .project),
        ])
        XCTAssertTrue(files.isEmpty)
    }

    func testRooRulesDirectoryIsFound() throws {
        let home = try makeDirectory("RulesRooHome")
        let project = try makeDirectory("RulesRooProject")
        try write("# Global Roo\n", to: home.appending(path: ".roo/rules/global.md"))
        try write("# Project Roo\n", to: project.appending(path: ".roo/rules/api.md"))

        let files = RulesScanner().scan(
            homeRoot: AuthorizedRootSnapshot(id: "home", url: home, kind: .home),
            projectRoots: [
                AuthorizedRootSnapshot(id: "proj", url: project, kind: .project),
            ]
        )
        XCTAssertEqual(Set(files.map(\.path)), [
            home.appending(path: ".roo/rules/global.md").path,
            project.appending(path: ".roo/rules/api.md").path,
        ])
        XCTAssertTrue(files.allSatisfy { $0.agentID == "roo-code" })
    }

    func testKiloRulesDirectoryIsFound() throws {
        let project = try makeDirectory("RulesKilo")
        try write("# Kilo\n", to: project.appending(path: ".kilocode/rules/style.md"))
        let files = RulesScanner().scan(homeRoot: nil, projectRoots: [
            AuthorizedRootSnapshot(id: "proj", url: project, kind: .project),
        ])
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files.first?.agentID, "kilo-code")
        XCTAssertEqual(files.first?.filename, "style.md")
    }

    func testClineRulesDirectoryAndGlobalFolderAreFound() throws {
        let home = try makeDirectory("RulesClineHome")
        let project = try makeDirectory("RulesClineProject")
        try write("# Cline global\n", to: home.appending(path: "Documents/Cline/Rules/base.md"))
        try write("# Cline dir rule\n", to: project.appending(path: ".clinerules/api.md"))

        let files = RulesScanner().scan(
            homeRoot: AuthorizedRootSnapshot(id: "home", url: home, kind: .home),
            projectRoots: [
                AuthorizedRootSnapshot(id: "proj", url: project, kind: .project),
            ]
        )
        XCTAssertEqual(Set(files.map(\.path)), [
            home.appending(path: "Documents/Cline/Rules/base.md").path,
            project.appending(path: ".clinerules/api.md").path,
        ])
        XCTAssertTrue(files.allSatisfy { $0.agentID == "cline" })
    }

    func testWindsurfRulesDirectoryAndGlobalFileAreFound() throws {
        let home = try makeDirectory("RulesWindsurfHome")
        let project = try makeDirectory("RulesWindsurfProject")
        try write("# Cascade rules\n", to: project.appending(path: ".windsurf/rules/cascade.md"))
        try write(
            "# Global rules\n",
            to: home.appending(path: ".codeium/windsurf/memories/global_rules.md")
        )

        let files = RulesScanner().scan(
            homeRoot: AuthorizedRootSnapshot(id: "home", url: home, kind: .home),
            projectRoots: [
                AuthorizedRootSnapshot(id: "proj", url: project, kind: .project),
            ]
        )
        XCTAssertEqual(Set(files.map(\.path)), [
            project.appending(path: ".windsurf/rules/cascade.md").path,
            home.appending(path: ".codeium/windsurf/memories/global_rules.md").path,
        ])
        XCTAssertEqual(
            files.first { $0.projectRootID == nil }?.filename,
            "global_rules.md"
        )
        XCTAssertTrue(files.allSatisfy { $0.agentID == "windsurf" })
    }

    func testGeminiMdHierarchyIsFound() throws {
        let home = try makeDirectory("RulesGeminiHome")
        let project = try makeDirectory("RulesGeminiProject")
        try write("# Global Gemini\n", to: home.appending(path: ".gemini/GEMINI.md"))
        try write("# Project Gemini\n", to: project.appending(path: "GEMINI.md"))

        let files = RulesScanner().scan(
            homeRoot: AuthorizedRootSnapshot(id: "home", url: home, kind: .home),
            projectRoots: [
                AuthorizedRootSnapshot(id: "proj", url: project, kind: .project),
            ]
        )
        XCTAssertEqual(Set(files.map(\.path)), [
            home.appending(path: ".gemini/GEMINI.md").path,
            project.appending(path: "GEMINI.md").path,
        ])
        XCTAssertTrue(files.allSatisfy { $0.agentID == "gemini-cli" })
    }

    func testCopilotInstructionsDirectoryMatchesFilenameSuffix() throws {
        let project = try makeDirectory("RulesCopilotInstructions")
        try write(
            "---\napplyTo: \"**/*.py\"\n---\n# Python\n",
            to: project.appending(path: ".github/instructions/python.instructions.md")
        )
        // A plain .md file is not an instructions file, and the suffix must
        // not match without a dot boundary ("myinstructions.md").
        try write("# Not instructions\n", to: project.appending(path: ".github/instructions/notes.md"))
        try write("# Boundary\n", to: project.appending(path: ".github/instructions/myinstructions.md"))

        let files = RulesScanner().scan(homeRoot: nil, projectRoots: [
            AuthorizedRootSnapshot(id: "proj", url: project, kind: .project),
        ])
        XCTAssertEqual(files.map(\.filename), ["python.instructions.md"])
        XCTAssertEqual(files.first?.agentID, "github-copilot")
    }

    func testRooAndKiloModeRulesDirectoriesAreMatched() throws {
        let home = try makeDirectory("RulesRooModeHome")
        let project = try makeDirectory("RulesRooMode")
        try write("# Mode code\n", to: home.appending(path: ".roo/rules-code/arch.md"))
        try write("# Mode debug\n", to: project.appending(path: ".roo/rules-debug/dbg.md"))
        try write("# Kilo mode\n", to: project.appending(path: ".kilocode/rules-code/km.md"))
        // The pattern requires the "rules-" prefix: not a mode directory.
        try write("# Not a mode\n", to: project.appending(path: ".roo/rulesx/nope.md"))

        let files = RulesScanner().scan(
            homeRoot: AuthorizedRootSnapshot(id: "home", url: home, kind: .home),
            projectRoots: [
                AuthorizedRootSnapshot(id: "proj", url: project, kind: .project),
            ]
        )
        XCTAssertEqual(Set(files.map(\.path)), [
            home.appending(path: ".roo/rules-code/arch.md").path,
            project.appending(path: ".roo/rules-debug/dbg.md").path,
            project.appending(path: ".kilocode/rules-code/km.md").path,
        ])
        XCTAssertEqual(
            files.first { $0.path.contains(".roo/rules-code") }?.agentID,
            "roo-code"
        )
        XCTAssertEqual(
            files.first { $0.path.contains(".kilocode") }?.agentID,
            "kilo-code"
        )
    }

    func testQoderRulesDirectoryIsFound() throws {
        let project = try makeDirectory("RulesQoder")
        try write("# Qoder\n", to: project.appending(path: ".qoder/rules/api.md"))
        let files = RulesScanner().scan(homeRoot: nil, projectRoots: [
            AuthorizedRootSnapshot(id: "proj", url: project, kind: .project),
        ])
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files.first?.agentID, "qoder")
        XCTAssertEqual(files.first?.filename, "api.md")
    }

    func testAmpAgentFileIsFound() throws {
        let project = try makeDirectory("RulesAmp")
        try write("# Amp\n", to: project.appending(path: "AGENT.md"))
        let files = RulesScanner().scan(homeRoot: nil, projectRoots: [
            AuthorizedRootSnapshot(id: "proj", url: project, kind: .project),
        ])
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files.first?.agentID, "amp")
        XCTAssertEqual(files.first?.filename, "AGENT.md")
    }
}
