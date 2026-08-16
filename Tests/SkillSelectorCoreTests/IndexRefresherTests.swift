import Foundation
import SwiftData
import XCTest
@testable import SkillSelectorCore

@MainActor
final class IndexRefresherTests: XCTestCase {
    func testHomeRefreshUsesCanonicalOwnersAndLeavesSharedAgentsEmpty() async throws {
        let fixture = try RefreshFixture()
        try fixture.writeSkill(at: ".codex/skills/codex-only", name: "codex-only")
        try fixture.writeSkill(at: ".claude/skills/claude-only", name: "claude-only")
        try fixture.writeSkill(at: ".agents/skills/shared", name: "shared")
        let container = try fixture.makeContainer()
        let bookmarks = BookmarkStore(container: container, adapter: FixtureBookmarkAdapter())
        _ = try bookmarks.save(url: fixture.home, kind: .home)
        let index = SkillIndex(container: container)
        let refresher = IndexRefresher(
            registry: BuiltInAgentRegistry.make(),
            bookmarks: bookmarks,
            index: index
        )

        _ = try await refresher.refresh()
        let skills = Dictionary(uniqueKeysWithValues: try index.skills().map { ($0.name, $0) })

        XCTAssertEqual(skills["codex-only"]?.agentIDs, ["codex"])
        XCTAssertEqual(skills["claude-only"]?.agentIDs, ["claude-code"])
        XCTAssertEqual(skills["shared"]?.agentIDs, [])
        XCTAssertEqual(skills["shared"]?.rootIDs.count, 1)
    }

    func testAccessibleRefreshRemovesLegacyCompatibilityAssociations() async throws {
        let fixture = try RefreshFixture()
        try fixture.writeSkill(at: ".agents/skills/shared", name: "shared")
        let container = try fixture.makeContainer()
        let bookmarks = BookmarkStore(container: container, adapter: FixtureBookmarkAdapter())
        let homeRoot = try bookmarks.save(url: fixture.home, kind: .home)
        let index = SkillIndex(container: container)
        let sharedURL = fixture.home.appending(path: ".agents/skills/shared")
        try index.apply(report: ScanReport(
            installations: [
                ScannedSkill(
                    installation: SkillInstallation(path: sharedURL),
                    document: ParsedSkillDocument(name: "shared"),
                    agentIDsByRoot: [homeRoot.id: ["cursor", "gemini-cli"]],
                    entryFilename: "SKILL.md"
                ),
            ],
            roots: [
                ScannedRoot(id: homeRoot.id, url: fixture.home, availability: .available),
            ]
        ))
        let refresher = IndexRefresher(
            registry: BuiltInAgentRegistry.make(),
            bookmarks: bookmarks,
            index: index
        )

        _ = try await refresher.refresh()
        let refreshed = try XCTUnwrap(index.skills().first { $0.name == "shared" })

        XCTAssertEqual(refreshed.agentIDs, [])
        XCTAssertEqual(refreshed.rootIDs, [homeRoot.id])
    }

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

        let summary = try await refresher.refresh()
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

        _ = try await refresher.refresh()

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

        let first = try await refresher.refresh()
        try FileManager.default.removeItem(at: project)
        let second = try await refresher.refresh()

        XCTAssertEqual(first.added, 1)
        XCTAssertEqual(second.changed, 0)
        XCTAssertEqual(second.removed, 1)
        XCTAssertTrue(try index.skills().isEmpty)
        XCTAssertEqual(adapter.stoppedURLs.map(\.path), [project.path, project.path])
    }

    func testInaccessibleAuthorizedProjectDropsItsPriorInstallations() async throws {
        let fixture = try RefreshFixture()
        try fixture.writeSkill(at: "project/.cursor/skills/demo", name: "demo")
        let project = fixture.home.appending(path: "project")
        let adapter = FixtureBookmarkAdapter()
        let container = try fixture.makeContainer()
        let bookmarks = BookmarkStore(container: container, adapter: adapter)
        _ = try bookmarks.save(url: project, kind: .project)
        let index = SkillIndex(container: container)
        let fileSystem = RecordingIndexRefresherFileSystem()
        let refresher = IndexRefresher(
            registry: BuiltInAgentRegistry.make(),
            bookmarks: bookmarks,
            index: index,
            fileSystem: fileSystem
        )

        let first = try await refresher.refresh()
        fileSystem.inaccessiblePaths.insert(project.standardizedFileURL.path)
        let second = try await refresher.refresh()

        XCTAssertEqual(first.added, 1)
        XCTAssertEqual(second.removed, 1)
        XCTAssertTrue(try index.skills().isEmpty)
    }

    func testFailedHomeBookmarkDropsPreviouslyIndexedSkill() async throws {
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

        let first = try await refresher.refresh()
        adapter.shouldFailResolution = true
        let second = try await refresher.refresh()

        XCTAssertEqual(first.added, 1)
        XCTAssertEqual(second.removed, 1)
        XCTAssertTrue(try index.skills().isEmpty)
    }

    func testFailedMatchedSystemBookmarkDropsPreviouslyIndexedSkill() async throws {
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

        let first = try await refresher.refresh()
        adapter.shouldFailResolution = true
        let second = try await refresher.refresh()

        XCTAssertEqual(first.added, 1)
        XCTAssertEqual(second.removed, 1)
        XCTAssertTrue(try index.skills().isEmpty)
    }

    func testInaccessibleExactSystemAndCustomRootsDropPriorInstallations() async throws {
        let fixture = try RefreshFixture()
        try fixture.writeSkill(at: "system/system-demo", name: "system-demo")
        try fixture.writeSkill(at: "custom/custom-demo", name: "custom-demo")
        let system = fixture.home.appending(path: "system")
        let custom = fixture.home.appending(path: "custom")
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
        _ = try bookmarks.save(url: custom, kind: .custom)
        let index = SkillIndex(container: container)
        let fileSystem = RecordingIndexRefresherFileSystem()
        let refresher = IndexRefresher(
            registry: registry,
            bookmarks: bookmarks,
            index: index,
            fileSystem: fileSystem
        )

        let first = try await refresher.refresh()
        fileSystem.inaccessiblePaths = Set([system.path, custom.path])
        let second = try await refresher.refresh()

        XCTAssertEqual(first.added, 2)
        XCTAssertEqual(second.removed, 2)
        XCTAssertTrue(try index.skills().isEmpty)
    }

    func testInaccessibleAuthorizedHomeDropsPriorInstallations() async throws {
        let fixture = try RefreshFixture()
        try fixture.writeSkill(at: ".claude/skills/demo", name: "demo")
        let adapter = FixtureBookmarkAdapter()
        let container = try fixture.makeContainer()
        let bookmarks = BookmarkStore(container: container, adapter: adapter)
        _ = try bookmarks.save(url: fixture.home, kind: .home)
        let index = SkillIndex(container: container)
        let fileSystem = RecordingIndexRefresherFileSystem()
        let refresher = IndexRefresher(
            registry: BuiltInAgentRegistry.make(),
            bookmarks: bookmarks,
            index: index,
            fileSystem: fileSystem
        )

        let first = try await refresher.refresh()
        fileSystem.inaccessiblePaths.insert(fixture.home.standardizedFileURL.path)
        let second = try await refresher.refresh()

        XCTAssertEqual(first.added, 1)
        XCTAssertEqual(second.removed, 1)
        XCTAssertTrue(try index.skills().isEmpty)
    }

    func testUnavailableHomeChildIsDroppedWhileAvailableSiblingSurvives() async throws {
        let fixture = try RefreshFixture()
        try fixture.writeSkill(at: ".first/skills/first", name: "first")
        try fixture.writeSkill(at: ".second/skills/second", name: "second")
        let firstRoot = fixture.home.appending(path: ".first/skills")
        let registry = AgentRegistry(definitions: [
            AgentDefinition(
                id: "first-agent",
                displayName: "First Agent",
                globalRoots: ["~/.first/skills"],
                projectPatterns: []
            ),
            AgentDefinition(
                id: "second-agent",
                displayName: "Second Agent",
                globalRoots: ["~/.second/skills"],
                projectPatterns: []
            ),
        ])
        let adapter = FixtureBookmarkAdapter()
        let container = try fixture.makeContainer()
        let bookmarks = BookmarkStore(container: container, adapter: adapter)
        _ = try bookmarks.save(url: fixture.home, kind: .home)
        let index = SkillIndex(container: container)
        let fileSystem = RecordingIndexRefresherFileSystem()
        let refresher = IndexRefresher(
            registry: registry,
            bookmarks: bookmarks,
            index: index,
            fileSystem: fileSystem
        )

        let first = try await refresher.refresh()
        fileSystem.inaccessiblePaths.insert(firstRoot.path)
        let second = try await refresher.refresh()
        let skills = try index.skills()

        XCTAssertEqual(first.added, 2)
        XCTAssertEqual(second.removed, 1)
        XCTAssertEqual(skills.map(\.name), ["second"])
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

        let first = try await refresher.refresh()
        try FileManager.default.removeItem(at: skillsRoot)
        let second = try await refresher.refresh()

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

        _ = try await refresher.refresh()

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

        let first = try await refresher.refresh()
        try FileManager.default.removeItem(at: skillsRoot)
        let second = try await refresher.refresh()

        XCTAssertEqual(first.added, 1)
        XCTAssertEqual(second.removed, 1)
        XCTAssertTrue(try index.skills().isEmpty)
    }

    func testAffectedRootRefreshLeavesUnselectedRootUntouched() async throws {
        let fixture = try RefreshFixture()
        try fixture.writeSkill(at: "first/.cursor/skills/one", name: "one")
        try fixture.writeSkill(at: "second/.cursor/skills/two", name: "two")
        let firstURL = fixture.home.appending(path: "first")
        let secondURL = fixture.home.appending(path: "second")
        let adapter = FixtureBookmarkAdapter()
        let container = try fixture.makeContainer()
        let bookmarks = BookmarkStore(container: container, adapter: adapter)
        let first = try bookmarks.save(url: firstURL, kind: .project)
        _ = try bookmarks.save(url: secondURL, kind: .project)
        let index = SkillIndex(container: container)
        let refresher = IndexRefresher(
            registry: BuiltInAgentRegistry.make(),
            bookmarks: bookmarks,
            index: index
        )
        _ = try await refresher.refresh()
        try FileManager.default.removeItem(at: firstURL)
        try FileManager.default.removeItem(at: secondURL)

        _ = try await refresher.refresh(rootIDs: [first.id])

        let skills = try index.skills()
        XCTAssertEqual(skills.map(\.name), ["two"])
        XCTAssertEqual(adapter.stoppedURLs.filter { $0.path == firstURL.path }.count, 2)
        XCTAssertEqual(adapter.stoppedURLs.filter { $0.path == secondURL.path }.count, 1)
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

private final class FixtureBookmarkAdapter: BookmarkDataCreating, @unchecked Sendable {
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
    var inaccessiblePaths: Set<String> = []
    private(set) var enumeratedURLs: [URL] = []
    private(set) var probedDirectoryURLs: [URL] = []

    func probeDirectory(_ url: URL) throws -> DirectoryProbe {
        let standardizedURL = url.standardizedFileURL
        probedDirectoryURLs.append(standardizedURL)
        if inaccessiblePaths.contains(standardizedURL.path) {
            throw FixtureFileSystemError.inaccessible
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: standardizedURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return .missing
        }
        return .directory
    }

    func contentsOfDirectory(at url: URL) throws -> [URL] {
        enumeratedURLs.append(url.standardizedFileURL)
        return try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        )
    }

    func resolvingSymlinks(in url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }
}

private enum FixtureFileSystemError: Error {
    case inaccessible
}
