import Foundation
import XCTest
@testable import SkillSelectorCore

final class SkillComparisonTests: XCTestCase {
    private func document(
        _ fields: [String: String]
    ) -> ParsedSkillDocument {
        ParsedSkillDocument(fields: fields)
    }

    private func state(
        _ entries: [(path: String, size: Int64?)]
    ) -> SkillScanState {
        SkillScanState(
            entryFilename: "SKILL.md",
            resolvedTarget: nil,
            entries: entries.map { entry in
                SkillScanState.Entry(
                    relativePath: entry.path,
                    kind: .file,
                    size: entry.size,
                    modificationDate: nil,
                    symlinkDestination: nil
                )
            }
        )
    }

    func testIdenticalCopiesCompareEqual() {
        let comparison = SkillComparisonBuilder.compare(
            leftPath: "/a",
            rightPath: "/b",
            leftDocument: document(["name": "Twin", "description": "same"]),
            rightDocument: document(["name": "Twin", "description": "same"]),
            leftBody: "# Heading\n\nBody line.",
            rightBody: "# Heading\n\nBody line.",
            leftState: state([(".", 120), ("SKILL.md", 120)]),
            rightState: state([(".", 120), ("SKILL.md", 120)])
        )
        XCTAssertTrue(comparison.bodiesAreIdentical)
        XCTAssertTrue(comparison.frontmatter.allSatisfy { !$0.isDifferent })
        XCTAssertTrue(comparison.files.allSatisfy { $0.difference == .identical })
    }

    func testFrontmatterUnionIncludesMissingKeysAsDifferences() {
        let comparison = SkillComparisonBuilder.compare(
            leftPath: "/a",
            rightPath: "/b",
            leftDocument: document(["name": "Alpha", "shared": "one"]),
            rightDocument: document(["name": "Beta", "extra": "value"]),
            leftBody: "same",
            rightBody: "same",
            leftState: state([(".", 1)]),
            rightState: state([(".", 1)])
        )
        let fields: [String: SkillComparison.FrontmatterField] = Dictionary(
            uniqueKeysWithValues: comparison.frontmatter.map { ($0.key, $0) }
        )
        XCTAssertEqual(Set(fields.keys), ["name", "shared", "extra"])
        XCTAssertTrue(fields["name"]!.isDifferent)
        XCTAssertTrue(fields["shared"]!.isDifferent, "absent on the right counts as a difference")
        XCTAssertNil(fields["shared"]!.right)
        XCTAssertEqual(fields["extra"]!.right, "value")
        XCTAssertTrue(fields["extra"]!.isDifferent)
    }

    func testBlankFrontmatterValuesNormalizeToMissing() {
        let comparison = SkillComparisonBuilder.compare(
            leftPath: "/a",
            rightPath: "/b",
            leftDocument: document(["name": "Alpha", "note": "   "]),
            rightDocument: document(["name": "Alpha", "note": ""]),
            leftBody: "same",
            rightBody: "same",
            leftState: state([(".", 1)]),
            rightState: state([(".", 1)])
        )
        let note = comparison.frontmatter.first { $0.key == "note" }
        XCTAssertEqual(note?.left, nil)
        XCTAssertEqual(note?.right, nil)
        XCTAssertFalse(note!.isDifferent)
    }

    func testBodyDifferencesSurfaceAsLineDiff() {
        let comparison = SkillComparisonBuilder.compare(
            leftPath: "/a",
            rightPath: "/b",
            leftDocument: document([:]),
            rightDocument: document([:]),
            leftBody: "keep\nremove\nkeep",
            rightBody: "keep\nadd\nkeep",
            leftState: state([(".", 1)]),
            rightState: state([(".", 1)])
        )
        XCTAssertFalse(comparison.bodiesAreIdentical)
        XCTAssertEqual(comparison.bodyDiff.removedCount, 1)
        XCTAssertEqual(comparison.bodyDiff.addedCount, 1)
    }

    func testFileDifferencesClassify() {
        let comparison = SkillComparisonBuilder.compare(
            leftPath: "/a",
            rightPath: "/b",
            leftDocument: document([:]),
            rightDocument: document([:]),
            leftBody: "same",
            rightBody: "same",
            leftState: state([
                ("left-only.txt", 10),
                ("different-size.txt", 10),
                ("same.txt", 10),
                ("SKILL.md", 5),
            ]),
            rightState: state([
                ("right-only.txt", 10),
                ("different-size.txt", 20),
                ("same.txt", 10),
                ("SKILL.md", 5),
            ])
        )
        let byPath: [String: SkillComparison.FileDifference] = Dictionary(
            uniqueKeysWithValues: comparison.files.map { ($0.relativePath, $0.difference) }
        )
        XCTAssertEqual(byPath["left-only.txt"], .leftOnly)
        XCTAssertEqual(byPath["right-only.txt"], .rightOnly)
        XCTAssertEqual(byPath["different-size.txt"], .sizeDiffers)
        XCTAssertEqual(byPath["same.txt"], .identical)
        XCTAssertEqual(byPath["SKILL.md"], .identical)
    }

    func testSymlinkDestinationChangeCountsAsKindMismatch() {
        func linkState(_ destination: String) -> SkillScanState {
            SkillScanState(
                entryFilename: "SKILL.md",
                resolvedTarget: nil,
                entries: [
                    SkillScanState.Entry(
                        relativePath: "linked",
                        kind: .symbolicLink,
                        size: nil,
                        modificationDate: nil,
                        symlinkDestination: destination
                    )
                ]
            )
        }
        let comparison = SkillComparisonBuilder.compare(
            leftPath: "/a",
            rightPath: "/b",
            leftDocument: document([:]),
            rightDocument: document([:]),
            leftBody: "same",
            rightBody: "same",
            leftState: linkState("/shared/target"),
            rightState: linkState("/other/target")
        )
        XCTAssertEqual(comparison.files.first?.difference, .kindMismatch)
    }
}
