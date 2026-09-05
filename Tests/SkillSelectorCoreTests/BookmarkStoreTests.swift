import Foundation
import GRDB
import XCTest
@testable import SkillSelectorCore

final class BookmarkStoreTests: XCTestCase {
    func testSaveAndResolveRoundTripPreservesExplicitRootKind() throws {
        let adapter = BookmarkAdapterSpy()
        let store = try makeStore(adapter: adapter)
        let url = URL(fileURLWithPath: "/tmp/project/child")

        let saved = try store.save(url: url, kind: .project)
        let access = try store.resolve(id: saved.id)

        XCTAssertEqual(access.root.url, url.standardizedFileURL)
        XCTAssertEqual(access.root.kind, .project)
        XCTAssertEqual(try store.roots(), [access.root])
        XCTAssertEqual(adapter.createdURLs, [url.standardizedFileURL])
        access.lease.close()
        XCTAssertEqual(adapter.stoppedURLs, [url.standardizedFileURL])
    }

    func testStaleBookmarkRefreshesPersistedData() throws {
        let adapter = BookmarkAdapterSpy()
        let database = try makeDatabase()
        let store = BookmarkStore(database: database, adapter: adapter)
        let url = URL(fileURLWithPath: "/tmp/custom")
        let saved = try store.save(url: url, kind: .custom)
        adapter.nextResolutionIsStale = true

        let firstAccess = try store.resolve(id: saved.id)
        firstAccess.lease.close()
        let reloadedStore = BookmarkStore(database: database, adapter: adapter)
        let secondAccess = try reloadedStore.resolve(id: saved.id)
        secondAccess.lease.close()

        XCTAssertEqual(adapter.createdURLs, [url.standardizedFileURL, url.standardizedFileURL])
        XCTAssertEqual(adapter.resolvedData, [Data("bookmark-1".utf8), Data("bookmark-2".utf8)])
    }

    func testUnreadableBookmarkRebuildsFromRecordedPath() throws {
        let adapter = BookmarkAdapterSpy()
        let database = try makeDatabase()
        let store = BookmarkStore(database: database, adapter: adapter)
        let url = URL(fileURLWithPath: "/tmp/custom")
        let saved = try store.save(url: url, kind: .custom)
        adapter.nextResolutionFails = true

        let access = try store.resolve(id: saved.id)
        access.lease.close()

        XCTAssertEqual(access.root.url, url.standardizedFileURL)
        XCTAssertEqual(access.root.kind, .custom)
        // The failed bookmark was rebuilt from the recorded path and re-resolved.
        XCTAssertEqual(adapter.createdURLs, [url.standardizedFileURL, url.standardizedFileURL])
        XCTAssertEqual(adapter.resolvedData, [Data("bookmark-1".utf8), Data("bookmark-2".utf8)])
    }

    func testRootsThrowsForPersistedInvalidKind() throws {
        let database = try makeDatabase()
        var record = AuthorizedRootRecord(
            path: "/tmp/invalid",
            kind: .custom,
            bookmarkData: Data("invalid".utf8)
        )
        record.kindRawValue = "broader-root"
        try database.write { try record.upsert($0) }
        let store = BookmarkStore(database: database, adapter: BookmarkAdapterSpy())

        XCTAssertThrowsError(try store.roots()) { error in
            XCTAssertEqual(error as? BookmarkStoreError, .invalidRootKind("broader-root"))
        }
    }

    func testStaleBookmarkRejectsPathCollisionBeforeMutationOrAccess() throws {
        let adapter = BookmarkAdapterSpy()
        let database = try makeDatabase()
        let store = BookmarkStore(database: database, adapter: adapter)
        let first = try store.save(url: URL(fileURLWithPath: "/tmp/first"), kind: .project)
        _ = try store.save(url: URL(fileURLWithPath: "/tmp/second"), kind: .custom)
        adapter.nextResolutionIsStale = true

        XCTAssertThrowsError(try store.resolve(id: first.id)) { error in
            XCTAssertEqual(error as? BookmarkStoreError, .duplicateRootPath("/tmp/second"))
        }
        XCTAssertEqual(adapter.createdURLs.count, 2)
        XCTAssertTrue(adapter.startedURLs.isEmpty)
        XCTAssertEqual(try store.roots().map(\.url.path), ["/tmp/first", "/tmp/second"])
    }

    func testAccessLeaseClosesSuccessfulAccessExactlyOnce() throws {
        let adapter = BookmarkAdapterSpy()
        let store = try makeStore(adapter: adapter)
        let saved = try store.save(url: URL(fileURLWithPath: "/tmp/home"), kind: .home)

        let access = try store.resolve(id: saved.id)
        XCTAssertEqual(adapter.startedURLs.count, 1)

        access.lease.close()
        access.lease.close()

        XCTAssertEqual(adapter.stoppedURLs.count, 1)
    }

    func testFailedSecurityScopeStartDoesNotStop() throws {
        let adapter = BookmarkAdapterSpy()
        adapter.shouldStartAccess = false
        let store = try makeStore(adapter: adapter)
        let saved = try store.save(url: URL(fileURLWithPath: "/tmp/system"), kind: .system)

        let access = try store.resolve(id: saved.id)
        access.lease.close()

        XCTAssertTrue(adapter.stoppedURLs.isEmpty)
        XCTAssertEqual(access.root.kind, .system)
    }

    func testRevokeClosesActiveAccessAndRemovesPersistedBookmark() throws {
        let adapter = BookmarkAdapterSpy()
        let store = try makeStore(adapter: adapter)
        let saved = try store.save(url: URL(fileURLWithPath: "/tmp/project"), kind: .project)
        let access = try store.resolve(id: saved.id)

        try store.revoke(id: saved.id)

        XCTAssertEqual(adapter.stoppedURLs, [saved.url])
        XCTAssertTrue(try store.roots().isEmpty)
        access.lease.close()
        XCTAssertEqual(adapter.stoppedURLs, [saved.url])
        XCTAssertThrowsError(try store.resolve(id: saved.id)) { error in
            XCTAssertEqual(error as? BookmarkStoreError, .rootNotFound(saved.id))
        }
    }

    func testDroppingAccessStillClosesLeaseWithoutWaitingForRevoke() throws {
        let adapter = BookmarkAdapterSpy()
        let store = try makeStore(adapter: adapter)
        let saved = try store.save(url: URL(fileURLWithPath: "/tmp/project"), kind: .project)

        var access: AuthorizedRootAccess? = try store.resolve(id: saved.id)
        XCTAssertNotNil(access)
        access = nil

        XCTAssertEqual(adapter.stoppedURLs, [saved.url])
    }

    private func makeStore(adapter: BookmarkAdapterSpy) throws -> BookmarkStore {
        BookmarkStore(database: try makeDatabase(), adapter: adapter)
    }

    private func makeDatabase() throws -> DatabaseQueue {
        try SkillStore.inMemory()
    }
}

private final class BookmarkAdapterSpy: BookmarkDataCreating, @unchecked Sendable {
    var nextResolutionIsStale = false
    var nextResolutionFails = false
    var shouldStartAccess = true
    private(set) var createdURLs: [URL] = []
    private(set) var resolvedData: [Data] = []
    private(set) var startedURLs: [URL] = []
    private(set) var stoppedURLs: [URL] = []

    func createBookmarkData(for url: URL) throws -> Data {
        createdURLs.append(url)
        return Data("bookmark-\(createdURLs.count)".utf8)
    }

    func resolveBookmarkData(_ data: Data) throws -> BookmarkResolution {
        resolvedData.append(data)
        if nextResolutionFails {
            nextResolutionFails = false
            throw CocoaError(.fileReadCorruptFile)
        }
        let stale = nextResolutionIsStale
        nextResolutionIsStale = false
        let path = createdURLs.last?.path ?? "/tmp/unknown"
        return BookmarkResolution(url: URL(fileURLWithPath: path), isStale: stale)
    }

    func startAccessing(_ url: URL) -> Bool {
        startedURLs.append(url)
        return shouldStartAccess
    }

    func stopAccessing(_ url: URL) {
        stoppedURLs.append(url)
    }
}
