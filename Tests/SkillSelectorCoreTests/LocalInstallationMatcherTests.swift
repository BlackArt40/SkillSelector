import XCTest
@testable import SkillSelector
@testable import SkillSelectorCore

/// 市场 Skill 与本地索引的匹配器（`LocalInstallationMatcher`）单元测试：
/// 按 Skill 目录名（忽略大小写/变音符/全半角）把远程目录 Skill 关联到本地
/// 安装，供市场详情「对照本地」与列表「已安装」标记使用。纯函数，无 I/O。
final class LocalInstallationMatcherTests: XCTestCase {
    /// 构造一个来自 anthropics/skills 的市场 Skill 元数据。
    private func marketSkill(name: String) -> CatalogSkill {
        CatalogSkill(
            id: "anthropics/skills:skills/\(name)/SKILL.md",
            sourceID: "anthropics/skills",
            name: name,
            skillPath: "skills/\(name)/SKILL.md",
            githubURL: URL(string: "https://github.com/anthropics/skills/tree/main/skills/\(name)")!,
            rawURL: URL(string: "https://raw.githubusercontent.com/anthropics/skills/main/skills/\(name)/SKILL.md")!
        )
    }

    /// 构造一条本地 Skill 安装（路径、名称、关联 Agent）。
    private func snapshot(
        name: String,
        path: String = "/tmp/skills/",
        agentIDs: [String] = ["claude-code"]
    ) -> SkillSnapshot {
        SkillSnapshot(
            path: path + name,
            resolvedTarget: nil,
            name: name,
            localDescription: nil,
            modificationDate: nil,
            agentIDs: agentIDs,
            rootIDs: ["root-1"],
            entryFilename: "SKILL.md",
            parseDiagnostics: []
        )
    }

    /// 目录名完全一致时视为已安装。
    func testExactNameMatch() {
        let local = snapshot(name: "pdf")
        let matches = LocalInstallationMatcher.localInstallations(
            of: marketSkill(name: "pdf"),
            in: [local]
        )
        XCTAssertEqual(matches.map(\.path), [local.path])
    }

    /// 名称忽略大小写：本地 "PDF" 匹配市场 "pdf"。
    func testCaseInsensitiveMatch() {
        let local = snapshot(name: "PDF")
        let matches = LocalInstallationMatcher.localInstallations(
            of: marketSkill(name: "pdf"),
            in: [local]
        )
        XCTAssertEqual(matches.map(\.path), [local.path])
    }

    /// 本地没有任何同名安装时返回空（不误报）。
    func testNoMatchWhenAbsent() {
        let matches = LocalInstallationMatcher.localInstallations(
            of: marketSkill(name: "pdf"),
            in: [snapshot(name: "browser"), snapshot(name: "notion")]
        )
        XCTAssertTrue(matches.isEmpty)
    }

    /// 本地索引为空时返回空，不崩溃。
    func testEmptyLocalIndex() {
        let matches = LocalInstallationMatcher.localInstallations(
            of: marketSkill(name: "pdf"),
            in: []
        )
        XCTAssertTrue(matches.isEmpty)
    }

    /// 同名安装在多个 Agent 下时全部返回，且各自保留 Agent 关联——
    /// 详情页「装在哪个 Agent」依赖此行为。
    func testMatchesEveryLocalCopyWithAgents() {
        let first = snapshot(name: "pdf", path: "/Users/alice/.claude/skills/", agentIDs: ["claude-code"])
        let second = snapshot(name: "pdf", path: "/Users/alice/.codex/skills/", agentIDs: ["codex"])
        let matches = LocalInstallationMatcher.localInstallations(
            of: marketSkill(name: "pdf"),
            in: [first, second]
        )
        XCTAssertEqual(matches.map(\.path), [first.path, second.path])
        XCTAssertEqual(matches.map(\.agentIDs), [["claude-code"], ["codex"]])
    }

    /// 无关名称不参与匹配。
    func testIgnoresUnrelatedNames() {
        let local = snapshot(name: "pdf")
        let matches = LocalInstallationMatcher.localInstallations(
            of: marketSkill(name: "docs"),
            in: [local]
        )
        XCTAssertTrue(matches.isEmpty)
    }

    /// 列表侧 `installedNames` 集合（O(1) 查询）与详情侧用同一套归一化规则：
    /// "PDF" 归入集合后，"pdf" 能查到，无关词查不到，空索引返回空集合。
    func testInstalledNamesSetMatchesCaseInsensitively() {
        let installed = LocalInstallationMatcher.installedNames(in: [snapshot(name: "PDF")])
        XCTAssertTrue(LocalInstallationMatcher.isInstalled(name: "pdf", installedNames: installed))
        XCTAssertFalse(LocalInstallationMatcher.isInstalled(name: "docs", installedNames: installed))
        XCTAssertTrue(LocalInstallationMatcher.installedNames(in: []).isEmpty)
    }

    /// `installedNames` 集合能容纳多个名称并正确区分命中与未命中。
    func testInstalledNamesSetMatchesAcrossNormalization() {
        let installed = LocalInstallationMatcher.installedNames(
            in: [snapshot(name: "pdf"), snapshot(name: "web-search")]
        )
        XCTAssertTrue(LocalInstallationMatcher.isInstalled(name: "web-search", installedNames: installed))
        XCTAssertFalse(LocalInstallationMatcher.isInstalled(name: "browser", installedNames: installed))
    }
}
