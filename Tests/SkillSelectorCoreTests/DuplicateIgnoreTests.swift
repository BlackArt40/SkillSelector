import Foundation
import SwiftData
import XCTest
@testable import SkillSelector
@testable import SkillSelectorCore

/// Duplicate-group ignore (spec §1.10, AC-6/AC-7): marking a group as
/// ignored removes it from the duplicates view, and the choice is persisted
/// with SwiftData so it survives restarts.
@MainActor
final class DuplicateIgnorePersistenceTests: XCTestCase {
    /// Two content-identical Skills under one project root.
    private func makeFixture() throws -> (root: URL, fingerprints: [String: String]) {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "DuplicateIgnore-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let root = ScanRoot.project(id: "p", url: base, registry: BuiltInAgentRegistry.make())
        let content = "---\nname: twin\ndescription: identical\n---\n# twin\nshared body\n"
        var fingerprints: [String: String] = [:]
        for name in ["alpha", "beta"] {
            let directory = base.appending(path: ".codex/skills/\(name)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let entry = directory.appending(path: "SKILL.md")
            try content.write(to: entry, atomically: true, encoding: .utf8)
            fingerprints[directory.standardizedFileURL.path] = try SkillContentFingerprint.compute(entryFileURL: entry)
        }
        return (base, fingerprints)
    }

    private func makeIndex(storeURL: URL? = nil) throws -> SkillIndex {
        let configuration: ModelConfiguration
        if let storeURL {
            configuration = ModelConfiguration(url: storeURL)
        } else {
            configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        }
        let container = try ModelContainer(
            for: SkillRecord.self,
            AuthorizedRootRecord.self,
            configurations: configuration
        )
        return SkillIndex(container: container)
    }

    private func twinFingerprint(_ report: ScanReport) throws -> String {
        let fingerprints = Set(try report.installations.map { installation in
            try XCTUnwrap(installation.contentFingerprint)
        })
        XCTAssertEqual(fingerprints.count, 1, "fixture must produce one duplicate group")
        return try XCTUnwrap(fingerprints.first)
    }

    func testIgnoringGroupRemovesItFromTheDuplicatesView() async throws {
        let (base, _) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = ScanRoot.project(id: "p", url: base, registry: BuiltInAgentRegistry.make())
        let index = try makeIndex()
        try index.apply(report: await SkillScanner().scan([root]))

        // AC-6: before ignoring, both copies group.
        let fingerprint = try twinFingerprint(await SkillScanner().scan([root]))
        XCTAssertEqual(DuplicateSkillGrouper.groups(try index.skills()).count, 1)

        // Mark the group ignored → it disappears from the duplicates view.
        XCTAssertEqual(try index.setIgnoredDuplicateGroup(fingerprint, ignored: true), 2)
        let skills = try index.skills()
        XCTAssertTrue(skills.allSatisfy { $0.ignoredDuplicateGroup == fingerprint })
        XCTAssertTrue(DuplicateSkillGrouper.groups(skills).isEmpty)
    }

    func testUnignoringRestoresTheGroup() async throws {
        let (base, _) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = ScanRoot.project(id: "p", url: base, registry: BuiltInAgentRegistry.make())
        let index = try makeIndex()
        try index.apply(report: await SkillScanner().scan([root]))
        let fingerprint = try twinFingerprint(await SkillScanner().scan([root]))

        _ = try index.setIgnoredDuplicateGroup(fingerprint, ignored: true)
        _ = try index.setIgnoredDuplicateGroup(fingerprint, ignored: false)

        let skills = try index.skills()
        XCTAssertTrue(skills.allSatisfy { $0.ignoredDuplicateGroup == nil })
        XCTAssertEqual(DuplicateSkillGrouper.groups(skills).count, 1)
    }

    /// AC-7: the ignore choice survives a store reopen (app restart).
    func testIgnoredGroupPersistsAcrossStoreReopen() async throws {
        let (base, _) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = ScanRoot.project(id: "p", url: base, registry: BuiltInAgentRegistry.make())
        let storeURL = FileManager.default.temporaryDirectory
            .appending(path: "DuplicateIgnoreStore-\(UUID().uuidString).store")
        defer { try? FileManager.default.removeItem(at: storeURL) }

        let first = try makeIndex(storeURL: storeURL)
        try first.apply(report: await SkillScanner().scan([root]))
        let fingerprint = try twinFingerprint(await SkillScanner().scan([root]))
        _ = try first.setIgnoredDuplicateGroup(fingerprint, ignored: true)

        // Reopen the same store: the ignore is still applied.
        let second = try makeIndex(storeURL: storeURL)
        let skills = try second.skills()
        XCTAssertTrue(skills.allSatisfy { $0.ignoredDuplicateGroup == fingerprint })
        XCTAssertTrue(DuplicateSkillGrouper.groups(skills).isEmpty)
    }

    func testRefreshKeepsTheIgnoreChoice() async throws {
        // A rescan rewrites records; the persisted ignore must survive it.
        let (base, _) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = ScanRoot.project(id: "p", url: base, registry: BuiltInAgentRegistry.make())
        let index = try makeIndex()
        let report = await SkillScanner().scan([root])
        try index.apply(report: report)
        let fingerprint = try twinFingerprint(report)

        _ = try index.setIgnoredDuplicateGroup(fingerprint, ignored: true)
        // Refresh with the same (now cached) tree.
        let refreshed = await SkillScanner().scan(
            [root],
            cache: SkillScanCache(entriesByPath: try index.cachedScanEntries())
        )
        try index.apply(report: refreshed)

        let skills = try index.skills()
        XCTAssertTrue(skills.allSatisfy { $0.ignoredDuplicateGroup == fingerprint })
        XCTAssertTrue(DuplicateSkillGrouper.groups(skills).isEmpty)
    }
}

/// Fingerprint algorithm versioning (migration from the pre-v2
/// directory-tree hash): every fresh fingerprint carries the current
/// version prefix, and incremental-cache entries with a stale-version
/// fingerprint are skipped so they rescan once with the body-only hash.
@MainActor
final class FingerprintVersionMigrationTests: XCTestCase {
    func testFingerprintCarriesTheCurrentVersionPrefix() throws {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "FpVersion-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let entry = base.appending(path: "SKILL.md")
        try "---\nname: demo\n---\n# demo\nbody\n".write(to: entry, atomically: true, encoding: .utf8)

        let fingerprint = try SkillContentFingerprint.compute(entryFileURL: entry)
        XCTAssertTrue(fingerprint.hasPrefix(SkillContentFingerprint.currentVersionPrefix))
        XCTAssertTrue(SkillContentFingerprint.isCurrentVersion(fingerprint))
        // A bare hex (the old algorithm's output) is not current.
        XCTAssertFalse(SkillContentFingerprint.isCurrentVersion(String(fingerprint.dropFirst(3))))
        XCTAssertFalse(SkillContentFingerprint.isCurrentVersion(""))
    }

    /// An entry whose cache carries a pre-v2 fingerprint is excluded from
    /// the incremental cache; the next scan re-reads it and produces a
    /// current-version fingerprint.
    func testStaleFingerprintCacheEntriesAreSkippedAndRescanned() async throws {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "FpVersionScan-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: base) }
        let skill = base.appending(path: ".codex/skills/demo", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        try "---\nname: demo\ndescription: same\n---\n# demo\nbody\n".write(
            to: skill.appending(path: "SKILL.md"),
            atomically: true,
            encoding: .utf8
        )

        let container = try ModelContainer(
            for: SkillRecord.self,
            AuthorizedRootRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let index = SkillIndex(container: container)
        let root = ScanRoot.project(id: "p", url: base, registry: BuiltInAgentRegistry.make())
        try index.apply(report: await SkillScanner(computesContentFingerprints: true).scan([root]))

        // Rewrite the cache entry with an old-style (pre-v2) fingerprint.
        let context = ModelContext(container)
        let record = try XCTUnwrap(
            try context.fetch(FetchDescriptor<SkillRecord>()).first
        )
        let data = try XCTUnwrap(record.scanStateData)
        let entry = try JSONDecoder().decode(ScannedSkillCacheEntry.self, from: data)
        record.scanStateData = try JSONEncoder().encode(ScannedSkillCacheEntry(
            state: entry.state,
            document: entry.document,
            contentFingerprint: "5f5c6a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a",
            entryModificationDate: entry.entryModificationDate
        ))
        try context.save()

        // The stale entry is excluded from the incremental cache…
        XCTAssertTrue(try index.cachedScanEntries().isEmpty)
        // …so the next scan re-reads the installation instead of reusing it.
        let second = await SkillScanner(computesContentFingerprints: true).scan(
            [root],
            cache: SkillScanCache(entriesByPath: try index.cachedScanEntries())
        )
        let installation = try XCTUnwrap(second.installations.first)
        XCTAssertFalse(installation.reusedCachedScan)
        XCTAssertTrue(SkillContentFingerprint.isCurrentVersion(
            try XCTUnwrap(installation.contentFingerprint)
        ))
    }

    /// A current-version cache entry keeps serving its fingerprint (no
    /// regression in the incremental fast path).
    func testCurrentFingerprintCacheEntriesStillHit() async throws {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "FpVersionHit-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: base) }
        let skill = base.appending(path: ".codex/skills/demo", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        try "---\nname: demo\ndescription: same\n---\n# demo\nbody\n".write(
            to: skill.appending(path: "SKILL.md"),
            atomically: true,
            encoding: .utf8
        )

        let container = try ModelContainer(
            for: SkillRecord.self,
            AuthorizedRootRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let index = SkillIndex(container: container)
        let root = ScanRoot.project(id: "p", url: base, registry: BuiltInAgentRegistry.make())
        try index.apply(report: await SkillScanner(computesContentFingerprints: true).scan([root]))

        XCTAssertEqual(try index.cachedScanEntries().count, 1)
        let second = await SkillScanner(computesContentFingerprints: true).scan(
            [root],
            cache: SkillScanCache(entriesByPath: try index.cachedScanEntries())
        )
        XCTAssertTrue(try XCTUnwrap(second.installations.first).reusedCachedScan)
    }

    /// The migration end-to-end: an ignore recorded under a pre-v2
    /// fingerprint no longer matches the fresh grouping, so the group
    /// reappears (the user re-decides under the new algorithm).
    func testStaleIgnoreDoesNotSuppressTheNewGroup() async throws {
        let snapshot = SkillSnapshot(
            path: "/a/demo",
            resolvedTarget: nil,
            name: "demo",
            localDescription: nil,
            modificationDate: nil,
            agentIDs: [],
            rootIDs: [],
            entryFilename: "SKILL.md",
            parseDiagnostics: [],
            contentFingerprint: "v2:newbodyhash",
            ignoredDuplicateGroup: "oldtreehash"
        )
        let groups = DuplicateSkillGrouper.groups([
            snapshot,
            SkillSnapshot(
                path: "/b/demo",
                resolvedTarget: nil,
                name: "demo",
                localDescription: nil,
                modificationDate: nil,
                agentIDs: [],
                rootIDs: [],
                entryFilename: "SKILL.md",
                parseDiagnostics: [],
                contentFingerprint: "v2:newbodyhash"
            ),
        ])
        XCTAssertEqual(groups.count, 1, "a stale ignore must not hide the fresh group")
    }
}

/// Symbolic-link reachability (spec §1.11, AC-12): a link whose target
/// moved or vanished is flagged without the app touching the file system.
final class SymlinkReachabilityTests: XCTestCase {    func testLinkTargetUnreachableWhenDirectoryVanishes() throws {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "SymlinkReach-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: base) }
        let target = base.appending(path: "real-skill", directoryHint: .isDirectory)
        let link = base.appending(path: "linked-skill", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let snapshot = SkillSnapshot(
            path: link.path,
            resolvedTarget: target.path,
            name: "linked",
            localDescription: nil,
            modificationDate: nil,
            agentIDs: [],
            rootIDs: [],
            entryFilename: "SKILL.md",
            parseDiagnostics: []
        )
        XCTAssertFalse(snapshot.linkTargetIsUnreachable)

        // Target vanishes → the link is flagged unreachable.
        try FileManager.default.removeItem(at: target)
        XCTAssertTrue(snapshot.linkTargetIsUnreachable)
    }

    func testNonLinkSnapshotIsNeverUnreachable() {
        let snapshot = SkillSnapshot(
            path: "/plain/skill",
            resolvedTarget: nil,
            name: "plain",
            localDescription: nil,
            modificationDate: nil,
            agentIDs: [],
            rootIDs: [],
            entryFilename: "SKILL.md",
            parseDiagnostics: []
        )
        XCTAssertFalse(snapshot.linkTargetIsUnreachable)
    }
}
