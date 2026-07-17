import Foundation
import SwiftData
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
        XCTAssertEqual(store.roots(), [access.root])
        XCTAssertEqual(adapter.createdURLs, [url.standardizedFileURL])
        access.lease.close()
        XCTAssertEqual(adapter.stoppedURLs, [url.standardizedFileURL])
    }

    func testStaleBookmarkRefreshesPersistedData() throws {
        let adapter = BookmarkAdapterSpy()
        let store = try makeStore(adapter: adapter)
        let url = URL(fileURLWithPath: "/tmp/custom")
        let saved = try store.save(url: url, kind: .custom)
        adapter.nextResolutionIsStale = true

        let firstAccess = try store.resolve(id: saved.id)
        firstAccess.lease.close()
        _ = try store.resolve(id: saved.id)

        XCTAssertEqual(adapter.createdURLs, [url.standardizedFileURL, url.standardizedFileURL])
        XCTAssertEqual(adapter.resolvedData, [Data("bookmark-1".utf8), Data("bookmark-2".utf8)])
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

    private func makeStore(adapter: BookmarkAdapterSpy) throws -> BookmarkStore {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: SkillRecord.self,
            AuthorizedRootRecord.self,
            configurations: configuration
        )
        return BookmarkStore(container: container, adapter: adapter)
    }
}

private final class BookmarkAdapterSpy: BookmarkDataCreating {
    var nextResolutionIsStale = false
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
