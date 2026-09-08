import Foundation
import GRDB
import XCTest
@testable import SkillSelector
@testable import SkillSelectorCore

/// Model-level integration for the depth features: the deferred backfill
/// fills similarity fingerprints (near-duplicate view), the background
/// body index powers body search, refreshes record their changes, and the
/// copy comparison reads real installations.
@MainActor
final class DepthFeaturesTests: XCTestCase {
    private let longBody = String(
        repeating: "The assistant deploys review stacks and summarizes pull requests before handing them back. ",
        count: 10
    )

    func testBackfillFillsNearDuplicateGroupsAndBodyIndex() async throws {
        let harness = try makeHarness(
            skills: [
                ("original", longBody),
                ("drifted", longBody.replacingOccurrences(of: "pull requests", with: "merge requests")),
            ]
        )

        await harness.model.refresh()
        XCTAssertTrue(harness.model.nearDuplicateGroups.isEmpty, "no fingerprints yet")
        await harness.model.waitForFingerprintBackfill()
        await harness.model.waitForBodySearchIndex()

        let groups = harness.model.nearDuplicateGroups
        XCTAssertEqual(groups.count, 1)
        guard let group = groups.first else { return }
        XCTAssertEqual(group.members.count, 2)
        // The exact-duplicate view stays empty: the bodies differ.
        XCTAssertTrue(harness.model.duplicateGroups.isEmpty)
        // The body index folded both bodies.
        XCTAssertEqual(
            Set(harness.model.bodySearchTextsByPath.keys),
            Set(harness.model.snapshots.map(\.path))
        )
        XCTAssertTrue(
            harness.model.bodySearchTextsByPath.values.contains {
                $0.contains("merge requests")
            }
        )
    }

    func testBodySearchFindsSkillsThroughTheModelIndex() async throws {
        let harness = try makeHarness(
            skills: [
                ("original", longBody),
                ("unrelated", String(repeating: "Zebra migrations cross the savanna at dawn. ", count: 20)),
            ]
        )
        await harness.model.refresh()
        await harness.model.waitForBodySearchIndex()

        let results = SkillQuery(searchText: "body:summarizes")
            .apply(
                to: harness.model.snapshots,
                rootsByID: harness.model.rootsByID,
                bodyTextsByPath: harness.model.bodySearchTextsByPath
            )
        XCTAssertEqual(results.map(\.name), ["original"])
    }

    func testRefreshingWithChangesRecordsHistory() async throws {
        let harness = try makeHarness(skills: [("alpha", longBody)])
        await harness.model.refresh()
        // The very first scan of a fresh store legitimately records the
        // import as additions.
        XCTAssertEqual(harness.model.refreshHistory.count, 1)
        XCTAssertTrue(harness.model.refreshHistory[0].addedPaths[0].hasSuffix("alpha"))

        // A second Skill appears on disk.
        try writeSkill(
            in: harness.rootURL,
            name: "beta",
            body: longBody.replacingOccurrences(of: "deploys", with: "ships")
        )
        await harness.model.refresh()

        XCTAssertEqual(harness.model.refreshHistory.count, 2)
        let entry = harness.model.refreshHistory[0]
        XCTAssertEqual(entry.addedPaths.count, 1)
        XCTAssertTrue(entry.addedPaths[0].hasSuffix("beta"))

        // An unchanged refresh is not recorded.
        await harness.model.refresh()
        XCTAssertEqual(harness.model.refreshHistory.count, 2)
    }

    func testIgnoringNearDuplicateClusterHidesIt() async throws {
        let harness = try makeHarness(
            skills: [
                ("original", longBody),
                ("drifted", longBody.replacingOccurrences(of: "pull requests", with: "merge requests")),
            ]
        )
        await harness.model.refresh()
        await harness.model.waitForFingerprintBackfill()
        guard let group = harness.model.nearDuplicateGroups.first else {
            return XCTFail("expected a near-duplicate cluster after backfill")
        }

        _ = try harness.model.setNearDuplicateGroupIgnored(group, ignored: true)
        XCTAssertTrue(harness.model.nearDuplicateGroups.isEmpty)

        // The ignore persists across a refresh.
        await harness.model.refresh()
        await harness.model.waitForFingerprintBackfill()
        XCTAssertTrue(harness.model.nearDuplicateGroups.isEmpty)
    }

    /// Ignoring must stay reversible: the ignored exact group is listed by
    /// its persisted key with its members, and restoring brings the group
    /// back (the acceptance run found ignore to be a one-way operation).
    func testIgnoredExactGroupIsListedAndRestorable() async throws {
        let harness = try makeHarness(
            skills: [("original", longBody), ("copy", longBody)]
        )
        await harness.model.refresh()
        await harness.model.waitForFingerprintBackfill()
        guard let group = harness.model.duplicateGroups.first else {
            return XCTFail("expected an exact-duplicate group after backfill")
        }
        let fingerprint = group.fingerprint

        _ = try harness.model.setDuplicateGroupIgnored(fingerprint: fingerprint, ignored: true)
        XCTAssertTrue(harness.model.duplicateGroups.isEmpty)

        let ignored = harness.model.ignoredDuplicateGroups
        XCTAssertEqual(ignored.count, 1)
        XCTAssertEqual(ignored[0].fingerprint, fingerprint)
        XCTAssertEqual(ignored[0].members.count, 2)

        _ = try harness.model.setDuplicateGroupIgnored(fingerprint: fingerprint, ignored: false)
        XCTAssertEqual(harness.model.duplicateGroups.count, 1)
        XCTAssertTrue(harness.model.ignoredDuplicateGroups.isEmpty)
    }

    /// Same reversibility contract for near-duplicate clusters, restored
    /// through the key+paths path the duplicates view uses.
    func testIgnoredNearClusterIsListedAndRestorable() async throws {
        let harness = try makeHarness(
            skills: [
                ("original", longBody),
                ("drifted", longBody.replacingOccurrences(of: "pull requests", with: "merge requests")),
            ]
        )
        await harness.model.refresh()
        await harness.model.waitForFingerprintBackfill()
        guard let group = harness.model.nearDuplicateGroups.first else {
            return XCTFail("expected a near-duplicate cluster after backfill")
        }

        _ = try harness.model.setNearDuplicateGroupIgnored(group, ignored: true)
        XCTAssertTrue(harness.model.nearDuplicateGroups.isEmpty)

        let ignored = harness.model.ignoredNearDuplicateGroups
        XCTAssertEqual(ignored.count, 1)
        XCTAssertEqual(ignored[0].members.count, 2)

        _ = try harness.model.setNearDuplicateGroupIgnored(
            fingerprint: ignored[0].fingerprint,
            memberPaths: ignored[0].members.map(\.path),
            ignored: false
        )
        XCTAssertEqual(harness.model.nearDuplicateGroups.count, 1)
        XCTAssertTrue(harness.model.ignoredNearDuplicateGroups.isEmpty)
    }

    func testCompareSnapshotsReportsFrontmatterBodyAndFiles() async throws {
        let harness = try makeHarness(
            skills: [
                ("left", longBody),
                ("right", longBody.replacingOccurrences(of: "pull requests", with: "merge requests")),
            ]
        )
        await harness.model.refresh()
        let left = harness.model.snapshots.first { $0.name == "left" }!
        let right = harness.model.snapshots.first { $0.name == "right" }!
        // Sibling file only on the right side.
        try Data("template".utf8).write(
            to: URL(fileURLWithPath: right.path).appendingPathComponent("template.txt")
        )

        let comparison = try await harness.model.comparisons.compareSnapshots(left, right, authorizedRoots: harness.model.authorizedRoots)

        XCTAssertEqual(comparison.leftPath, left.path)
        XCTAssertEqual(comparison.rightPath, right.path)
        XCTAssertFalse(comparison.bodiesAreIdentical)
        XCTAssertEqual(comparison.bodyDiff.addedCount, 1)
        XCTAssertEqual(comparison.bodyDiff.removedCount, 1)
        let template = comparison.files.first { $0.relativePath == "template.txt" }
        XCTAssertEqual(template?.difference, .rightOnly)
    }

    // MARK: Fixture

    private struct Harness {
        let model: AppModel
        let rootURL: URL
        let defaults: UserDefaults
        private let suite: String

        init(model: AppModel, rootURL: URL, defaults: UserDefaults, suite: String) {
            self.model = model
            self.rootURL = rootURL
            self.defaults = defaults
            self.suite = suite
        }

        func teardown() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: rootURL)
        }
    }

    private func makeHarness(skills: [(name: String, body: String)]) throws -> Harness {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DepthFeaturesTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        for skill in skills {
            try writeSkill(in: rootURL, name: skill.name, body: skill.body)
        }

        let suite = "DepthFeaturesTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let database = try SkillStore.inMemory()
        let bookmarks = BookmarkStore(database: database, adapter: PathBookmarkAdapter())
        try bookmarks.save(url: rootURL, kind: .project)
        let index = SkillIndex(database: database)
        let registry = BuiltInAgentRegistry.make()
        let refresher = IndexRefresher(
            registry: registry,
            bookmarks: bookmarks,
            scanner: SkillScanner(computesContentFingerprints: false),
            index: index
        )
        let model = AppModel(
            refresher: refresher,
            index: index,
            bookmarks: bookmarks,
            registry: registry,
            defaults: defaults
        )
        let harness = Harness(model: model, rootURL: rootURL, defaults: defaults, suite: suite)
        addTeardownBlock { harness.teardown() }
        return harness
    }

    private func writeSkill(in root: URL, name: String, body: String) throws {
        let skill = root.appendingPathComponent(".cursor/skills/\(name)")
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        try "---\nname: \(name)\ndescription: \(name) skill\n---\n\(body)".write(
            to: skill.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
    }
}

/// Path-encoding bookmark adapter — a bare `swift test` process lacks the
/// app-scope entitlement for real security-scoped bookmarks (same pattern
/// as the other test files' adapters).
private final class PathBookmarkAdapter: BookmarkDataCreating, @unchecked Sendable {
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
