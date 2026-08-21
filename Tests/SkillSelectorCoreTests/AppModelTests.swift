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

    func testCheckEnvironmentOnLaunchAuthorizesInjectedHomeDirectory() async throws {
        let home = FileManager.default.temporaryDirectory
            .appending(path: "AppModelHome-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let model = makeModel(homeDirectory: home)

        await model.checkEnvironmentOnLaunch()

        XCTAssertEqual(
            model.authorizedRoots.first { $0.kind == .home }?.url.standardizedFileURL,
            home.standardizedFileURL
        )
    }

    /// The packaged builds that triggered this bug ran sandboxed, where
    /// `FileManager.default.homeDirectoryForCurrentUser` resolves to the app
    /// container rather than the user's home. A pre-fix build persisted that
    /// container path as the `.home` root, which scanned nothing and blocked
    /// the first-run guide. This test pins the cleanup and the deferral to
    /// the manual import path.
    func testSandboxedLaunchPurgesContainerHomeRootAndSkipsAutoAuthorization() async throws {
        let suite = "AppModelSandboxLaunch-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: SkillRecord.self,
            AuthorizedRootRecord.self,
            configurations: configuration
        )
        let bookmarks = BookmarkStore(container: container, adapter: AppModelBookmarkAdapter())
        // The pre-fix build recorded whatever homeDirectoryForCurrentUser
        // returned (the container path under sandbox; the real home in this
        // non-sandboxed test process — the same bogus-root shape).
        let staleRoot = try bookmarks.save(url: FileManager.default.homeDirectoryForCurrentUser, kind: .home)

        let home = FileManager.default.temporaryDirectory
            .appending(path: "AppModelSandboxHome-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let model = makeModel(
            defaults: defaults,
            homeDirectory: home,
            container: container,
            bookmarks: bookmarks
        )
        model.environmentIsSandboxed = true

        await model.checkEnvironmentOnLaunch()

        // The stale container home root is gone and nothing was authorized
        // automatically under sandbox.
        XCTAssertFalse(model.authorizedRoots.contains { $0.id == staleRoot.id })
        XCTAssertTrue(model.authorizedRoots.isEmpty)
        // With authorization cleared, the first-run guide can show again.
        XCTAssertTrue(model.shouldShowOnboarding)
    }

    func testRealUserHomeDirectoryMatchesFileManagerOutsideSandbox() {
        XCTAssertEqual(
            AppModel.realUserHomeDirectory().standardizedFileURL,
            FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        )
    }

    func testOnboardingPresentedOnlyWhenNotShownAndUnauthorized() {
        let suite = "AppModelOnboardingTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = makeModel(defaults: defaults)

        XCTAssertTrue(model.shouldShowOnboarding)
        model.presentOnboardingIfNeeded()
        XCTAssertTrue(model.showsOnboarding)

        model.dismissOnboarding()
        XCTAssertFalse(model.showsOnboarding)
        XCTAssertFalse(model.shouldShowOnboarding)
        XCTAssertTrue(defaults.bool(forKey: "SkillSelector.onboardingShown"))

        // Dismissing once means the guide never returns on later launches.
        model.presentOnboardingIfNeeded()
        XCTAssertFalse(model.showsOnboarding)
    }

    func testOnboardingSuppressedWhenRootsAlreadyAuthorized() async {
        let model = makeModel()

        await model.authorize(FileManager.default.homeDirectoryForCurrentUser, as: .home)

        XCTAssertFalse(model.shouldShowOnboarding)
        model.presentOnboardingIfNeeded()
        XCTAssertFalse(model.showsOnboarding)
    }

    func testLegacyAgentManualEnablePersistsAndIgnoresNonLegacyAgents() {
        let suite = "AppModelLegacyAgentTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = makeModel(defaults: defaults)

        XCTAssertFalse(model.manuallyEnabledAgentIDs.contains("roo-code"))
        XCTAssertTrue(model.legacyAgentDefinitions.contains { $0.id == "roo-code" })

        model.setLegacyAgent("roo-code", enabled: true)
        XCTAssertTrue(model.manuallyEnabledAgentIDs.contains("roo-code"))
        XCTAssertEqual(
            defaults.stringArray(forKey: "SkillSelector.manuallyEnabledAgents"),
            ["roo-code"]
        )

        // Non-legacy agents cannot be force-visible through this path.
        model.setLegacyAgent("codex", enabled: true)
        XCTAssertFalse(model.manuallyEnabledAgentIDs.contains("codex"))

        model.setLegacyAgent("roo-code", enabled: false)
        XCTAssertFalse(model.manuallyEnabledAgentIDs.contains("roo-code"))
        XCTAssertEqual(defaults.stringArray(forKey: "SkillSelector.manuallyEnabledAgents"), [])
    }

    private func makeModel(
        defaults: UserDefaults? = nil,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        container: ModelContainer? = nil,
        bookmarks: BookmarkStore? = nil
    ) -> AppModel {
        let suite = "AppModelGeneralTests-\(UUID().uuidString)"
        let isolatedDefaults = defaults ?? UserDefaults(suiteName: suite)!
        if defaults == nil {
            isolatedDefaults.removePersistentDomain(forName: suite)
        }
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = container ?? (try! ModelContainer(
            for: SkillRecord.self,
            AuthorizedRootRecord.self,
            configurations: configuration
        ))
        let index = SkillIndex(container: container)
        let bookmarks = bookmarks ?? BookmarkStore(container: container, adapter: AppModelBookmarkAdapter())
        let registry = BuiltInAgentRegistry.make()
        let refresher = IndexRefresher(registry: registry, bookmarks: bookmarks, index: index)
        return AppModel(
            refresher: refresher,
            index: index,
            bookmarks: bookmarks,
            registry: registry,
            defaults: isolatedDefaults,
            homeDirectory: homeDirectory
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
        let bookmarks = BookmarkStore(container: container, adapter: AppModelBookmarkAdapter())
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
        let bookmarks = BookmarkStore(container: container, adapter: AppModelBookmarkAdapter())
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

    func testImportCustomAgentsSkipsBuiltInIDs() throws {
        // Audit R5: a hand-edited transfer file must not be able to overwrite
        // a built-in Agent (merge() replaces definitions by id).
        let (model, store) = try makeValidationModel()
        let builtIn = try XCTUnwrap(BuiltInAgentRegistry.make().definitions.first)
        let transferFile = FileManager.default.temporaryDirectory
            .appending(path: "import-skip-builtin-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: transferFile) }
        try CustomAgentTransfer().archive([
            AgentDefinition(
                id: builtIn.id,
                displayName: "Evil Override",
                globalRoots: ["/tmp/evil"],
                projectPatterns: [],
                entryFilename: "SKILL.md"
            ),
        ]).write(to: transferFile)

        let result = try model.importCustomAgents(from: transferFile)

        XCTAssertEqual(result.imported, 0)
        XCTAssertEqual(result.skipped, 1)
        XCTAssertTrue(store.values.isEmpty)
        // The registry still serves the built-in definition.
        XCTAssertEqual(model.registry.definition(id: builtIn.id)?.displayName, builtIn.displayName)
    }

    func testImportCustomAgentsRejectsOversizedFile() throws {
        // Audit F-10: a giant transfer file is rejected before any read.
        let (model, _) = try makeValidationModel()
        let transferFile = FileManager.default.temporaryDirectory
            .appending(path: "import-oversize-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: transferFile) }
        let padding = String(repeating: "x", count: AppModel.maximumImportBytes + 1)
        try Data(padding.utf8).write(to: transferFile)

        XCTAssertThrowsError(try model.importCustomAgents(from: transferFile)) { error in
            guard case CustomAgentTransferError.unreadableFile = error else {
                return XCTFail("Expected unreadableFile, got \(error)")
            }
        }
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
        let bookmarks = BookmarkStore(container: container, adapter: AppModelBookmarkAdapter())
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

/// Path-encoding bookmark adapter: creating a security-scoped bookmark
/// requires the app-scope entitlement, which a bare `swift test` process
/// does not have. The tests exercise AppModel behavior around authorize /
/// purge / onboarding, not the bookmark format, so a round-trip adapter
/// keeps them hermetic (same pattern as FixtureBookmarkAdapter).
private final class AppModelBookmarkAdapter: BookmarkDataCreating, @unchecked Sendable {
    func createBookmarkData(for url: URL) throws -> Data { Data(url.path.utf8) }

    func resolveBookmarkData(_ data: Data) throws -> BookmarkResolution {
        BookmarkResolution(
            url: URL(fileURLWithPath: String(decoding: data, as: UTF8.self)),
            isStale: false
        )
    }

    func startAccessing(_ url: URL) -> Bool { true }

    func stopAccessing(_ url: URL) {}
}
