import Foundation
import XCTest
@testable import SkillSelectorCore

final class RefreshHistoryStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func tearDown() {
        if let suite {
            defaults?.removePersistentDomain(forName: suite)
        }
        defaults = nil
        suite = nil
        super.tearDown()
    }

    private func makeDefaults() -> UserDefaults {
        suite = "RefreshHistoryStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        return defaults
    }

    private func entry(
        added: [String] = [],
        changed: [String] = [],
        removed: [String] = []
    ) -> RefreshChangeEntry {
        RefreshChangeEntry(
            addedPaths: added,
            changedPaths: changed,
            removedPaths: removed
        )
    }

    func testEmptyStoreReadsAsNoHistory() throws {
        let store = UserDefaultsRefreshHistoryStore(defaults: makeDefaults())
        XCTAssertTrue(try store.entries().isEmpty)
    }

    func testRecordKeepsNewestFirst() throws {
        let store = UserDefaultsRefreshHistoryStore(defaults: makeDefaults())
        try store.record(entry(added: ["/old"]))
        try store.record(entry(added: ["/new"]))

        let entries = try store.entries()
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].addedPaths, ["/new"])
        XCTAssertEqual(entries[1].addedPaths, ["/old"])
    }

    func testHistoryIsCapped() throws {
        let store = UserDefaultsRefreshHistoryStore(defaults: makeDefaults())
        for index in 0..<(UserDefaultsRefreshHistoryStore.maximumEntries + 5) {
            try store.record(entry(added: ["/skill-\(index)"]))
        }
        let entries = try store.entries()
        XCTAssertEqual(entries.count, UserDefaultsRefreshHistoryStore.maximumEntries)
        XCTAssertEqual(entries.first?.addedPaths, [
            "/skill-\(UserDefaultsRefreshHistoryStore.maximumEntries + 4)"
        ])
    }

    func testRemoveAllClearsHistory() throws {
        let store = UserDefaultsRefreshHistoryStore(defaults: makeDefaults())
        try store.record(entry(changed: ["/a"]))
        try store.removeAll()
        XCTAssertTrue(try store.entries().isEmpty)
    }

    func testCorruptedDataDegradesToEmpty() throws {
        let defaults = makeDefaults()
        // Unreadable payload must not crash the store.
        defaults.set(Data([0xFF, 0xFE, 0xFD]), forKey: "SkillSelector.refreshHistory")
        let store = UserDefaultsRefreshHistoryStore(defaults: defaults)
        XCTAssertTrue(try store.entries().isEmpty)
    }

    func testEntryFromSummaryCarriesPaths() {
        let summary = RefreshSummary(
            added: 1,
            changed: 2,
            removed: 1,
            addedPaths: ["/new"],
            changedPaths: ["/a", "/b"],
            removedPaths: ["/gone"]
        )
        let entry = RefreshChangeEntry(summary: summary)
        XCTAssertEqual(entry.addedPaths, ["/new"])
        XCTAssertEqual(entry.changedPaths, ["/a", "/b"])
        XCTAssertEqual(entry.removedPaths, ["/gone"])
    }

    func testSummaryIsEmptyWithoutChanges() {
        XCTAssertTrue(RefreshSummary(added: 0, changed: 0, removed: 0).isEmpty)
        XCTAssertFalse(
            RefreshSummary(added: 0, changed: 1, removed: 0, changedPaths: ["/a"]).isEmpty
        )
    }
}
