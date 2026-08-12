import Foundation
import SwiftData
import XCTest
@testable import SkillSelectorCore

final class PersistenceRecordTests: XCTestCase {
    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: SkillRecord.self,
            AuthorizedRootRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
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
        let context = ModelContext(try makeContainer())
        let record = AuthorizedRootRecord(
            id: "root-1",
            path: "/tmp/roots/project",
            kind: .project,
            bookmarkData: Data("bookmark".utf8)
        )
        context.insert(record)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<AuthorizedRootRecord>())
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
        let context = ModelContext(try makeContainer())
        context.insert(AuthorizedRootRecord(
            id: "same", path: "/tmp/a", kind: .home, bookmarkData: Data()
        ))
        context.insert(AuthorizedRootRecord(
            id: "same", path: "/tmp/b", kind: .project, bookmarkData: Data()
        ))
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<AuthorizedRootRecord>())
        XCTAssertEqual(fetched.count, 1)
        // Which of two conflicting inserts survives is not defined by SwiftData
        // and is not stable across runs, so asserting either direction yields a
        // flaky test. The contract worth pinning down is that the unique
        // constraint collapses them into a single row.
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
        let context = ModelContext(try makeContainer())
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
        context.insert(record)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<SkillRecord>())
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
        let context = ModelContext(try makeContainer())
        context.insert(SkillRecord(path: "/tmp/skills/demo", name: "a", entryFilename: "SKILL.md"))
        context.insert(SkillRecord(path: "/tmp/skills/demo", name: "b", entryFilename: "SKILL.md"))
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<SkillRecord>())
        XCTAssertEqual(fetched.count, 1)
        // As above: the winner of a unique-constraint collision is undefined and
        // observably non-deterministic. Production code never depends on it —
        // `SkillIndex.apply(report:)` fetches and reuses an existing record
        // rather than blind-inserting a duplicate.
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
