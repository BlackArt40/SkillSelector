import Foundation
import GRDB
import XCTest
@testable import SkillSelectorCore

/// GRDB 持久层行为契约：建表、record 往返、apply 语义、书签 BLOB 往返、
/// 串行写。原 SwiftData 时代的持久化断言（SkillIndexTests 等）改构造方式后
/// 继续生效；这里只测新存储层自身的机制。
final class SkillStoreTests: XCTestCase {
    private func makeStore() throws -> DatabaseQueue {
        // Through SkillStore so the schema migration runs: a raw in-memory
        // DatabaseQueue has no tables (GRDB 7: `DatabaseQueue()` is the
        // independent in-memory store; the GRDB 6-era `.inMemory()`
        // factory is gone).
        try SkillStore.inMemory()
    }

    func testOpenCreatesSchemaAtURL() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("skillstore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let url = base.appendingPathComponent("index.sqlite")
        _ = try SkillStore.open(url: url)
        let reopened = try SkillStore.open(url: url)   // 幂等：二次打开不重建不报错
        _ = reopened
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testSkillRecordRoundTrip() throws {
        let db = try makeStore()
        let record = SkillRecord(
            path: "/tmp/demo", resolvedTarget: nil, name: "demo",
            localDescription: "A demo", modificationDate: Date(timeIntervalSince1970: 100),
            agentIDsByRootData: Data("{\"project\":[\"cursor\"]}".utf8),
            entryFilename: "SKILL.md", parseDiagnosticsData: Data(),
            contentFingerprint: "s:abc", similarityFingerprint: "s1:def",
            ignoredDuplicateGroup: nil, ignoredNearDuplicateGroup: nil,
            scanStateData: nil
        )
        try db.write { try record.upsert($0) }
        let loaded = try db.read { try SkillRecord.fetchAll($0) }
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.path, "/tmp/demo")
        XCTAssertEqual(loaded.first?.name, "demo")
        XCTAssertEqual(loaded.first?.localDescription, "A demo")
    }

    func testUniquePathUpsertsInsteadOfDuplicating() throws {
        let db = try makeStore()
        try db.write { db in
            try SkillRecord(path: "/a", name: "one", entryFilename: "SKILL.md").upsert(db)
            try SkillRecord(path: "/a", name: "two", entryFilename: "SKILL.md").upsert(db)
        }
        let rows = try db.read { try SkillRecord.fetchAll($0) }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.name, "two")
    }

    func testAuthorizedRootBookmarkBlobRoundTrip() throws {
        let db = try makeStore()
        let blob = Data("bookmark-bytes-\(UUID())".utf8)
        let root = AuthorizedRootRecord(path: "/tmp/project", kind: .project, bookmarkData: blob)
        try db.write { try root.upsert($0) }
        let loaded = try db.read { try AuthorizedRootRecord.fetchAll($0) }
        XCTAssertEqual(loaded.first?.bookmarkData, blob)
        XCTAssertEqual(loaded.first?.kindRawValue, "project")
    }
}
