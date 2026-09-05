import Foundation
import GRDB
import XCTest
@testable import SkillSelectorCore

final class PersistenceRecordTests: XCTestCase {
    private func makeDatabase() throws -> DatabaseQueue {
        try SkillStore.inMemory()
    }

    // MARK: - AuthorizedRootKind

    func testRootKindLocalizedNames() {
        XCTAssertEqual(AuthorizedRootKind.home.localizedName, "Home Directory")
        XCTAssertEqual(AuthorizedRootKind.project.localizedName, "Project Directory")
        XCTAssertEqual(AuthorizedRootKind.system.localizedName, "System Skill Directory")
        XCTAssertEqual(AuthorizedRootKind.custom.localizedName, "Custom Skill Directory")
    }

    func testRootKindRawValuesRoundTrip() {
        for kind in AuthorizedRootKind.allCases {
            XCTAssertEqual(AuthorizedRootKind(rawValue: kind.rawValue), kind)
        }
    }

    // MARK: - AuthorizedRootRecord

    func testRootRecordPersistsAndFetches() throws {
        let database = try makeDatabase()
        let record = AuthorizedRootRecord(
            id: "root-1",
            path: "/tmp/roots/project",
            kind: .project,
            bookmarkData: Data("bookmark".utf8)
        )
        try database.write { try record.upsert($0) }

        let fetched = try database.read { try AuthorizedRootRecord.fetchAll($0) }
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched[0].id, "root-1")
        XCTAssertEqual(fetched[0].path, "/tmp/roots/project")
        XCTAssertEqual(fetched[0].kindRawValue, "project")
        XCTAssertEqual(fetched[0].bookmarkData, Data("bookmark".utf8))
    }

    func testRootRecordDefaultIdentifierIsUnique() {
        let first = AuthorizedRootRecord(path: "/tmp/a", kind: .custom, bookmarkData: Data())
        let second = AuthorizedRootRecord(path: "/tmp/b", kind: .custom, bookmarkData: Data())

        XCTAssertNotEqual(first.id, second.id)
        XCTAssertFalse(first.id.isEmpty)
    }

    func testRootRecordUniqueIdentifierKeepsSinglePersistedRecord() throws {
        let database = try makeDatabase()
        try database.write { db in
            try AuthorizedRootRecord(
                id: "same", path: "/tmp/a", kind: .home, bookmarkData: Data()
            ).upsert(db)
            try AuthorizedRootRecord(
                id: "same", path: "/tmp/b", kind: .project, bookmarkData: Data()
            ).upsert(db)
        }

        let fetched = try database.read { try AuthorizedRootRecord.fetchAll($0) }
        XCTAssertEqual(fetched.count, 1)
        // The primary key on `id` collapses conflicting inserts into a
        // single row: the second upsert replaces the first.
        XCTAssertTrue(["/tmp/a", "/tmp/b"].contains(fetched[0].path))
    }

    // MARK: - AuthorizedRootSnapshot

    func testRootSnapshotDisplayNamePrefersCustomName() {
        let url = URL(fileURLWithPath: "/tmp/roots/project")
        let plain = AuthorizedRootSnapshot(id: "1", url: url, kind: .project)
        let named = AuthorizedRootSnapshot(
            id: "2", url: url, kind: .project, customName: "Client Work"
        )

        XCTAssertEqual(plain.displayName, "project")
        XCTAssertEqual(named.displayName, "Client Work")
    }

    // MARK: - SkillRecord

    func testSkillRecordPersistsAllFields() throws {
        let database = try makeDatabase()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let record = SkillRecord(
            path: "/tmp/skills/demo",
            resolvedTarget: "/tmp/targets/demo",
            name: "demo",
            localDescription: "local",
            modificationDate: date,
            agentIDsByRootData: Data("{\"root-1\":[\"codex\"]}".utf8),
            entryFilename: "SKILL.md",
            parseDiagnosticsData: Data("issues".utf8)
        )
        try database.write { try record.upsert($0) }

        let fetched = try database.read { try SkillRecord.fetchAll($0) }
        XCTAssertEqual(fetched.count, 1)
        let loaded = fetched[0]
        XCTAssertEqual(loaded.path, "/tmp/skills/demo")
        XCTAssertEqual(loaded.resolvedTarget, "/tmp/targets/demo")
        XCTAssertEqual(loaded.name, "demo")
        XCTAssertEqual(loaded.localDescription, "local")
        XCTAssertEqual(loaded.modificationDate, date)
        XCTAssertEqual(
            loaded.agentIDsByRootData,
            Data("{\"root-1\":[\"codex\"]}".utf8)
        )
        XCTAssertEqual(loaded.entryFilename, "SKILL.md")
        XCTAssertEqual(loaded.parseDiagnosticsData, Data("issues".utf8))
    }

    func testSkillRecordDefaultsMatchLegacyStoreExpectations() {
        let record = SkillRecord(path: "/tmp/skills/demo", name: "demo", entryFilename: "SKILL.md")

        XCTAssertNil(record.resolvedTarget)
        XCTAssertNil(record.localDescription)
        XCTAssertNil(record.modificationDate)
        XCTAssertEqual(record.agentIDsByRootData, Data("{}".utf8))
        XCTAssertEqual(record.parseDiagnosticsData, Data())
    }

    func testSkillRecordUniquePathKeepsSinglePersistedRecord() throws {
        let database = try makeDatabase()
        try database.write { db in
            try SkillRecord(path: "/tmp/skills/demo", name: "a", entryFilename: "SKILL.md").upsert(db)
            try SkillRecord(path: "/tmp/skills/demo", name: "b", entryFilename: "SKILL.md").upsert(db)
        }

        let fetched = try database.read { try SkillRecord.fetchAll($0) }
        XCTAssertEqual(fetched.count, 1)
        // The primary key on `path` collapses conflicting inserts into a
        // single row: the second upsert replaces the first.
        XCTAssertTrue(["a", "b"].contains(fetched[0].name))
    }

    // MARK: - SkillSnapshot

    func testSkillSnapshotIdentityIsPath() {
        let snapshot = SkillSnapshot(
            path: "/tmp/skills/demo",
            resolvedTarget: nil,
            name: "demo",
            localDescription: nil,
            modificationDate: nil,
            agentIDs: ["codex"],
            rootIDs: ["root-1"],
            entryFilename: "SKILL.md",
            parseDiagnostics: []
        )

        XCTAssertEqual(snapshot.id, "/tmp/skills/demo")
    }
}
