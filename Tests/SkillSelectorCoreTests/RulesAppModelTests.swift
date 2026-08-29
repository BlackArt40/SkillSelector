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

        XCTAssertEqual(model.rulesFiles.count, 3)
        let homeClaude = model.rulesFiles.first { $0.path == home.appending(path: ".claude/CLAUDE.md").path }
        let projectClaude = model.rulesFiles.first { $0.path == project.appending(path: "CLAUDE.md").path }
        let cursorRules = model.rulesFiles.first { $0.path == project.appending(path: ".cursorrules").path }
        XCTAssertNotNil(homeClaude)
        XCTAssertNotNil(projectClaude)
        XCTAssertNotNil(cursorRules)

        // Global vs project attribution.
        XCTAssertNil(homeClaude?.projectRootID)
        XCTAssertEqual(projectClaude?.projectRootID, projectRoot.id)
        XCTAssertEqual(projectClaude?.agentID, "claude-code")
        XCTAssertEqual(cursorRules?.agentID, "cursor")

        // The validated reader loads the content.
        let document = try await model.loadRulesDocument(projectClaude!)
        XCTAssertTrue(document.source.contains("# Project Rules"))
        XCTAssertEqual(document.fileURL.lastPathComponent, "CLAUDE.md")

        // Revoking the project root drops its rules files on reload.
        await model.revokeAuthorization(id: projectRoot.id)
        XCTAssertEqual(model.rulesFiles.count, 1)
        XCTAssertEqual(model.rulesFiles.first?.path, homeClaude?.path)
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
