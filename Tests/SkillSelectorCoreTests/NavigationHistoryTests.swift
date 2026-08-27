import Foundation
import SwiftData
import XCTest
@testable import SkillSelector
@testable import SkillSelectorCore

/// Fine-grained navigation history (spec §1.4, AC-13..AC-18): sidebar
/// switches, detail openings and one search session per step; back/forward
/// traverse the stacks; the stack bottom is the launch default view.
@MainActor
final class NavigationHistoryTests: XCTestCase {
    func testSidebarSwitchesRecordAndBackTraverses() throws {
        // AC-13: 全局 → 重复 → 项目 → 后退 → 后退,回到全局.
        let model = try makeModel()
        model.recordNavigation(.sidebar(.all)) // seed (stack bottom)
        model.recordNavigation(.sidebar(.global))
        model.recordNavigation(.sidebar(.duplicates))
        model.recordNavigation(.sidebar(.project(rootID: "p1")))

        XCTAssertEqual(model.backEntries.count, 4)
        XCTAssertEqual(model.goBack()?.sidebarDestination, .duplicates)
        XCTAssertEqual(model.goBack()?.sidebarDestination, .global)
        // Back once more reaches the stack bottom (the launch default).
        XCTAssertEqual(model.goBack()?.sidebarDestination, .all)
        // AC-16: at the bottom, back returns nil → caller restores default.
        XCTAssertNil(model.goBack())
    }

    func testDetailPushesAndBackReturnsToTheList() throws {
        // AC-14: 点进详情 → 后退,回到列表.
        let model = try makeModel()
        model.recordNavigation(.sidebar(.all))
        model.recordNavigation(.skillDetail(SkillSelection(path: "/a/demo")))

        XCTAssertEqual(model.backEntries.count, 2)
        let restored = model.goBack()
        XCTAssertEqual(restored?.sidebarDestination, .all)
        XCTAssertNil(restored?.skillSelection)
    }

    func testSearchRecordsOneEntryAndRewritesInPlace() throws {
        // AC-15: 输入 a → ab → abc 只占一个历史槽;关闭/后退一步即回搜索前.
        let model = try makeModel()
        model.recordNavigation(.sidebar(.all))
        model.recordNavigation(.search("a"))
        model.recordNavigation(.search("ab"))
        model.recordNavigation(.search("abc"))

        XCTAssertEqual(model.backEntries.count, 2, "search word changes must not push")
        XCTAssertEqual(model.backEntries.last, .search("abc"))
        // One back from the search state lands on the pre-search state.
        XCTAssertEqual(model.goBack()?.sidebarDestination, .all)
        XCTAssertNil(model.goBack())
    }

    func testClickingSearchResultThenBackSkipsIntermediateWords() throws {
        // AC-15 end-to-end: typing → click result (session ends) → back once
        // lands on the pre-search state, not the intermediate words.
        let model = try makeModel()
        model.recordNavigation(.sidebar(.all))
        model.recordNavigation(.search("a"))
        model.recordNavigation(.search("abc"))
        model.endSearchIfNeeded() // clicking a result ends the session
        model.recordNavigation(.skillDetail(SkillSelection(path: "/a/demo")))

        XCTAssertEqual(model.backEntries.count, 2)
        XCTAssertEqual(model.goBack()?.sidebarDestination, .all)
        XCTAssertNil(model.goBack())
    }

    func testDismissingSearchEndsTheSession() throws {
        let model = try makeModel()
        model.recordNavigation(.sidebar(.all))
        model.recordNavigation(.search("abc"))
        XCTAssertEqual(model.backEntries.count, 2)

        // Closing the field (with or without words) removes the entry.
        model.endSearchIfNeeded()
        XCTAssertEqual(model.backEntries.count, 1)
        XCTAssertEqual(model.backEntries.last, .sidebar(.all))
        XCTAssertNil(model.goBack())
    }

    func testForwardRevisitsAfterBack() throws {
        // AC-18: 后退后前进,回到后退前的状态.
        let model = try makeModel()
        model.recordNavigation(.sidebar(.all))
        model.recordNavigation(.sidebar(.global))
        model.recordNavigation(.sidebar(.duplicates))

        XCTAssertEqual(model.goBack()?.sidebarDestination, .global)
        XCTAssertEqual(model.canGoForward, true)
        XCTAssertEqual(model.goForward()?.sidebarDestination, .duplicates)
        XCTAssertEqual(model.canGoForward, false)
        XCTAssertEqual(model.goBack()?.sidebarDestination, .global)
        XCTAssertEqual(model.goForward()?.sidebarDestination, .duplicates)
    }

    func testNewNavigationClearsForwardHistory() throws {
        let model = try makeModel()
        model.recordNavigation(.sidebar(.all))
        model.recordNavigation(.sidebar(.global))
        model.recordNavigation(.sidebar(.duplicates))
        _ = model.goBack()
        XCTAssertTrue(model.canGoForward)

        // A fresh navigation discards the forward stack.
        model.recordNavigation(.sidebar(.project(rootID: "p1")))
        XCTAssertFalse(model.canGoForward)
        XCTAssertEqual(model.backEntries.last, .sidebar(.project(rootID: "p1")))
    }

    /// A very long session must not grow the back stack without bound: the
    /// stack is capped while the bottom seed (the launch default view) is
    /// preserved, so back still bottoms out on the default destination.
    func testBackStackIsCappedWhilePreservingTheSeed() throws {
        let model = try makeModel()
        model.recordNavigation(.sidebar(.all)) // seed (stack bottom)
        for index in 1...250 {
            model.recordNavigation(.sidebar(.project(rootID: "p\(index)")))
        }

        XCTAssertEqual(model.backEntries.count, 200, "stack must be capped")
        XCTAssertEqual(model.backEntries.first?.sidebarDestination, .all)
        XCTAssertEqual(model.backEntries.last?.sidebarDestination, .project(rootID: "p250"))
        // Traversal still bottoms out at the seed (goBack needs ≥2 entries,
        // so stop before the seed is the only element left).
        while model.backEntries.count > 1 {
            _ = model.goBack()
        }
        XCTAssertEqual(model.backEntries.first?.sidebarDestination, .all)
    }

    // MARK: Fixtures

    private func makeModel(defaults: UserDefaults? = nil) throws -> AppModel {
        let suite = "NavigationHistoryTests-\(UUID().uuidString)"
        let isolatedDefaults = defaults ?? UserDefaults(suiteName: suite)!
        if defaults == nil {
            isolatedDefaults.removePersistentDomain(forName: suite)
        }
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: SkillRecord.self,
            AuthorizedRootRecord.self,
            configurations: configuration
        )
        let bookmarks = BookmarkStore(container: container, adapter: AppModelBookmarkAdapter())
        let index = SkillIndex(container: container)
        let registry = BuiltInAgentRegistry.make()
        let refresher = IndexRefresher(registry: registry, bookmarks: bookmarks, index: index)
        return AppModel(
            refresher: refresher,
            index: index,
            bookmarks: bookmarks,
            registry: registry,
            defaults: isolatedDefaults
        )
    }
}
