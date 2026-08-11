import Foundation
@testable import SkillSelector
import SkillSelectorCore
import SwiftData
import XCTest

@MainActor
final class AppModelTests: XCTestCase {
    func testAutoScanHomeDefaultsEnabledAndPersists() {
        let suite = "AppModelAutoScanTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = makeModel(defaults: defaults)

        XCTAssertTrue(model.autoScanHome)
        model.autoScanHome = false
        XCTAssertFalse(model.autoScanHome)
        XCTAssertFalse(defaults.bool(forKey: "SkillSelector.autoScanHome"))
    }

    func testCheckEnvironmentOnLaunchAuthorizesHomeWhenAutoScanEnabled() async throws {
        let model = makeModel()

        await model.checkEnvironmentOnLaunch()

        let homeRoot = model.authorizedRoots.first { $0.kind == .home }
        XCTAssertEqual(homeRoot?.url.standardizedFileURL, FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL)
    }

    func testCheckEnvironmentOnLaunchSkipsAuthorizationWhenAutoScanDisabled() async throws {
        let model = makeModel()
        model.autoScanHome = false

        await model.checkEnvironmentOnLaunch()

        XCTAssertTrue(model.authorizedRoots.isEmpty)
    }

    func testAuthorizingSecondHomeRootReusesExistingRoot() async throws {
        let model = makeModel()

        await model.authorize(FileManager.default.homeDirectoryForCurrentUser, as: .home)
        XCTAssertEqual(model.authorizedRoots.filter { $0.kind == .home }.count, 1)

        // A second .home import must not create another Home Directory entry.
        await model.authorize(URL(fileURLWithPath: "/tmp/other-home"), as: .home)
        XCTAssertEqual(model.authorizedRoots.filter { $0.kind == .home }.count, 1)
        XCTAssertEqual(
            model.authorizedRoots.first { $0.kind == .home }?.url.standardizedFileURL,
            FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        )
    }

    private func makeModel(defaults: UserDefaults? = nil) -> AppModel {
        let suite = "AppModelGeneralTests-\(UUID().uuidString)"
        let isolatedDefaults = defaults ?? UserDefaults(suiteName: suite)!
        if defaults == nil {
            isolatedDefaults.removePersistentDomain(forName: suite)
        }
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try! ModelContainer(
            for: SkillRecord.self,
            AuthorizedRootRecord.self,
            configurations: configuration
        )
        let index = SkillIndex(container: container)
        let bookmarks = BookmarkStore(container: container)
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

    func testEditingCustomAgentRetainsIdentifierAndUpdatesDefinition() throws {
        let suite = "AppModelCustomAgentTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: SkillRecord.self,
            AuthorizedRootRecord.self,
            configurations: configuration
        )
        let index = SkillIndex(container: container)
        let registry = BuiltInAgentRegistry.make()
        let bookmarks = BookmarkStore(container: container)
        let refresher = IndexRefresher(registry: registry, bookmarks: bookmarks, index: index)
        let store = RecordingAgentDefinitionStore()
        let model = AppModel(
            refresher: refresher,
            index: index,
            registry: registry,
            defaults: defaults,
            customAgentStore: store
        )

        try model.saveCustomAgent(
            displayName: "Original",
            globalRoots: ["~/.original/skills"],
            projectPatterns: [".original/skills"],
            entryFilename: "AGENT.md"
        )
        let created = try XCTUnwrap(model.customAgentDefinitions.first)

        var editor = CustomAgentEditorState()
        editor.beginEditing(created)
        XCTAssertEqual(editor.selectedAgentID, created.id)
        XCTAssertEqual(editor.agentName, "Original")
        XCTAssertEqual(editor.globalRoots, "~/.original/skills")
        XCTAssertEqual(editor.projectPatterns, ".original/skills")
        XCTAssertEqual(editor.entryFilename, "AGENT.md")
        editor.agentName = "Renamed"
        editor.globalRoots = "~/.renamed/skills"
        editor.projectPatterns = ".renamed/skills"
        editor.entryFilename = "CUSTOM.md"
        try editor.save(using: model)

        let edited = try XCTUnwrap(model.customAgentDefinitions.first)
        XCTAssertEqual(edited.id, created.id)
        XCTAssertEqual(edited.displayName, "Renamed")
        XCTAssertEqual(edited.entryFilename, "CUSTOM.md")
        XCTAssertEqual(store.insertedIDs, [created.id])
        XCTAssertEqual(store.savedIDs, [created.id])
        XCTAssertNil(editor.selectedAgentID)
        XCTAssertEqual(editor.entryFilename, "SKILL.md")
    }

    func testDeletingCurrentlyEditedCustomAgentResetsEditorState() throws {
        let suite = "AppModelCustomAgentDeleteTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: SkillRecord.self,
            AuthorizedRootRecord.self,
            configurations: configuration
        )
        let index = SkillIndex(container: container)
        let registry = BuiltInAgentRegistry.make()
        let bookmarks = BookmarkStore(container: container)
        let refresher = IndexRefresher(registry: registry, bookmarks: bookmarks, index: index)
        let store = RecordingAgentDefinitionStore()
        let model = AppModel(
            refresher: refresher,
            index: index,
            registry: registry,
            defaults: defaults,
            customAgentStore: store
        )
        try model.saveCustomAgent(
            displayName: "To Delete",
            globalRoots: ["~/.delete/skills"],
            projectPatterns: [".delete/skills"],
            entryFilename: "AGENT.md"
        )
        let definition = try XCTUnwrap(model.customAgentDefinitions.first)
        var editor = CustomAgentEditorState()
        editor.beginEditing(definition)

        try model.removeCustomAgent(id: definition.id)
        editor.resetIfEditing(removedID: definition.id)

        XCTAssertTrue(model.customAgentDefinitions.isEmpty)
        XCTAssertNil(editor.selectedAgentID)
        XCTAssertEqual(editor.agentName, "")
        XCTAssertEqual(editor.globalRoots, "")
        XCTAssertEqual(editor.projectPatterns, "")
        XCTAssertEqual(editor.entryFilename, "SKILL.md")
    }

    func testCustomAgentValidationRejectsInvalidPathsAndEntryFilenames() throws {
        let (model, store) = try makeValidationModel()

        // entryFilename with path separator is rejected
        XCTAssertThrowsError(try model.saveCustomAgent(
            displayName: "Bad Entry",
            globalRoots: ["~/.skills"],
            projectPatterns: [".skills"],
            entryFilename: "sub/dir/SKILL.md"
        )) { error in
            guard case .invalidEntryFilename = error as? AppModelValidationError else {
                return XCTFail("Expected invalidEntryFilename, got \(error)")
            }
        }

        // entryFilename with backslash is rejected
        XCTAssertThrowsError(try model.saveCustomAgent(
            displayName: "Bad Entry",
            globalRoots: ["~/.skills"],
            projectPatterns: [".skills"],
            entryFilename: "SKILL\\.md"
        )) { error in
            guard case .invalidEntryFilename = error as? AppModelValidationError else {
                return XCTFail("Expected invalidEntryFilename, got \(error)")
            }
        }

        // root-only "/" is rejected
        XCTAssertThrowsError(try model.saveCustomAgent(
            displayName: "Bad Root",
            globalRoots: ["/"],
            projectPatterns: [".skills"],
            entryFilename: "SKILL.md"
        )) { error in
            guard case .invalidPathTemplate = error as? AppModelValidationError else {
                return XCTFail("Expected invalidPathTemplate, got \(error)")
            }
        }

        // bare "~" is rejected
        XCTAssertThrowsError(try model.saveCustomAgent(
            displayName: "Bad Root",
            globalRoots: ["~"],
            projectPatterns: [".skills"],
            entryFilename: "SKILL.md"
        )) { error in
            guard case .invalidPathTemplate = error as? AppModelValidationError else {
                return XCTFail("Expected invalidPathTemplate, got \(error)")
            }
        }

        // pure wildcard "*" is rejected
        XCTAssertThrowsError(try model.saveCustomAgent(
            displayName: "Bad Root",
            globalRoots: ["*"],
            projectPatterns: [".skills"],
            entryFilename: "SKILL.md"
        )) { error in
            guard case .invalidPathTemplate = error as? AppModelValidationError else {
                return XCTFail("Expected invalidPathTemplate, got \(error)")
            }
        }

        // nothing was persisted despite multiple attempts
        XCTAssertTrue(store.values.isEmpty)
    }

    private func makeValidationModel() throws -> (AppModel, RecordingAgentDefinitionStore) {
        let suite = "AppModelValidationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: SkillRecord.self,
            AuthorizedRootRecord.self,
            configurations: configuration
        )
        let index = SkillIndex(container: container)
        let registry = BuiltInAgentRegistry.make()
        let bookmarks = BookmarkStore(container: container)
        let refresher = IndexRefresher(registry: registry, bookmarks: bookmarks, index: index)
        let store = RecordingAgentDefinitionStore()
        let model = AppModel(
            refresher: refresher,
            index: index,
            registry: registry,
            defaults: defaults,
            customAgentStore: store
        )
        return (model, store)
    }
}

private final class RecordingAgentDefinitionStore: AgentDefinitionStoring, @unchecked Sendable {
    private(set) var values: [AgentDefinition] = []
    private(set) var insertedIDs: [String] = []
    private(set) var savedIDs: [String] = []

    func definitions() throws -> [AgentDefinition] { values }

    func insert(_ definition: AgentDefinition) throws {
        insertedIDs.append(definition.id)
        values.append(definition)
    }

    func save(_ definition: AgentDefinition) throws {
        savedIDs.append(definition.id)
        if let index = values.firstIndex(where: { $0.id == definition.id }) {
            values[index] = definition
        } else {
            values.append(definition)
        }
    }

    func remove(id: String) throws { values.removeAll { $0.id == id } }
}
