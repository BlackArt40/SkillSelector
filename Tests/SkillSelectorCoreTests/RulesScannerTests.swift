import Foundation
import XCTest
@testable import SkillSelectorCore

/// `RulesScanner` 单元测试：按注册表声明扫描授权根内的规则文件
/// （`CLAUDE.md`/`AGENTS.md`/`.cursorrules`/规则目录等），验证归属 Agent、
/// 共享文件的多 Agent 关联、扩展名过滤、仅一层不递归、大小上限等只读语义。
/// 每个测试在临时目录构造 fixture，不触碰真实用户目录。
final class RulesScannerTests: XCTestCase {
    /// 建一个带唯一名字的临时目录并在 teardown 时清理。
    private func makeDirectory(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// 写入一个规则文件（自动创建父目录）。
    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// 基础扫描：全局与项目规则文件都被发现；全局文件无项目根；项目
    /// CLAUDE.md 被多个声明它的 Agent 共享（多 Agent 关联），.cursorrules
    /// 仅归 cursor；文件大小与修改时间被捕获用于展示。
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
        XCTAssertEqual(claudeGlobal?.agentIDs, ["claude-code"])
        XCTAssertNil(claudeGlobal?.projectRootID)

        // Project files carry the project root id; CLAUDE.md is shared by
        // every Agent that declares it, Claude Code among them.
        let claudeProject = files.first { $0.path == project.appending(path: "CLAUDE.md").path }
        XCTAssertEqual(claudeProject?.agentIDs.contains("claude-code"), true)
        XCTAssertTrue((claudeProject?.agentIDs.count ?? 0) > 1)
        XCTAssertEqual(claudeProject?.projectRootID, "proj")
        XCTAssertEqual(
            files.first { $0.path == project.appending(path: ".cursorrules").path }?.agentIDs,
            ["cursor"]
        )
        // Sizes are captured for display.
        XCTAssertEqual(claudeProject?.fileSize, "# Project Claude\n".utf8.count)
        XCTAssertNotNil(claudeProject?.modificationDate)
    }

    /// 授权根内没有任何规则文件时返回空列表，不报错。
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

    /// 没有 home 授权时，全局声明被跳过，项目级文件仍被发现。
    func testWithoutHomeRootOnlyProjectFilesAreFound() throws {
        let project = try makeDirectory("RulesProjectOnly")
        try write("# Project\n", to: project.appending(path: "CLAUDE.md"))
        let files = RulesScanner().scan(homeRoot: nil, projectRoots: [
            AuthorizedRootSnapshot(id: "proj", url: project, kind: .project),
        ])
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files.first?.filename, "CLAUDE.md")
    }

    /// 名为 "CLAUDE.md" 的目录不是规则文件，被忽略（只认 regular file）。
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

    /// 超过读取大小上限的规则文件被跳过，不读取内容。
    func testOversizedRulesFilesAreSkipped() throws {
        let project = try makeDirectory("RulesProjectBig")
        let huge = Data(repeating: 0x41, count: RulesScanner.maximumRulesFileBytes + 1)
        try huge.write(to: project.appending(path: "CLAUDE.md"))
        let files = RulesScanner().scan(homeRoot: nil, projectRoots: [
            AuthorizedRootSnapshot(id: "proj", url: project, kind: .project),
        ])
        XCTAssertTrue(files.isEmpty, "an oversized rules file must be skipped, not read")
    }

    /// 项目内嵌套路径的规则文件（.github/copilot-instructions.md）被发现。
    func testNestedProjectRulesAreFound() throws {
        let project = try makeDirectory("RulesProjectNested")
        try write("# Copilot\n", to: project.appending(path: ".github/copilot-instructions.md"))
        let files = RulesScanner().scan(homeRoot: nil, projectRoots: [
            AuthorizedRootSnapshot(id: "proj", url: project, kind: .project),
        ])
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files.first?.filename, "copilot-instructions.md")
        XCTAssertEqual(files.first?.agentIDs, ["github-copilot"])
    }

    // MARK: Directory sources (.cursor/rules, .claude/rules)

    /// .cursor/rules 目录：只收扩展名匹配的直接子级文件（.mdc），忽略
    /// 其他扩展名与嵌套子目录（仅一层，不递归）。
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
        XCTAssertTrue(files.allSatisfy { $0.agentIDs == ["cursor"] && $0.projectRootID == "proj" })
    }

    /// .claude/rules 目录在全局与项目两处都被扫描；扩展名只收 .md，
    /// 同目录下的 .mdc 归 Cursor 而非 Claude。
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
        XCTAssertTrue(files.allSatisfy { $0.agentIDs == ["claude-code"] })
        XCTAssertEqual(
            files.first { $0.path.contains(".claude/rules/style.md") }?.projectRootID,
            nil
        )
        XCTAssertEqual(
            files.first { $0.path.contains(".claude/rules/testing.md") }?.projectRootID,
            "proj"
        )
    }

    /// CLAUDE.local.md（Claude 的项目级本地规则）被发现。
    func testClaudeLocalMdIsFound() throws {
        let project = try makeDirectory("RulesClaudeLocal")
        try write("# Local\n", to: project.appending(path: "CLAUDE.local.md"))
        let files = RulesScanner().scan(homeRoot: nil, projectRoots: [
            AuthorizedRootSnapshot(id: "proj", url: project, kind: .project),
        ])
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files.first?.agentIDs, ["claude-code"])
        XCTAssertEqual(files.first?.filename, "CLAUDE.local.md")
    }

    /// 规则目录内同样受大小上限约束：超限文件跳过，其余正常返回。
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

    /// 声明的规则目录不存在时静默跳过（不报错、不产出）。
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
        XCTAssertTrue(files.allSatisfy { $0.agentIDs == ["roo-code"] })
    }

    /// .kilocode/rules 目录（Kilo Code 的规则目录）被发现。
    func testKiloRulesDirectoryIsFound() throws {
        let project = try makeDirectory("RulesKilo")
        try write("# Kilo\n", to: project.appending(path: ".kilocode/rules/style.md"))
        let files = RulesScanner().scan(homeRoot: nil, projectRoots: [
            AuthorizedRootSnapshot(id: "proj", url: project, kind: .project),
        ])
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files.first?.agentIDs, ["kilo-code"])
        XCTAssertEqual(files.first?.filename, "style.md")
    }

    /// Cline：项目 .clinerules 目录 + 全局 ~/Documents/Cline/Rules 都被扫描。
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
        XCTAssertTrue(files.allSatisfy { $0.agentIDs == ["cline"] })
    }

    /// Windsurf：项目 .windsurf/rules 目录 + 全局 memories/global_rules.md。
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
        XCTAssertTrue(files.allSatisfy { $0.agentIDs == ["windsurf"] })
    }

    /// Gemini CLI：GEMINI.md 的全局与项目两级都被扫描。
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
        XCTAssertTrue(files.allSatisfy { $0.agentIDs == ["gemini-cli"] })
    }

    /// .github/instructions 目录按文件名后缀匹配（.instructions.md），
    /// 且后缀需带点边界（"myinstructions.md" 不匹配）。
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
        XCTAssertEqual(files.first?.agentIDs, ["github-copilot"])
    }

    /// Roo/Kilo 的 `rules-*` 通配模式目录：只匹配以 "rules-" 为前缀的
    /// 兄弟目录并各列一层，前缀不符的目录被忽略。
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
            files.first { $0.path.contains(".roo/rules-code") }?.agentIDs,
            ["roo-code"]
        )
        XCTAssertEqual(
            files.first { $0.path.contains(".kilocode") }?.agentIDs,
            ["kilo-code"]
        )
    }

    /// .qoder/rules 目录（Qoder 的规则目录）被发现。
    func testQoderRulesDirectoryIsFound() throws {
        let project = try makeDirectory("RulesQoder")
        try write("# Qoder\n", to: project.appending(path: ".qoder/rules/api.md"))
        let files = RulesScanner().scan(homeRoot: nil, projectRoots: [
            AuthorizedRootSnapshot(id: "proj", url: project, kind: .project),
        ])
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files.first?.agentIDs, ["qoder"])
        XCTAssertEqual(files.first?.filename, "api.md")
    }

    /// Amp 的项目根 AGENT.md（单数）被发现，归 Amp。
    func testAmpAgentFileIsFound() throws {
        let project = try makeDirectory("RulesAmp")
        try write("# Amp\n", to: project.appending(path: "AGENT.md"))
        let files = RulesScanner().scan(homeRoot: nil, projectRoots: [
            AuthorizedRootSnapshot(id: "proj", url: project, kind: .project),
        ])
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files.first?.agentIDs, ["amp"])
        XCTAssertEqual(files.first?.filename, "AGENT.md")
    }
}
