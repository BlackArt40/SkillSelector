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

    func testFailedHomeBookmarkMarksPreviouslyIndexedSkillUnavailable() async throws {
        let fixture = try RefreshFixture()
        try fixture.writeSkill(at: ".claude/skills/demo", name: "demo")
        let adapter = FixtureBookmarkAdapter()
        let container = try fixture.makeContainer()
        let bookmarks = BookmarkStore(container: container, adapter: adapter)
        _ = try bookmarks.save(url: fixture.home, kind: .home)
        let index = SkillIndex(container: container)
        let refresher = IndexRefresher(
            registry: BuiltInAgentRegistry.make(),
            bookmarks: bookmarks,
            index: index
        )

        let first = try await refresher.refresh(.startup)
        adapter.shouldFailResolution = true
        let second = try await refresher.refresh(.manual)

        XCTAssertEqual(first.added, 1)
        XCTAssertEqual(second.unavailable, 1)
        XCTAssertEqual(try index.skills().first?.availability, .unavailable)
    }

    func testFailedMatchedSystemBookmarkMarksPreviouslyIndexedSkillUnavailable() async throws {
        let fixture = try RefreshFixture()
        try fixture.writeSkill(at: "system/demo", name: "demo")
        let system = fixture.home.appending(path: "system")
        let registry = AgentRegistry(definitions: [
            AgentDefinition(
                id: "system-agent",
                displayName: "System Agent",
                globalRoots: [system.path],
                projectPatterns: []
            ),
        ])
        let adapter = FixtureBookmarkAdapter()
        let container = try fixture.makeContainer()
        let bookmarks = BookmarkStore(container: container, adapter: adapter)
        _ = try bookmarks.save(url: system, kind: .system)
        let index = SkillIndex(container: container)
        let refresher = IndexRefresher(
            registry: registry,
            bookmarks: bookmarks,
            index: index
        )

        let first = try await refresher.refresh(.startup)
        adapter.shouldFailResolution = true
        let second = try await refresher.refresh(.manual)

        XCTAssertEqual(first.added, 1)
        XCTAssertEqual(second.unavailable, 1)
        XCTAssertEqual(try index.skills().first?.availability, .unavailable)
    }

    func testDisappearingRegisteredHomeRootRemovesItsPriorInstallations() async throws {
        let fixture = try RefreshFixture()
        try fixture.writeSkill(at: ".claude/skills/demo", name: "demo")
        let skillsRoot = fixture.home.appending(path: ".claude/skills")
        let adapter = FixtureBookmarkAdapter()
        let container = try fixture.makeContainer()
        let bookmarks = BookmarkStore(container: container, adapter: adapter)
        _ = try bookmarks.save(url: fixture.home, kind: .home)
        let index = SkillIndex(container: container)
        let refresher = IndexRefresher(
            registry: BuiltInAgentRegistry.make(),
            bookmarks: bookmarks,
            index: index
        )

        let first = try await refresher.refresh(.startup)
        try FileManager.default.removeItem(at: skillsRoot)
        let second = try await refresher.refresh(.manual)

        XCTAssertEqual(first.added, 1)
        XCTAssertEqual(second.removed, 1)
        XCTAssertTrue(try index.skills().isEmpty)
    }

    func testTemplatedHomeRootDoesNotEnumerateSymlinkedParentOutsideHome() async throws {
        let fixture = try RefreshFixture()
        let outside = FileManager.default.temporaryDirectory
            .appending(path: "IndexRefresherOutside-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outside) }
        try RefreshFixture.writeSkill(at: outside.appending(path: "skills-escape/private"), name: "private")
        try FileManager.default.createSymbolicLink(
            at: fixture.home.appending(path: ".roo"),
            withDestinationURL: outside
        )
        let fileSystem = RecordingIndexRefresherFileSystem()
        let adapter = FixtureBookmarkAdapter()
        let container = try fixture.makeContainer()
        let bookmarks = BookmarkStore(container: container, adapter: adapter)
        _ = try bookmarks.save(url: fixture.home, kind: .home)
        let index = SkillIndex(container: container)
        let refresher = IndexRefresher(
            registry: BuiltInAgentRegistry.make(),
            bookmarks: bookmarks,
            scanner: SkillScanner(),
            index: index,
            fileSystem: fileSystem
        )

        _ = try await refresher.refresh(.startup)

        XCTAssertTrue(try index.skills().isEmpty)
        XCTAssertFalse(fileSystem.enumeratedURLs.contains(fixture.home.appending(path: ".roo")))
        XCTAssertTrue(fileSystem.probedDirectoryURLs.allSatisfy {
            !$0.path.hasPrefix(outside.path)
        })
    }

    func testDisappearingLastTemplatedHomeRootRemovesItsPriorInstallations() async throws {
        let fixture = try RefreshFixture()
        try fixture.writeSkill(at: ".roo/skills-code/demo", name: "demo")
        let skillsRoot = fixture.home.appending(path: ".roo/skills-code")
        let registry = AgentRegistry(definitions: [
            AgentDefinition(
                id: "templated",
                displayName: "Templated",
                globalRoots: ["~/.roo/skills-{modeSlug}"],
                projectPatterns: []
            ),
        ])
        let adapter = FixtureBookmarkAdapter()
        let container = try fixture.makeContainer()
        let bookmarks = BookmarkStore(container: container, adapter: adapter)
        _ = try bookmarks.save(url: fixture.home, kind: .home)
        let index = SkillIndex(container: container)
        let refresher = IndexRefresher(
            registry: registry,
            bookmarks: bookmarks,
            index: index
        )

        let first = try await refresher.refresh(.startup)
        try FileManager.default.removeItem(at: skillsRoot)
        let second = try await refresher.refresh(.manual)

        XCTAssertEqual(first.added, 1)
        XCTAssertEqual(second.removed, 1)
        XCTAssertTrue(try index.skills().isEmpty)
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
        try Self.writeSkill(at: home.appending(path: relativePath), name: name)
    }

    static func writeSkill(at directory: URL, name: String) throws {
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

private final class RecordingIndexRefresherFileSystem: IndexRefresherFileSystem {
    private(set) var enumeratedURLs: [URL] = []
    private(set) var probedDirectoryURLs: [URL] = []

    func isDirectory(_ url: URL) -> Bool {
        probedDirectoryURLs.append(url.standardizedFileURL)
        return (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    func contentsOfDirectory(at url: URL) -> [URL] {
        enumeratedURLs.append(url.standardizedFileURL)
        return (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        )) ?? []
    }

    func resolvingSymlinks(in url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }
}
