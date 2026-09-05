import Foundation
import GRDB
import XCTest
@testable import SkillSelector
@testable import SkillSelectorCore

/// Deferred content fingerprints: the scan skips its dominant I/O cost so
/// the Skill list appears immediately; the background backfill fills the
/// fingerprints (and the duplicate view) in afterwards.
@MainActor
final class DeferredFingerprintTests: XCTestCase {
    func testDeferredScannerOmitsFingerprintsOnFreshScans() async throws {
        let fixture = try makeFixture()
        let root = ScanRoot.project(id: "p", url: fixture.url, registry: BuiltInAgentRegistry.make())

        let deferred = await SkillScanner(computesContentFingerprints: false).scan([root])
        XCTAssertEqual(deferred.installations.count, 2)
        XCTAssertTrue(
            deferred.installations.allSatisfy { $0.contentFingerprint == nil },
            "deferred fresh scans must not read file contents for fingerprints"
        )

        let full = await SkillScanner().scan([root])
        XCTAssertTrue(
            full.installations.allSatisfy { $0.contentFingerprint != nil },
            "the default scanner keeps computing fingerprints inline"
        )
    }

    func testBackfillWritesRecordsAndCacheEntries() async throws {
        let fixture = try makeFixture()
        let root = ScanRoot.project(id: "p", url: fixture.url, registry: BuiltInAgentRegistry.make())
        let report = await SkillScanner(computesContentFingerprints: false).scan([root])
        let index = try makeIndex()

        try index.apply(report: report)
        XCTAssertTrue(try index.skills().allSatisfy { $0.contentFingerprint == nil })

        let fingerprints = try report.installations.dictionaryMap { installation in
            (
                installation.path.standardizedFileURL.path,
                try SkillContentFingerprint.compute(
                    entryFileURL: installation.path.appending(path: "SKILL.md")
                )
            )
        }
        XCTAssertEqual(try index.backfillContentFingerprints(fingerprints), 2)

        // Records expose the fingerprint…
        let skills = try index.skills()
        XCTAssertTrue(skills.allSatisfy { $0.contentFingerprint != nil })
        XCTAssertEqual(skills.compactMap(\.contentFingerprint).count, 2)
        // …and the incremental cache serves it on the next scan's fast path.
        let entries = try index.cachedScanEntries()
        XCTAssertEqual(entries.count, 2)
        for (path, entry) in entries {
            XCTAssertEqual(entry.contentFingerprint, fingerprints[path])
        }
        // Idempotent: nothing left to update.
        XCTAssertEqual(try index.backfillContentFingerprints(fingerprints), 0)
        // Unknown paths (the Skill vanished) are skipped, not fatal.
        XCTAssertEqual(try index.backfillContentFingerprints(["/gone": "abc"]), 0)
    }

    func testBackfilledCacheEntriesServeFingerprintsOnCacheHits() async throws {
        let fixture = try makeFixture()
        let root = ScanRoot.project(id: "p", url: fixture.url, registry: BuiltInAgentRegistry.make())
        let scanner = SkillScanner(computesContentFingerprints: false)
        let index = try makeIndex()
        let report = await scanner.scan([root])
        try index.apply(report: report)

        let fingerprints = try report.installations.dictionaryMap { installation in
            (
                installation.path.standardizedFileURL.path,
                try SkillContentFingerprint.compute(
                    entryFileURL: installation.path.appending(path: "SKILL.md")
                )
            )
        }
        try index.backfillContentFingerprints(fingerprints)

        // Second scan with the backfilled cache: hits must return the
        // fingerprint without re-reading file contents.
        let second = await scanner.scan(
            [root],
            cache: SkillScanCache(entriesByPath: try index.cachedScanEntries())
        )
        XCTAssertTrue(second.installations.allSatisfy(\.reusedCachedScan))
        for installation in second.installations {
            XCTAssertEqual(
                installation.contentFingerprint,
                fingerprints[installation.path.standardizedFileURL.path]
            )
        }
    }

    func testModelShowsListImmediatelyAndBackfillsDuplicates() async throws {
        let fixture = try makeFixture()
        let suite = "DeferredFingerprintModelTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let database = try SkillStore.inMemory()
        let bookmarks = BookmarkStore(database: database, adapter: PathBookmarkAdapter())
        try bookmarks.save(url: fixture.url, kind: .project)
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

        await model.refresh()

        // The list is already complete — only the fingerprints are missing.
        XCTAssertEqual(model.snapshots.count, 2)
        XCTAssertTrue(model.snapshots.allSatisfy { $0.contentFingerprint == nil })
        XCTAssertTrue(model.duplicateGroups.isEmpty)

        await model.waitForFingerprintBackfill()

        // The background pass filled the fingerprints and the duplicate
        // view now groups the identical copies.
        XCTAssertTrue(model.snapshots.allSatisfy { $0.contentFingerprint != nil })
        XCTAssertEqual(model.duplicateGroups.count, 1)
        XCTAssertEqual(model.duplicateGroups[0].members.count, 2)

        // A later refresh keeps the fingerprints via the backfilled cache.
        await model.refresh()
        XCTAssertTrue(model.snapshots.allSatisfy { $0.contentFingerprint != nil })
        XCTAssertEqual(model.duplicateGroups.count, 1)
    }

    // MARK: Fixtures

    /// A project root with two content-identical Skills.
    private func makeFixture() throws -> Fixture {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "DeferredFingerprintTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for name in ["alpha", "beta"] {
            let skill = url.appending(path: ".cursor/skills/\(name)")
            try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
            // Byte-identical entry files: the fingerprint covers the skill
            // directory's relative tree, so identical copies in different
            // folders share a fingerprint.
            try "---\nname: twin\ndescription: identical\n---\n# twin\n".write(
                to: skill.appending(path: "SKILL.md"),
                atomically: true,
                encoding: .utf8
            )
        }
        return Fixture(url: url)
    }

    private func makeIndex() throws -> SkillIndex {
        SkillIndex(database: try makeDatabase())
    }

    private func makeDatabase() throws -> DatabaseQueue {
        try SkillStore.inMemory()
    }
}

private struct Fixture {
    let url: URL

    // Temp directories resolve through /var → /private/var; the scanner
    // standardizes, so keys must use the resolved form.
    var projectRoot: URL { url.resolvingSymlinksInPath().standardizedFileURL }
}

private extension Array {
    func dictionaryMap<K, V>(_ transform: (Element) throws -> (K, V)) rethrows -> [K: V] {
        var result: [K: V] = [:]
        for element in self {
            let (key, value) = try transform(element)
            result[key] = value
        }
        return result
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
