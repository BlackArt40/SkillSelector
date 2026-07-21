import Foundation
import SwiftData
import XCTest
@testable import SkillSelectorCore

final class SkillIndexTests: XCTestCase {

    func testSetCustomDescriptionTrimsPersistsAndClearsOverride() throws {
        let index = try makeIndex()
        let path = "/tmp/project/.agents/skills/demo"
        try index.apply(
            report: report(
                rootID: "project",
                availability: .available,
                installations: [skill(path: path)]
            )
        )

        let customized = try index.setCustomDescription(path: path, value: "  My summary\n")
        XCTAssertEqual(customized.customDescription, "My summary")
        XCTAssertEqual(try index.skills().first?.customDescription, "My summary")

        let restored = try index.setCustomDescription(path: path, value: " \n\t ")
        XCTAssertNil(restored.customDescription)
        XCTAssertNil(try index.skills().first?.customDescription)
    }

    func testSetCustomDescriptionThrowsTypedNotFoundError() throws {
        let index = try makeIndex()

        XCTAssertThrowsError(try index.setCustomDescription(path: "/missing", value: "summary")) { error in
            XCTAssertEqual(error as? SkillIndexError, .skillNotFound(path: "/missing"))
        }
    }

    func testCopyOperationMetadataCreatesIndependentPathValues() throws {
        let index = try makeIndex()
        let source = "/tmp/project/.agents/skills/source"
        let destination = "/tmp/project/.agents/skills/destination"
        try index.apply(report: report(
            rootID: "project",
            availability: .available,
            installations: [skill(path: source), skill(path: destination)]
        ))
        _ = try index.setCustomDescription(path: source, value: "Source custom")
        let metadata = SkillAppMetadata(customDescription: "Source custom")

        try index.applyOperationMetadataTransfer(.copy(metadata), to: destination)
        _ = try index.setCustomDescription(path: source, value: "Changed later")

        let destinationSnapshot = try XCTUnwrap(index.skills().first { $0.path == destination })
        XCTAssertEqual(destinationSnapshot.customDescription, "Source custom")
    }

    func testMoveOperationMetadataCanApplyAfterRefreshRemovedSource() throws {
        let index = try makeIndex()
        let source = "/tmp/project/.agents/skills/source"
        let destination = "/tmp/project/.agents/skills/destination"
        try index.apply(report: report(
            rootID: "project",
            availability: .available,
            installations: [skill(path: source)]
        ))
        _ = try index.setCustomDescription(path: source, value: "Moved custom")
        let transfer = FileOperationMetadataTransfer.move(SkillAppMetadata(customDescription: "Moved custom"))

        try index.apply(report: report(
            rootID: "project",
            availability: .available,
            installations: [skill(path: destination)]
        ))
        try index.applyOperationMetadataTransfer(transfer, to: destination)

        XCTAssertFalse(try index.skills().contains { $0.path == source })
        let moved = try XCTUnwrap(index.skills().first { $0.path == destination })
        XCTAssertEqual(moved.customDescription, "Moved custom")
    }

    func testUnavailableRootRetainsRecordsAndMarksThemUnavailable() throws {
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

        let snapshot = try XCTUnwrap(index.skills().first)
        XCTAssertEqual(snapshot.availability, .unavailable)
        XCTAssertEqual(snapshot.unavailableReason, "bookmark stale")
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
        XCTAssertEqual(snapshot.availability, .available)
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
        XCTAssertEqual(snapshot.availability, .available)
    }

    func testNewRecordStoresDecodableEmptyProvenanceMap() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let record = SkillRecord(path: "/tmp/new", name: "new", entryFilename: "SKILL.md")
        context.insert(record)
        try context.save()

        let saved = try context.fetch(FetchDescriptor<SkillRecord>()).first { $0.path == "/tmp/new" }
        XCTAssertEqual(try JSONDecoder().decode([String: Set<String>].self, from: try XCTUnwrap(saved?.agentIDsByRootData)), [:])
    }

    func testLegacyNilDiscoveredSourceBindingsDecodeAsEmpty() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let record = SkillRecord(
            path: "/tmp/legacy",
            name: "legacy",
            entryFilename: "SKILL.md"
        )
        context.insert(record)
        try context.save()

        let snapshot = try XCTUnwrap(try SkillIndex(container: container).skills().first)
        // discoveredSourceBindings removed
    }

    func testCorruptProvenanceFailsQueriesAndReconciliation() throws {
        let container = try makeContainer()
        let index = SkillIndex(container: container)
        try index.apply(
            report: report(
                rootID: "project",
                availability: .available,
                installations: [skill(path: "/tmp/project/.agents/skills/demo")]
            )
        )
        let context = ModelContext(container)
        let record = try XCTUnwrap(try context.fetch(FetchDescriptor<SkillRecord>()).first)
        record.agentIDsByRootData = Data("not-json".utf8)
        try context.save()

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

    private func makeIndex() throws -> SkillIndex {
        SkillIndex(container: try makeContainer())
    }

    private func makeContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: SkillRecord.self,
            AuthorizedRootRecord.self,
            configurations: configuration
        )
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
