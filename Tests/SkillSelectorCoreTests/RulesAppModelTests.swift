import Foundation
import SwiftData
import XCTest
@testable import SkillSelector
@testable import SkillSelectorCore

/// Model-level integration for rules files: authorization + refresh
/// populates the rules list, and the validated reader loads a rules file's
/// content through the same security-scoped path the Skills use.
@MainActor
final class RulesAppModelTests: XCTestCase {
    func testRefreshPopulatesRulesFilesAndLoadsDocuments() async throws {
        let home = FileManager.default.temporaryDirectory
            .appending(path: "RulesAppModelHome-\(UUID().uuidString)", directoryHint: .isDirectory)
        let project = FileManager.default.temporaryDirectory
            .appending(path: "RulesAppModelProject-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: project)
        }
        try write("# Home Claude Rules\n\nKeep it local.\n", to: home.appending(path: ".claude/CLAUDE.md"))
        try write("# Project Rules\n\nAlways test first.\n", to: project.appending(path: "CLAUDE.md"))
        try write("# Cursor Rules\n", to: project.appending(path: ".cursorrules"))

        let suite = "RulesAppModelTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try ModelContainer(
            for: SkillRecord.self,
            AuthorizedRootRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let bookmarks = BookmarkStore(container: container, adapter: RulesPathBookmarkAdapter())
        let homeRoot = try bookmarks.save(url: home, kind: .home)
        let projectRoot = try bookmarks.save(url: project, kind: .project)
        let index = SkillIndex(container: container)
        let registry = BuiltInAgentRegistry.make()
        let refresher = IndexRefresher(
            registry: registry,
            bookmarks: bookmarks,
            index: index
        )
        let model = AppModel(
            refresher: refresher,
            index: index,
            bookmarks: bookmarks,
            registry: registry,
            defaults: defaults
        )

        await model.refresh()

        XCTAssertEqual(model.rules.files.count, 3)
        let homeClaude = model.rules.files.first { $0.path == home.appending(path: ".claude/CLAUDE.md").path }
        let projectClaude = model.rules.files.first { $0.path == project.appending(path: "CLAUDE.md").path }
        let cursorRules = model.rules.files.first { $0.path == project.appending(path: ".cursorrules").path }
        XCTAssertNotNil(homeClaude)
        XCTAssertNotNil(projectClaude)
        XCTAssertNotNil(cursorRules)

        // Global vs project attribution.
        XCTAssertNil(homeClaude?.projectRootID)
        XCTAssertEqual(projectClaude?.projectRootID, projectRoot.id)
        XCTAssertEqual(projectClaude?.agentIDs.contains("claude-code"), true)
        XCTAssertEqual(cursorRules?.agentIDs, ["cursor"])

        // The validated reader loads the content.
        let document = try await model.rules.loadDocument(projectClaude!)
        XCTAssertTrue(document.source.contains("# Project Rules"))
        XCTAssertEqual(document.fileURL.lastPathComponent, "CLAUDE.md")

        // Revoking the project root drops its rules files on reload.
        await model.revokeAuthorization(id: projectRoot.id)
        XCTAssertEqual(model.rules.files.count, 1)
        XCTAssertEqual(model.rules.files.first?.filename, "CLAUDE.md")
    }

    /// 「同名文件对比」：全局与项目同名的规则文件做行级 diff（复用 LineDiff）。
    /// 两文件正文各有一行不同 → +1 −1；同一文件对自身 → 全 same。
    func testBodyDiffComparesSameNamedFiles() async throws {
        let home = FileManager.default.temporaryDirectory
            .appending(path: "RulesDiffHome-\(UUID().uuidString)", directoryHint: .isDirectory)
        let project = FileManager.default.temporaryDirectory
            .appending(path: "RulesDiffProject-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: project)
        }
        try write("# Home Rules\n\nHome-only line.\n", to: home.appending(path: ".claude/CLAUDE.md"))
        try write("# Home Rules\n\nProject-only line.\n", to: project.appending(path: "CLAUDE.md"))

        let suite = "RulesDiffTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try ModelContainer(
            for: SkillRecord.self,
            AuthorizedRootRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let bookmarks = BookmarkStore(container: container, adapter: RulesPathBookmarkAdapter())
        _ = try bookmarks.save(url: home, kind: .home)
        _ = try bookmarks.save(url: project, kind: .project)
        let index = SkillIndex(container: container)
        let registry = BuiltInAgentRegistry.make()
        let refresher = IndexRefresher(registry: registry, bookmarks: bookmarks, index: index)
        let model = AppModel(
            refresher: refresher,
            index: index,
            bookmarks: bookmarks,
            registry: registry,
            defaults: defaults
        )

        await model.refresh()

        let homeClaude = try XCTUnwrap(
            model.rules.files.first { $0.path == home.appending(path: ".claude/CLAUDE.md").path }
        )
        let projectClaude = try XCTUnwrap(
            model.rules.files.first { $0.path == project.appending(path: "CLAUDE.md").path }
        )

        // Differing bodies → one added + one removed line.
        let diff = await model.rules.bodyDiff(homeClaude, projectClaude)
        XCTAssertEqual(diff?.addedCount, 1)
        XCTAssertEqual(diff?.removedCount, 1)

        // A file against itself → every row is same.
        let same = await model.rules.bodyDiff(homeClaude, homeClaude)
        XCTAssertEqual(same?.rows.allSatisfy { $0.kind == .same }, true)
    }

    /// 端到端验证共享项目规则文件的多 Agent 关联：项目根的一个 AGENTS.md
    /// 会被所有声明它的 Agent 共享，而不是只归给第一个声明者。
    ///
    /// 走完整管线——授权 home + project 目录、`refresh()` 触发重扫、再从
    /// `model.rules.files` 读取结果——而非直接调用 `RulesScanner`，确保
    /// 授权、IndexRefresher、RulesStateModel 的整条链路一起被验证。
    ///
    /// `expected` 集合必须与 `RulesRegistry.declarations` 中所有声明
    /// `projectPath: "AGENTS.md"` 的 Agent 保持一致：新增或移除这类声明时
    /// 需同步更新本测试（它锁定当前注册表行为，防止共享关联悄悄回退）。
    func testSharedProjectAgentsMdAssociatesEveryDeclaringAgent() async throws {
        let home = FileManager.default.temporaryDirectory
            .appending(path: "RulesSharedHome-\(UUID().uuidString)", directoryHint: .isDirectory)
        let project = FileManager.default.temporaryDirectory
            .appending(path: "RulesSharedProject-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: project)
        }
        try write("# Shared project briefing\n", to: project.appending(path: "AGENTS.md"))

        let suite = "RulesAppModelShared-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try ModelContainer(
            for: SkillRecord.self,
            AuthorizedRootRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let bookmarks = BookmarkStore(container: container, adapter: RulesPathBookmarkAdapter())
        _ = try bookmarks.save(url: home, kind: .home)
        let projectRoot = try bookmarks.save(url: project, kind: .project)
        let index = SkillIndex(container: container)
        let registry = BuiltInAgentRegistry.make()
        let refresher = IndexRefresher(
            registry: registry,
            bookmarks: bookmarks,
            index: index
        )
        let model = AppModel(
            refresher: refresher,
            index: index,
            bookmarks: bookmarks,
            registry: registry,
            defaults: defaults
        )

        await model.refresh()

        let agents = model.rules.files.first { $0.path == project.appending(path: "AGENTS.md").path }
        XCTAssertNotNil(agents, "the shared project AGENTS.md must be scanned")
        XCTAssertEqual(agents?.projectRootID, projectRoot.id)
        // A project-root AGENTS.md is read by every Agent that declares it —
        // the whole point of the shared-file multi-Agent association.
        let expected: Set<String> = [
            "cursor", "codex", "opencode", "windsurf", "kilo-code",
            "qoder", "codebuddy", "gemini-cli", "openhands", "letta",
            "kiro", "factory-droid", "goose",
        ]
        XCTAssertEqual(Set(agents?.agentIDs ?? []), expected)
    }

    func testLoadDocumentThrowsWhenProjectRootIsNotAuthorized() async throws {
        let suite = "RulesNoRoot-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try ModelContainer(
            for: SkillRecord.self,
            AuthorizedRootRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let bookmarks = BookmarkStore(container: container, adapter: RulesPathBookmarkAdapter())
        let index = SkillIndex(container: container)
        let registry = BuiltInAgentRegistry.make()
        let refresher = IndexRefresher(
            registry: registry,
            bookmarks: bookmarks,
            index: index
        )
        let model = AppModel(
            refresher: refresher,
            index: index,
            bookmarks: bookmarks,
            registry: registry,
            defaults: defaults
        )

        // A project rule whose project root is absent from the authorized
        // list must be rejected before any disk read.
        XCTAssertEqual(model.authorizedRoots, [])
        let orphan = RulesFileDescriptor(
            path: "/tmp/nowhere/CLAUDE.md",
            filename: "CLAUDE.md",
            agentIDs: ["claude-code"],
            projectRootID: "missing-root",
            fileSize: nil,
            modificationDate: nil
        )
        do {
            _ = try await model.rules.loadDocument(orphan)
            XCTFail("expected DocumentAccessError.noAuthorizedRoot")
        } catch let error as DocumentAccessError {
            XCTAssertEqual(error, .noAuthorizedRoot)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: Fixture

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// Path-encoding bookmark adapter — a bare `swift test` process lacks the
/// app-scope entitlement for real security-scoped bookmarks (same pattern
/// as the other test files' adapters).
private final class RulesPathBookmarkAdapter: BookmarkDataCreating, @unchecked Sendable {
    func createBookmarkData(for url: URL) throws -> Data { Data(url.path.utf8) }

    func resolveBookmarkData(_ data: Data) throws -> BookmarkResolution {
        BookmarkResolution(
            url: URL(fileURLWithPath: String(decoding: data, as: UTF8.self)),
            isStale: false
        )
    }

    func startAccessing(_ url: URL) -> Bool { true }

    func stopAccessing(_ url: URL) {}
}
