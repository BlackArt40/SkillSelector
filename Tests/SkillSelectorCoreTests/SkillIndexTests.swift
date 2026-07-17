import Foundation
import SwiftData
import XCTest
@testable import SkillSelectorCore

final class SkillIndexTests: XCTestCase {
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
            agentIDs: ["cursor"],
            rootIDs: ["home", "project"]
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
        XCTAssertEqual(snapshot.availability, .available)
    }

    private func makeIndex() throws -> SkillIndex {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: SkillRecord.self,
            AuthorizedRootRecord.self,
            configurations: configuration
        )
        return SkillIndex(container: container)
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
            rootIDs: rootIDs,
            entryFilename: "SKILL.md",
            entryModificationDate: date
        )
    }
}
