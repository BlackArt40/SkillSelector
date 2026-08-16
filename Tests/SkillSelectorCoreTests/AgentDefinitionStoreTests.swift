import Foundation
import XCTest
@testable import SkillSelectorCore

final class AgentDefinitionStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "AgentDefinitionStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeStore() -> UserDefaultsAgentDefinitionStore {
        UserDefaultsAgentDefinitionStore(defaults: defaults)
    }

    private func makeDefinition(id: String, displayName: String = "Agent") -> AgentDefinition {
        AgentDefinition(
            id: id,
            displayName: displayName,
            globalRoots: ["~/.\(id)/skills"],
            projectPatterns: [".\(id)/skills"]
        )
    }

    func testDefinitionsEmptyWhenNothingPersisted() throws {
        XCTAssertEqual(try makeStore().definitions(), [])
    }

    func testInsertPersistsSortedByIdentifier() throws {
        let store = makeStore()

        try store.insert(makeDefinition(id: "zeta"))
        try store.insert(makeDefinition(id: "alpha"))
        try store.insert(makeDefinition(id: "mid"))

        XCTAssertEqual(try store.definitions().map(\.id), ["alpha", "mid", "zeta"])
    }

    func testInsertRejectsDuplicateIdentifier() throws {
        let store = makeStore()
        try store.insert(makeDefinition(id: "codex"))

        XCTAssertThrowsError(try store.insert(makeDefinition(id: "codex", displayName: "Other"))) { error in
            XCTAssertEqual(
                error as? AgentDefinitionStoreError,
                .duplicateIdentifier("codex")
            )
        }
        XCTAssertEqual(try store.definitions().count, 1)
    }

    func testSaveUpsertsExistingIdentifier() throws {
        let store = makeStore()
        try store.save(makeDefinition(id: "codex", displayName: "Original"))

        try store.save(makeDefinition(id: "codex", displayName: "Updated"))

        let definitions = try store.definitions()
        XCTAssertEqual(definitions.count, 1)
        XCTAssertEqual(definitions[0].displayName, "Updated")
    }

    func testSaveAppendsNewIdentifier() throws {
        let store = makeStore()
        try store.save(makeDefinition(id: "alpha"))
        try store.save(makeDefinition(id: "beta"))

        XCTAssertEqual(try store.definitions().map(\.id), ["alpha", "beta"])
    }

    func testRemoveDeletesOnlyMatchingIdentifier() throws {
        let store = makeStore()
        try store.insert(makeDefinition(id: "alpha"))
        try store.insert(makeDefinition(id: "beta"))

        try store.remove(id: "alpha")

        XCTAssertEqual(try store.definitions().map(\.id), ["beta"])
    }

    func testRemoveUnknownIdentifierIsANoOp() throws {
        let store = makeStore()
        try store.insert(makeDefinition(id: "alpha"))

        try store.remove(id: "missing")

        XCTAssertEqual(try store.definitions().map(\.id), ["alpha"])
    }

    func testDefinitionsRoundTripAcrossStoreInstances() throws {
        try makeStore().insert(makeDefinition(id: "codex", displayName: "Codex"))

        let reloaded = makeStore()
        XCTAssertEqual(try reloaded.definitions(), [makeDefinition(id: "codex", displayName: "Codex")])
    }

    func testDefinitionsThrowsForCorruptPersistedData() {
        defaults.set(Data("not json".utf8), forKey: "SkillSelector.customAgentDefinitions")

        XCTAssertThrowsError(try makeStore().definitions())
    }
}
