import Foundation
import XCTest
@testable import SkillSelectorCore

final class FileOperationPlanTests: XCTestCase {
    func testRequestStandardizesSourceAndDestinationURLs() {
        let request = FileOperationRequest(
            operation: .copy,
            sourceURL: URL(fileURLWithPath: "/tmp/./skills/../skills/demo"),
            resolvedSourceURL: URL(fileURLWithPath: "/tmp/target/../target/demo"),
            sourceEntryFilename: "SKILL.md",
            destinationRootURL: URL(fileURLWithPath: "/tmp/dest/../dest")
        )

        XCTAssertEqual(request.sourceURL.path, "/tmp/skills/demo")
        XCTAssertEqual(request.resolvedSourceURL?.path, "/tmp/target/demo")
        XCTAssertEqual(request.destinationRootURL?.path, "/tmp/dest")
    }

    func testIndexedSkillAliasStandardizesPathsAndSortsRootIDs() {
        let alias = IndexedSkillAlias(
            path: "/tmp/./skills/demo",
            resolvedTarget: "/tmp/./targets/demo",
            rootIDs: ["root-b", "root-a"]
        )

        XCTAssertEqual(alias.path, "/tmp/skills/demo")
        XCTAssertEqual(alias.resolvedTarget, "/tmp/targets/demo")
        XCTAssertEqual(alias.rootIDs, ["root-a", "root-b"])
    }

    func testIndexedSkillAliasWithoutResolvedTargetStaysNil() {
        let alias = IndexedSkillAlias(path: "/tmp/skills/demo", resolvedTarget: nil)

        XCTAssertNil(alias.resolvedTarget)
        XCTAssertEqual(alias.rootIDs, [])
    }

    func testConfirmationTokensAreUniqueAndNotInterchangeable() {
        let first = ConfirmationToken()
        let second = ConfirmationToken()

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first, first)
    }

    func testConflictPolicyCoversAllExpectedCases() {
        XCTAssertEqual(
            Set(FileConflictPolicy.allCases),
            [.fail, .keepBoth, .replace, .cancel]
        )
    }

    func testMetadataTransferCodableRoundTrip() throws {
        let cases: [FileOperationMetadataTransfer] = [
            .none,
            .copy(SkillAppMetadata(customDescription: "copied notes")),
            .move(SkillAppMetadata(customDescription: nil)),
        ]
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for value in cases {
            XCTAssertEqual(try decoder.decode(
                FileOperationMetadataTransfer.self,
                from: encoder.encode(value)
            ), value)
        }
    }

    func testOperationKindCodableRoundTrip() throws {
        let kinds: [FileOperationKind] = [.copy, .move, .delete, .createSymbolicLink]
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for kind in kinds {
            XCTAssertEqual(try decoder.decode(
                FileOperationKind.self,
                from: encoder.encode(kind)
            ), kind)
        }
    }

    func testResultCarriesOutcomeAndRefreshRoots() {
        let result = FileOperationResult(
            outcome: .completed,
            sourceURL: URL(fileURLWithPath: "/tmp/source"),
            destinationURL: URL(fileURLWithPath: "/tmp/dest/source"),
            refreshRootIDs: ["root-1"],
            metadataTransfer: .copy(SkillAppMetadata(customDescription: "notes"))
        )

        XCTAssertEqual(result.outcome, .completed)
        XCTAssertEqual(result.refreshRootIDs, ["root-1"])
        XCTAssertEqual(
            result.metadataTransfer,
            .copy(SkillAppMetadata(customDescription: "notes"))
        )

        let cancelled = FileOperationResult(
            outcome: .cancelled,
            sourceURL: URL(fileURLWithPath: "/tmp/source"),
            destinationURL: nil,
            refreshRootIDs: [],
            metadataTransfer: .none
        )
        XCTAssertEqual(cancelled.outcome, .cancelled)
        XCTAssertNil(cancelled.destinationURL)
    }
}
