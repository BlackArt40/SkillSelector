import Foundation
import XCTest
@testable import SkillSelectorCore

final class DiagnosticStoreTests: XCTestCase {
    private let redactor = Redactor(
        homeDirectory: URL(fileURLWithPath: "/Users/alice")
    )

    func testRecordStoresRedactedEventInOrder() {
        let store = DiagnosticStore(capacity: 10)

        store.record(
            category: .scanning,
            code: "diagnostic.scanFailed",
            message: "failed at /Users/alice/.codex/skills",
            redactor: redactor
        )
        store.record(
            category: .operations,
            code: "plain-code",
            message: "no secrets here",
            redactor: redactor
        )

        let events = store.recent()
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].category, .scanning)
        XCTAssertEqual(events[0].code, "diagnostic.scanFailed")
        XCTAssertEqual(events[0].message, "failed at <home>/.codex/skills")
        XCTAssertEqual(events[1].category, .operations)
        XCTAssertEqual(events[1].message, "no secrets here")
    }

    func testCapacityEvictsOldestEvents() {
        let store = DiagnosticStore(capacity: 3)

        for index in 0..<5 {
            store.record(category: .persistence, code: "code-\(index)", message: "m\(index)")
        }

        let events = store.recent()
        XCTAssertEqual(events.map(\.code), ["code-2", "code-3", "code-4"])
    }

    func testCapacityIsClampedToAtLeastOne() {
        let store = DiagnosticStore(capacity: 0)

        store.record(category: .scanning, code: "first", message: "first")
        store.record(category: .scanning, code: "second", message: "second")

        XCTAssertEqual(store.recent().map(\.code), ["second"])
    }

    func testConcurrentRecordingKeepsCapacityBound() {
        let store = DiagnosticStore(capacity: 50)
        let iterations = 200

        DispatchQueue.concurrentPerform(iterations: iterations) { index in
            store.record(category: .operations, code: "code-\(index)", message: "m")
        }

        let events = store.recent()
        XCTAssertEqual(events.count, 50)
        XCTAssertEqual(Set(events.map(\.code)).count, events.count)
    }
}
