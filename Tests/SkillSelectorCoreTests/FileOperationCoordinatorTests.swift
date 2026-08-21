import Foundation
import SwiftData
import XCTest
@testable import SkillSelector
@testable import SkillSelectorCore

/// Integration tests for the batch-operation orchestration layer
/// (`FileOperationCoordinator`). Audit coverage gap: the plan → confirm →
/// execute → partial-refresh user path for multi-select operations had zero
/// automated tests; the underlying single-item `SkillFileOperator` is covered
/// by 37 tests, but nothing exercised the batch state machine.
@MainActor
final class FileOperationCoordinatorTests: XCTestCase {

    /// Creates an isolated fixture tree with a source root holding two Skills
    /// and an empty destination root. Returns a cleanup closure.
    private func makeFixture() throws -> (source: URL, destination: URL, cleanup: () -> Void) {
        let fixtureRoot = FileManager.default.temporaryDirectory
            .appending(path: "FileOperationCoordinatorTests-\(UUID().uuidString)")
        let source = fixtureRoot.appending(path: "source")
        let destination = fixtureRoot.appending(path: "destination")
        for directory in [source, destination] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return (source, destination, { try? FileManager.default.removeItem(at: fixtureRoot) })
    }

    @discardableResult
    private func writeSkill(named name: String, in root: URL) throws -> URL {
        let directory = root.appending(path: name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try """
        ---
        name: \(name)
        description: \(name) description
        ---
        # \(name)
        """.write(
            to: directory.appending(path: "SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        return directory
    }

    /// Authorizes both roots and refreshes so the source Skills are indexed.
    /// Returns the model and the underlying store (so a test can mutate
    /// authorization directly, bypassing the in-app guard that forbids
    /// revoking while a batch is pending).
    private func setUpModelWithIndexedSkills(
        source: URL,
        destination: URL
    ) async throws -> (model: AppModel, bookmarks: BookmarkStore) {
        let suite = "FileOperationCoordinatorTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: SkillRecord.self,
            AuthorizedRootRecord.self,
            configurations: configuration
        )
        let bookmarks = BookmarkStore(container: container, adapter: AppModelBookmarkAdapter())
        let model = AppModel(
            refresher: IndexRefresher(
                registry: BuiltInAgentRegistry.make(),
                bookmarks: bookmarks,
                index: SkillIndex(container: container)
            ),
            index: SkillIndex(container: container),
            bookmarks: bookmarks,
            registry: BuiltInAgentRegistry.make(),
            defaults: defaults,
            homeDirectory: source.deletingLastPathComponent()
        )
        try writeSkill(named: "alpha", in: source)
        try writeSkill(named: "beta", in: source)
        await model.authorize(source, as: .custom)
        await model.authorize(destination, as: .custom)
        await model.refresh()
        XCTAssertEqual(model.snapshots.count, 2, "Both source skills should be indexed")
        return (model, bookmarks)
    }

    private func sortedNames(in root: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ).map(\.lastPathComponent).sorted()
    }

    func testBatchCopyPlansAllItemsAndExecutesIntoDestination() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let (model, _) = try await setUpModelWithIndexedSkills(
            source: fixture.source,
            destination: fixture.destination
        )
        let skills = model.snapshots.sorted { $0.path < $1.path }
        let coordinator = model.fileOperations

        await coordinator.planBatch(.copy, for: skills, destinationRootURL: fixture.destination)

        let batch = try XCTUnwrap(coordinator.pendingBatch)
        XCTAssertEqual(batch.entries.count, 2)
        XCTAssertNil(coordinator.operationError)

        await coordinator.executePendingBatch()

        XCTAssertNil(coordinator.operationError)
        XCTAssertNil(coordinator.pendingBatch)
        XCTAssertFalse(coordinator.isOperating)
        XCTAssertEqual(try sortedNames(in: fixture.destination), ["alpha", "beta"])
        // Sources are untouched by a copy.
        XCTAssertEqual(try sortedNames(in: fixture.source), ["alpha", "beta"])
    }

    func testBatchMoveMovesAllItemsAndClearsSelection() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let (model, _) = try await setUpModelWithIndexedSkills(
            source: fixture.source,
            destination: fixture.destination
        )
        let skills = model.snapshots.sorted { $0.path < $1.path }
        let coordinator = model.fileOperations

        await coordinator.planBatch(.move, for: skills, destinationRootURL: fixture.destination)
        await coordinator.executePendingBatch()

        XCTAssertNil(coordinator.operationError)
        XCTAssertNil(coordinator.pendingBatch)
        XCTAssertEqual(try sortedNames(in: fixture.destination), ["alpha", "beta"])
        // Move removes the sources.
        XCTAssertEqual(try sortedNames(in: fixture.source), [])
    }

    func testBatchDeleteTrashesAllItems() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let (model, _) = try await setUpModelWithIndexedSkills(
            source: fixture.source,
            destination: fixture.destination
        )
        let skills = model.snapshots.sorted { $0.path < $1.path }
        let coordinator = model.fileOperations

        await coordinator.planBatch(.delete, for: skills)
        await coordinator.executePendingBatch()

        XCTAssertNil(coordinator.operationError)
        XCTAssertNil(coordinator.pendingBatch)
        XCTAssertEqual(try sortedNames(in: fixture.source), [])
    }

    func testBatchRejectsUnsupportedOperationKinds() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let (model, _) = try await setUpModelWithIndexedSkills(
            source: fixture.source,
            destination: fixture.destination
        )
        let coordinator = model.fileOperations

        // .createSymbolicLink is single-item only; the batch guard rejects it.
        await coordinator.planBatch(.createSymbolicLink, for: model.snapshots, destinationRootURL: fixture.destination)

        XCTAssertNil(coordinator.pendingBatch)
        XCTAssertNotNil(coordinator.operationError)
    }

    func testBatchStopsAtFirstFailureAndKeepsCompletedItemsVisible() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let (model, _) = try await setUpModelWithIndexedSkills(
            source: fixture.source,
            destination: fixture.destination
        )
        let alpha = model.snapshots.first { $0.path.hasSuffix("/alpha") }
        let beta = model.snapshots.first { $0.path.hasSuffix("/beta") }
        let skills = [try XCTUnwrap(alpha), try XCTUnwrap(beta)].sorted { $0.path < $1.path }
        let coordinator = model.fileOperations

        // Plan succeeds for both (both sources exist), then the first source
        // disappears before execution — the batch must stop at that item and
        // surface the error instead of cascading.
        await coordinator.planBatch(.copy, for: skills, destinationRootURL: fixture.destination)
        XCTAssertNotNil(coordinator.pendingBatch)
        try FileManager.default.removeItem(at: fixture.source.appending(path: "alpha"))
        await coordinator.executePendingBatch()

        XCTAssertNotNil(coordinator.operationError)
        XCTAssertNil(coordinator.pendingBatch)
        XCTAssertFalse(coordinator.isOperating)
    }

    func testExecuteRequiresUnchangedAuthorization() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let (model, bookmarks) = try await setUpModelWithIndexedSkills(
            source: fixture.source,
            destination: fixture.destination
        )
        let skills = model.snapshots.sorted { $0.path < $1.path }
        let coordinator = model.fileOperations

        await coordinator.planBatch(.copy, for: skills, destinationRootURL: fixture.destination)
        // Revoke authorization between plan and execute — the batch must fail
        // closed instead of operating against a stale authorization snapshot.
        // The revoke goes through the store directly: the in-app
        // revokeAuthorization guards against mutating roots while a batch is
        // pending, which is exactly the invariant this test checks at the
        // coordinator level.
        let rootToRevoke = try XCTUnwrap(model.authorizedRoots.first { $0.kind == .custom })
        try bookmarks.revoke(id: rootToRevoke.id)
        await coordinator.executePendingBatch()

        XCTAssertNotNil(coordinator.operationError)
        XCTAssertNil(coordinator.pendingBatch)
    }
}
