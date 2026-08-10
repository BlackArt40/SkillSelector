import Foundation
import SwiftData
import XCTest
@testable import SkillSelector
@testable import SkillSelectorCore

@MainActor
final class DocumentManagerTests: XCTestCase {
    private let temporaryDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("DocumentManagerTests.\(UUID().uuidString)")

    override func setUp() {
        super.setUp()
        try? FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: temporaryDirectory)
        super.tearDown()
    }

    private func makeStore() throws -> BookmarkStore {
        let container = try ModelContainer(
            for: SkillRecord.self,
            AuthorizedRootRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return BookmarkStore(container: container, adapter: PathEncodingBookmarkAdapter())
    }

    private func makeSnapshot(
        path: String,
        rootIDs: [String],
        resolvedTarget: String? = nil,
        entryFilename: String = "SKILL.md"
    ) -> SkillSnapshot {
        SkillSnapshot(
            path: path,
            resolvedTarget: resolvedTarget,
            name: "demo",
            localDescription: nil,
            customDescription: nil,
            modificationDate: nil,
            agentIDs: [],
            rootIDs: rootIDs,
            entryFilename: entryFilename,
            parseDiagnostics: []
        )
    }

    func testAccessWithoutBookmarkStorageThrowsUnavailable() {
        let manager = DocumentManager(bookmarks: nil)
        let skill = makeSnapshot(path: "/tmp/skills/demo", rootIDs: ["root-1"])

        XCTAssertThrowsError(
            try manager.resolveDocumentAccess(for: skill, authorizedRoots: [])
        ) { error in
            XCTAssertEqual(
                error as? DocumentAccessError,
                .authorizationStorageUnavailable
            )
            // W1 regression: the message must come from the localized mapping,
            // not the raw enum case name (previously the view matched a
            // different error type and fell through to String(describing:)).
            XCTAssertFalse(error.localizedDescription.contains("authorizationStorageUnavailable"))
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
    }

    func testAccessWithoutAnyRootAssociationThrowsNoAuthorizedRoot() throws {
        let manager = DocumentManager(bookmarks: try makeStore())
        let skill = makeSnapshot(path: "/tmp/skills/demo", rootIDs: [])

        XCTAssertThrowsError(
            try manager.resolveDocumentAccess(for: skill, authorizedRoots: [])
        ) { error in
            XCTAssertEqual(error as? DocumentAccessError, .noAuthorizedRoot)
        }
    }

    func testAccessWithUnknownRootIDThrowsResolutionError() throws {
        let manager = DocumentManager(bookmarks: try makeStore())
        let skill = makeSnapshot(path: "/tmp/skills/demo", rootIDs: ["missing-root"])

        XCTAssertThrowsError(
            try manager.resolveDocumentAccess(for: skill, authorizedRoots: [])
        ) { error in
            XCTAssertEqual(error as? BookmarkStoreError, .rootNotFound("missing-root"))
        }
    }

    func testAccessRejectsSkillOutsideAuthorizedRoot() throws {
        let store = try makeStore()
        let root = try store.save(
            url: temporaryDirectory.appendingPathComponent("root"),
            kind: .custom
        )
        let manager = DocumentManager(bookmarks: store)
        let skill = makeSnapshot(
            path: "/outside/\(UUID().uuidString)/demo",
            rootIDs: [root.id]
        )
        let roots = [AuthorizedRootSnapshot(id: root.id, url: root.url, kind: .custom)]

        XCTAssertThrowsError(
            try manager.resolveDocumentAccess(for: skill, authorizedRoots: roots)
        ) { error in
            XCTAssertEqual(error as? DocumentAccessError, .noAuthorizedRoot)
        }
    }

    func testAccessRejectsResolvedTargetOutsideAuthorizedRoots() throws {
        let store = try makeStore()
        let root = try store.save(
            url: temporaryDirectory.appendingPathComponent("root"),
            kind: .custom
        )
        let manager = DocumentManager(bookmarks: store)
        let linkPath = root.url.appendingPathComponent("demo").path
        let skill = makeSnapshot(
            path: linkPath,
            rootIDs: [root.id],
            resolvedTarget: "/elsewhere/\(UUID().uuidString)/target"
        )
        let roots = [AuthorizedRootSnapshot(id: root.id, url: root.url, kind: .custom)]

        XCTAssertThrowsError(
            try manager.resolveDocumentAccess(for: skill, authorizedRoots: roots)
        ) { error in
            XCTAssertEqual(error as? DocumentAccessError, .noAuthorizedRoot)
        }
    }

    func testSuccessfulAccessBuildsRequestWithRootURLs() throws {
        let store = try makeStore()
        let root = try store.save(
            url: temporaryDirectory.appendingPathComponent("root"),
            kind: .custom
        )
        let manager = DocumentManager(bookmarks: store)
        let skillPath = root.url.appendingPathComponent("demo").path
        let skill = makeSnapshot(path: skillPath, rootIDs: [root.id])
        let roots = [AuthorizedRootSnapshot(id: root.id, url: root.url, kind: .custom)]

        let access = try manager.resolveDocumentAccess(for: skill, authorizedRoots: roots)
        defer { access.leases.forEach { $0.close() } }

        XCTAssertEqual(access.request.installationURL.path, skillPath)
        XCTAssertEqual(access.request.entryFilename, "SKILL.md")
        XCTAssertEqual(access.request.authorizedRootURLs.map(\.path), [root.url.path])
        XCTAssertNil(access.request.resolvedTargetURL)
    }

    func testLoadDocumentReadsSkillInsideAuthorizedRoot() async throws {
        let rootURL = temporaryDirectory.appendingPathComponent("root")
        let skillURL = rootURL.appendingPathComponent("demo")
        try FileManager.default.createDirectory(
            at: skillURL,
            withIntermediateDirectories: true
        )
        let source = "---\nname: demo\ndescription: test skill\n---\n# Demo\n"
        try source.write(
            to: skillURL.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )

        let store = try makeStore()
        let root = try store.save(url: rootURL, kind: .custom)
        let manager = DocumentManager(bookmarks: store)
        let skill = makeSnapshot(path: skillURL.path, rootIDs: [root.id])
        let roots = [AuthorizedRootSnapshot(id: root.id, url: root.url, kind: .custom)]

        let document = try await manager.loadDocument(for: skill, authorizedRoots: roots)

        XCTAssertEqual(document.source, source)
        XCTAssertEqual(document.fileURL.lastPathComponent, "SKILL.md")
    }
}

private final class PathEncodingBookmarkAdapter: BookmarkDataCreating, @unchecked Sendable {
    func createBookmarkData(for url: URL) throws -> Data {
        Data(url.path.utf8)
    }

    func resolveBookmarkData(_ data: Data) throws -> BookmarkResolution {
        BookmarkResolution(
            url: URL(fileURLWithPath: String(decoding: data, as: UTF8.self)),
            isStale: false
        )
    }

    func startAccessing(_ url: URL) -> Bool { true }
    func stopAccessing(_ url: URL) {}
}
