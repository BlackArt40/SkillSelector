import Foundation
import XCTest
@testable import SkillSelector

/// Regression tests for the one-time legacy-store migration (v1.8.0 and
/// earlier kept the SwiftData framework default `default.store`, a name
/// shared with every other SwiftData app). The migration must copy only
/// stores carrying this app's schema fingerprint, only when the
/// app-scoped store does not exist yet, and never touch the original.
@MainActor
final class LegacyStoreMigrationTests: XCTestCase {
    private var base: URL!
    private var fileManager: FileManager!

    override func setUpWithError() throws {
        try super.setUpWithError()
        fileManager = .default
        base = fileManager.temporaryDirectory
            .appendingPathComponent("legacy-store-migration-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fileManager.removeItem(at: base)
        try super.tearDownWithError()
    }

    private func writeLegacyStore(_ content: String, suffix: String = "") throws {
        try content.write(
            to: base.appendingPathComponent("default.store\(suffix)"),
            atomically: true,
            encoding: .utf8
        )
    }

    private var migratedStore: URL {
        base.appendingPathComponent("SkillSelector", isDirectory: true)
            .appendingPathComponent("SkillSelector.store")
    }

    func testMigratesStoreWithOurSchemaFingerprint() throws {
        try writeLegacyStore("CREATE TABLE ZSKILLRECORD (...); CREATE TABLE ZAUTHORIZEDROOTRECORD (...);")
        try writeLegacyStore("wal-bytes", suffix: "-wal")

        SkillSelectorApp.migrateLegacyStoreIfNeeded(applicationSupport: base, fileManager: fileManager)

        XCTAssertTrue(fileManager.fileExists(atPath: migratedStore.path), "应迁移到应用专属位置")
        XCTAssertTrue(fileManager.fileExists(atPath: migratedStore.path + "-wal"), "WAL 伴随文件一并迁移")
        XCTAssertEqual(try String(contentsOf: migratedStore, encoding: .utf8),
                       "CREATE TABLE ZSKILLRECORD (...); CREATE TABLE ZAUTHORIZEDROOTRECORD (...);")
        // The shared-path original is never removed — another SwiftData
        // app may own the same default.store name.
        XCTAssertTrue(fileManager.fileExists(atPath: base.appendingPathComponent("default.store").path),
                      "旧文件只拷贝不移除")
    }

    func testSkipsForeignStoreWithoutFingerprint() throws {
        try writeLegacyStore("CREATE TABLE ZSOMEOTHERAPPDATA (...);")

        SkillSelectorApp.migrateLegacyStoreIfNeeded(applicationSupport: base, fileManager: fileManager)

        XCTAssertFalse(fileManager.fileExists(atPath: migratedStore.path), "外来 store 不迁移")
    }

    func testSkipsWhenAppScopedStoreAlreadyExists() throws {
        try writeLegacyStore("CREATE TABLE ZSKILLRECORD (...);")
        try fileManager.createDirectory(
            at: base.appendingPathComponent("SkillSelector", isDirectory: true),
            withIntermediateDirectories: true
        )
        try "existing".write(to: migratedStore, atomically: true, encoding: .utf8)

        SkillSelectorApp.migrateLegacyStoreIfNeeded(applicationSupport: base, fileManager: fileManager)

        XCTAssertEqual(try String(contentsOf: migratedStore, encoding: .utf8), "existing",
                       "已有应用专属 store 时不得覆盖")
    }

    func testSkipsWhenNoLegacyStore() throws {
        SkillSelectorApp.migrateLegacyStoreIfNeeded(applicationSupport: base, fileManager: fileManager)

        XCTAssertFalse(fileManager.fileExists(atPath: migratedStore.path))
    }
}
