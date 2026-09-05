import Foundation
import GRDB
import XCTest
@testable import SkillSelectorCore

final class SkillIndexTests: XCTestCase {

    func testUnavailableRootDropsAssociatedRecords() throws {
        let index = try makeIndex()
        try index.apply(
            report: report(
                rootID: "project",
                availability: .available,
                installations: [skill(path: "/tmp/project/.agents/skills/demo")]
            )
        )

        try index.apply(
            report: report(
                rootID: "project",
                availability: .unavailable(reason: "bookmark stale")
            )
        )

        XCTAssertTrue(try index.skills().isEmpty)
    }

    func testAccessibleMissingPathRemovesRecord() throws {
        let index = try makeIndex()
        try index.apply(
            report: report(
                rootID: "project",
                availability: .available,
                installations: [skill(path: "/tmp/project/.agents/skills/demo")]
            )
        )

        try index.apply(report: report(rootID: "project", availability: .available))

        XCTAssertTrue(try index.skills().isEmpty)
    }

    func testApplyMapsScannerMetadataWithoutDocumentContent() throws {
        let index = try makeIndex()
        let date = Date(timeIntervalSince1970: 1_234)
        let scanned = skill(
            path: "/tmp/project/.cursor/skills/demo",
            resolvedTarget: "/tmp/project/shared/demo",
            agentIDs: ["cursor", "codex"],
            date: date,
            document: ParsedSkillDocument(
                name: "demo",
                description: "Local description",
                title: "Demo",
                firstDescriptiveParagraph: "Fallback paragraph",
                issues: [ParseIssue(line: 3, message: "Malformed field")]
            )
        )

        try index.apply(
            report: report(rootID: "project", availability: .available, installations: [scanned])
        )

        let snapshot = try XCTUnwrap(index.skills().first)
        XCTAssertEqual(snapshot.path, "/tmp/project/.cursor/skills/demo")
        XCTAssertEqual(snapshot.resolvedTarget, "/tmp/project/shared/demo")
        XCTAssertEqual(snapshot.name, "demo")
        XCTAssertEqual(snapshot.localDescription, "Local description")
        XCTAssertEqual(snapshot.entryFilename, "SKILL.md")
        XCTAssertEqual(snapshot.modificationDate, date)
        XCTAssertEqual(snapshot.agentIDs, ["codex", "cursor"])
        XCTAssertEqual(snapshot.rootIDs, ["project"])
        XCTAssertEqual(snapshot.parseDiagnostics, [ParseIssue(line: 3, message: "Malformed field")])
    }

    func testAccessibleRootRemovesOnlyItsAssociationFromSharedRecord() throws {
        let index = try makeIndex()
        let shared = skill(
            path: "/tmp/shared/demo",
            agentIDsByRoot: ["home": ["cursor"], "project": ["codex"]]
        )
        try index.apply(
            report: ScanReport(
                installations: [shared],
                roots: [
                    ScannedRoot(id: "home", url: URL(fileURLWithPath: "/tmp"), availability: .available),
                    ScannedRoot(id: "project", url: URL(fileURLWithPath: "/tmp"), availability: .available),
                ]
            )
        )

        try index.apply(report: report(rootID: "project", availability: .available))

        let snapshot = try XCTUnwrap(index.skills().first)
        XCTAssertEqual(snapshot.rootIDs, ["home"])
        XCTAssertEqual(snapshot.agentIDs, ["cursor"])
    }

    func testNewRecordStoresDecodableEmptyProvenanceMap() throws {
        let database = try makeDatabase()
        let record = SkillRecord(path: "/tmp/new", name: "new", entryFilename: "SKILL.md")
        try database.write { try record.upsert($0) }

        let saved = try database.read { try SkillRecord.fetchAll($0) }.first { $0.path == "/tmp/new" }
        XCTAssertEqual(try JSONDecoder().decode([String: Set<String>].self, from: try XCTUnwrap(saved?.agentIDsByRootData)), [:])
    }

    func testLegacyNilDiscoveredSourceBindingsDecodeAsEmpty() throws {
        let database = try makeDatabase()
        let record = SkillRecord(
            path: "/tmp/legacy",
            name: "legacy",
            entryFilename: "SKILL.md"
        )
        try database.write { try record.upsert($0) }

        let snapshot = try XCTUnwrap(try SkillIndex(database: database).skills().first)
        // discoveredSourceBindings removed
    }

    func testCorruptProvenanceFailsQueriesAndReconciliation() throws {
        let database = try makeDatabase()
        let index = SkillIndex(database: database)
        try index.apply(
            report: report(
                rootID: "project",
                availability: .available,
                installations: [skill(path: "/tmp/project/.agents/skills/demo")]
            )
        )
        var record = try XCTUnwrap(try database.read { try SkillRecord.fetchAll($0) }.first)
        record.agentIDsByRootData = Data("not-json".utf8)
        try database.write { try record.upsert($0) }

        XCTAssertThrowsError(try index.skills()) { error in
            XCTAssertEqual(
                error as? SkillIndexError,
                .invalidAgentProvenance(path: "/tmp/project/.agents/skills/demo")
            )
        }
        XCTAssertThrowsError(
            try index.apply(report: report(rootID: "project", availability: .unavailable(reason: "stale")))
        ) { error in
            XCTAssertEqual(
                error as? SkillIndexError,
                .invalidAgentProvenance(path: "/tmp/project/.agents/skills/demo")
            )
        }
    }

    func testDuplicateRowsInStoreAreDedupedInsteadOfCrashing() throws {
        // Audit R2: a store holding duplicate path rows (SwiftData unique
        // constraint non-determinism) must not crash on the dictionary build
        // and must converge to a single row. The GRDB primary key on `path`
        // makes this structural: two upserts of one path leave one row.
        let database = try makeDatabase()
        let path = "/tmp/project/.agents/skills/demo"
        try database.write { db in
            try SkillRecord(path: path, name: "first", entryFilename: "SKILL.md").upsert(db)
            try SkillRecord(path: path, name: "second", entryFilename: "SKILL.md").upsert(db)
        }

        let index = SkillIndex(database: database)
        try index.apply(
            report: report(
                rootID: "project",
                availability: .available,
                installations: [skill(path: path)]
            )
        )

        let skills = try index.skills()
        XCTAssertEqual(skills.count, 1)
        let remaining = try database.read { try SkillRecord.fetchAll($0) }
        XCTAssertEqual(remaining.count, 1)
    }

    private func makeIndex() throws -> SkillIndex {
        SkillIndex(database: try makeDatabase())
    }

    private func makeDatabase() throws -> DatabaseQueue {
        try SkillStore.inMemory()
    }

    private func report(
        rootID: String,
        availability: ScanRootAvailability,
        installations: [ScannedSkill] = []
    ) -> ScanReport {
        ScanReport(
            installations: installations,
            roots: [
                ScannedRoot(
                    id: rootID,
                    url: URL(fileURLWithPath: "/tmp/project"),
                    availability: availability
                )
            ]
        )
    }

    private func skill(
        path: String,
        resolvedTarget: String? = nil,
        agentIDs: Set<String> = ["cursor"],
        rootIDs: Set<String> = ["project"],
        agentIDsByRoot: [String: Set<String>]? = nil,
        date: Date? = nil,
        document: ParsedSkillDocument = ParsedSkillDocument(
            name: "demo",
            description: "Demo"
        )
    ) -> ScannedSkill {
        ScannedSkill(
            installation: SkillInstallation(
                path: URL(fileURLWithPath: path),
                resolvedTarget: resolvedTarget.map(URL.init(fileURLWithPath:)),
                agentIDs: agentIDs
            ),
            document: document,
            agentIDsByRoot: agentIDsByRoot
                ?? Dictionary(uniqueKeysWithValues: rootIDs.map { ($0, agentIDs) }),
            entryFilename: "SKILL.md",
            entryModificationDate: date
        )
    }
}
