import Foundation
import SwiftData
import XCTest
@testable import SkillSelectorCore

@MainActor
final class IndexRefresherTests: XCTestCase {
    func testHomeRefreshEnumeratesOnlyRegistryDeclaredGlobalRoots() async throws {
        let fixture = try RefreshFixture()
        try fixture.writeSkill(at: ".claude/skills/known", name: "known")
        try fixture.writeSkill(at: ".roo/skills-code/mode", name: "mode")
        try fixture.writeSkill(at: "Documents/private", name: "private")

        let adapter = FixtureBookmarkAdapter()
        let container = try fixture.makeContainer()
        let bookmarks = BookmarkStore(container: container, adapter: adapter)
        let home = try bookmarks.save(url: fixture.home, kind: .home)
        let index = SkillIndex(container: container)
        let refresher = IndexRefresher(
            registry: BuiltInAgentRegistry.make(),
            bookmarks: bookmarks,
            scanner: SkillScanner(),
            index: index
        )

        let summary = try await refresher.refresh(.startup)
        let skills = try index.skills()

        XCTAssertEqual(summary.added, 2)
        XCTAssertEqual(skills.map(\.name), ["known", "mode"])
        XCTAssertFalse(skills.contains { $0.name == "private" })
        _ = home
    }

    func testFailedBookmarkResolutionDoesNotScanPersistedPath() async throws {
        let fixture = try RefreshFixture()
        try fixture.writeSkill(at: "custom/private", name: "private")
        let adapter = FixtureBookmarkAdapter()
        let container = try fixture.makeContainer()
        let bookmarks = BookmarkStore(container: container, adapter: adapter)
        _ = try bookmarks.save(url: fixture.home.appending(path: "custom"), kind: .custom)
        adapter.shouldFailResolution = true
        let index = SkillIndex(container: container)
        let refresher = IndexRefresher(
            registry: BuiltInAgentRegistry.make(),
            bookmarks: bookmarks,
            index: index
        )

        _ = try await refresher.refresh(.startup)

        XCTAssertTrue(try index.skills().isEmpty)
    }

    func testUnavailableProjectIsNotAlsoCountedAsChangedAndLeasesClose() async throws {
        let fixture = try RefreshFixture()
        try fixture.writeSkill(at: "project/packages/app/.cursor/skills/demo", name: "demo")
        let project = fixture.home.appending(path: "project")
        let adapter = FixtureBookmarkAdapter()
        let container = try fixture.makeContainer()
        let bookmarks = BookmarkStore(container: container, adapter: adapter)
        _ = try bookmarks.save(url: project, kind: .project)
        let index = SkillIndex(container: container)
        let refresher = IndexRefresher(
            registry: BuiltInAgentRegistry.make(),
            bookmarks: bookmarks,
            index: index
        )

        let first = try await refresher.refresh(.startup)
        try FileManager.default.removeItem(at: project)
        let second = try await refresher.refresh(.manual)

        XCTAssertEqual(first.added, 1)
        XCTAssertEqual(second.changed, 0)
        XCTAssertEqual(second.unavailable, 1)
        XCTAssertEqual(second.removed, 0)
        XCTAssertEqual(try index.skills().first?.availability, .unavailable)
        XCTAssertEqual(adapter.stoppedURLs.map(\.path), [project.path, project.path])
    }

}

private final class RefreshFixture: @unchecked Sendable {
    let home: URL

    init() throws {
        home = FileManager.default.temporaryDirectory
            .appending(path: "IndexRefresherTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: home) }

    func writeSkill(at relativePath: String, name: String) throws {
        let directory = home.appending(path: relativePath)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "---\nname: \(name)\n---\n# \(name)\n".write(
            to: directory.appending(path: "SKILL.md"), atomically: true, encoding: .utf8
        )
    }

    func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: SkillRecord.self,
            AuthorizedRootRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }
}

private final class FixtureBookmarkAdapter: BookmarkDataCreating {
    var shouldFailResolution = false
    private(set) var stoppedURLs: [URL] = []

    func createBookmarkData(for url: URL) throws -> Data { Data(url.path.utf8) }

    func resolveBookmarkData(_ data: Data) throws -> BookmarkResolution {
        if shouldFailResolution { throw FixtureBookmarkError.denied }
        return BookmarkResolution(
            url: URL(fileURLWithPath: String(decoding: data, as: UTF8.self)),
            isStale: false
        )
    }

    func startAccessing(_ url: URL) -> Bool { true }
    func stopAccessing(_ url: URL) { stoppedURLs.append(url.standardizedFileURL) }
}

private enum FixtureBookmarkError: Error {
    case denied
}
