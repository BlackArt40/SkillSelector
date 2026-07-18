import Foundation
import XCTest
@testable import SkillSelectorCore

final class DocumentLoadIdentityTests: XCTestCase {
    func testEveryDocumentAccessFieldChangesIdentity() {
        let baseline = snapshot()
        let identity = DocumentLoadIdentity(snapshot: baseline)
        let changed = [
            snapshot(path: "/other"),
            snapshot(entryFilename: "AGENT.md"),
            snapshot(resolvedTarget: "/resolved/other"),
            snapshot(modificationDate: Date(timeIntervalSince1970: 2)),
            snapshot(availability: .unavailable),
            snapshot(rootIDs: ["other-root"]),
        ]

        for snapshot in changed {
            XCTAssertNotEqual(DocumentLoadIdentity(snapshot: snapshot), identity)
        }
    }

    func testRootOrderDoesNotChangeIdentityAndDescriptionFieldsAreIgnored() {
        let baseline = snapshot(rootIDs: ["a", "b"])
        let reorderedAndDescribed = snapshot(
            rootIDs: ["b", "a"],
            customDescription: "Custom",
            localDescription: "Local"
        )

        XCTAssertEqual(
            DocumentLoadIdentity(snapshot: baseline),
            DocumentLoadIdentity(snapshot: reorderedAndDescribed)
        )
    }

    private func snapshot(
        path: String = "/skill",
        entryFilename: String = "SKILL.md",
        resolvedTarget: String? = "/resolved/skill",
        modificationDate: Date? = Date(timeIntervalSince1970: 1),
        availability: SkillAvailability = .available,
        rootIDs: [String] = ["root"],
        customDescription: String? = nil,
        localDescription: String? = nil
    ) -> SkillSnapshot {
        SkillSnapshot(
            path: path,
            resolvedTarget: resolvedTarget,
            name: "demo",
            localDescription: localDescription,
            enrichedDescription: nil,
            enrichedDescriptionProvenance: nil,
            customDescription: customDescription,
            digest: nil,
            modificationDate: modificationDate,
            availability: availability,
            unavailableReason: nil,
            sourceBinding: nil,
            agentIDs: ["cursor"],
            rootIDs: rootIDs,
            entryFilename: entryFilename,
            parseDiagnostics: []
        )
    }
}
