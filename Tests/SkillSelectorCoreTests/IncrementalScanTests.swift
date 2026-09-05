import Foundation
import GRDB
import XCTest
@testable import SkillSelectorCore

/// Incremental-scan pipeline: unchanged installations must reuse their
/// cached parse and fingerprint (no file reads), any stat change must
/// invalidate the cache for that installation.
final class IncrementalScanTests: XCTestCase {
    private var workspace: URL!

    override func setUpWithError() throws {
        workspace = FileManager.default.temporaryDirectory
            .appending(path: "IncrementalScanTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: workspace)
    }

    private var projectRoot: ScanRoot {
        .project(id: "project", url: workspace, registry: BuiltInAgentRegistry.make())
    }

    @discardableResult
    private func writeSkill(at relativePath: String, name: String, description: String) throws -> URL {
        let directory = workspace.appending(path: relativePath, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "---\nname: \(name)\ndescription: \(description)\n---\n# \(name)\n".write(
            to: directory.appending(path: "SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        return directory
    }

    /// Pushes the entry's mtime into the past so a later rewrite reliably
    /// produces a different timestamp (APFS is nanosecond-precise, but the
    /// test must not depend on write timing).
    private func ageEntry(at directory: URL) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -600)],
            ofItemAtPath: directory.appending(path: "SKILL.md").path
        )
    }

    private func cache(from report: ScanReport) -> SkillScanCache {
        var entries: [String: ScannedSkillCacheEntry] = [:]
        for installation in report.installations {
            guard let state = installation.scanState else { continue }
            entries[installation.path.path] = ScannedSkillCacheEntry(
                state: state,
                document: installation.document,
                contentFingerprint: installation.contentFingerprint,
                entryModificationDate: installation.entryModificationDate
            )
        }
        return SkillScanCache(entriesByPath: entries)
    }

    func testUnchangedInstallationsReuseTheCachedScan() async throws {
        try writeSkill(at: ".codex/skills/demo", name: "demo", description: "first")

        let first = await SkillScanner().scan([projectRoot])
        XCTAssertEqual(first.installations.first?.reusedCachedScan, false)
        XCTAssertNotNil(first.installations.first?.scanState)

        let second = await SkillScanner().scan([projectRoot], cache: cache(from: first))
        let installation = try XCTUnwrap(second.installations.first)
        XCTAssertTrue(installation.reusedCachedScan)
        XCTAssertNil(installation.scanState)
        XCTAssertEqual(installation.document.description, "first")
        XCTAssertEqual(installation.contentFingerprint, first.installations.first?.contentFingerprint)
    }

    func testRewrittenEntryFileInvalidatesTheCache() async throws {
        let directory = try writeSkill(at: ".codex/skills/demo", name: "demo", description: "first")
        try ageEntry(at: directory)
        let first = await SkillScanner().scan([projectRoot])

        try "---\nname: demo\ndescription: second\n---\n# demo\n".write(
            to: directory.appending(path: "SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        let second = await SkillScanner().scan([projectRoot], cache: cache(from: first))

        let installation = try XCTUnwrap(second.installations.first)
        XCTAssertFalse(installation.reusedCachedScan)
        XCTAssertEqual(installation.document.description, "second")
        XCTAssertNotNil(installation.scanState)
    }

    /// The auxiliary file changes the directory's stat tree, so the cache
    /// is invalidated and the installation re-reads — but the body-only
    /// fingerprint stays stable (AC-4: sub-files never participate).
    func testAddedAuxiliaryFileInvalidatesTheCacheButKeepsTheFingerprint() async throws {
        let directory = try writeSkill(at: ".codex/skills/demo", name: "demo", description: "same")
        let first = await SkillScanner().scan([projectRoot])
        let firstFingerprint = try XCTUnwrap(first.installations.first?.contentFingerprint)

        try "echo hi".write(
            to: directory.appending(path: "run.sh"),
            atomically: true,
            encoding: .utf8
        )
        let second = await SkillScanner().scan([projectRoot], cache: cache(from: first))

        let installation = try XCTUnwrap(second.installations.first)
        XCTAssertFalse(installation.reusedCachedScan)
        XCTAssertEqual(installation.contentFingerprint, firstFingerprint)
    }

    func testIndexPersistsScanCacheForTheNextRefresh() async throws {
        try writeSkill(at: ".codex/skills/demo", name: "demo", description: "first")
        let index = SkillIndex(database: try SkillStore.inMemory())

        let first = await SkillScanner().scan([projectRoot])
        try index.apply(report: first)

        let persisted = try index.cachedScanEntries()
        XCTAssertEqual(persisted.count, 1)
        XCTAssertEqual(persisted[first.installations[0].path.path]?.document.description, "first")

        let second = await SkillScanner().scan([projectRoot], cache: SkillScanCache(entriesByPath: persisted))
        try index.apply(report: second)
        XCTAssertTrue(try XCTUnwrap(second.installations.first).reusedCachedScan)

        // The reused pass keeps the persisted state; a third refresh hits too.
        let third = await SkillScanner().scan(
            [projectRoot],
            cache: SkillScanCache(entriesByPath: try index.cachedScanEntries())
        )
        XCTAssertTrue(try XCTUnwrap(third.installations.first).reusedCachedScan)
        XCTAssertEqual(try index.skills().first?.localDescription, "first")
    }

    func testRemovedSkillDropsItsCacheWithTheRecord() async throws {
        try writeSkill(at: ".codex/skills/demo", name: "demo", description: "first")
        let index = SkillIndex(database: try SkillStore.inMemory())

        let first = await SkillScanner().scan([projectRoot])
        try index.apply(report: first)
        try FileManager.default.removeItem(
            at: workspace.appending(path: ".codex/skills/demo", directoryHint: .isDirectory)
        )

        let second = await SkillScanner().scan([projectRoot], cache: SkillScanCache(entriesByPath: try index.cachedScanEntries()))
        try index.apply(report: second)

        XCTAssertTrue(second.installations.isEmpty)
        XCTAssertTrue(try index.cachedScanEntries().isEmpty)
    }
}
