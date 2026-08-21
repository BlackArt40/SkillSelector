import XCTest
@testable import SkillSelectorCore

final class FrontmatterParserTests: XCTestCase {
    func testParsesRequiredFieldsAndBlockDescription() {
        let text = """
        ---
        name: release-notes
        description: |
          Draft release notes
          from merged changes.
        ---
        # Release Notes
        """

        let parsed = FrontmatterParser.parse(text)

        XCTAssertEqual(parsed.name, "release-notes")
        XCTAssertEqual(parsed.description, "Draft release notes\nfrom merged changes.")
        XCTAssertEqual(parsed.title, "Release Notes")
        XCTAssertTrue(parsed.issues.isEmpty)
    }

    func testParsesQuotedScalarsFoldedBlocksAndUnknownFields() {
        let text = """
        ---
        name: "quoted-skill"
        description: >
          A description split
          across source lines.
        license: 'Apache-2.0'
        ---
        """

        let parsed = FrontmatterParser.parse(text)

        XCTAssertEqual(parsed.name, "quoted-skill")
        XCTAssertEqual(parsed.description, "A description split across source lines.")
        XCTAssertEqual(parsed.fields["license"], "Apache-2.0")
        XCTAssertTrue(parsed.issues.isEmpty)
    }

    func testIndentedDelimiterRemainsLiteralBlockContent() {
        let parsed = FrontmatterParser.parse(
            "---\nname: delimiter\ndescription: |\n  Before\n  ---\n  After\n---\n# Delimiter"
        )

        XCTAssertEqual(parsed.description, "Before\n---\nAfter")
        XCTAssertEqual(parsed.title, "Delimiter")
        XCTAssertTrue(parsed.issues.isEmpty)
    }

    func testIndentedDelimiterRemainsFoldedBlockContent() {
        let parsed = FrontmatterParser.parse(
            "---\nname: delimiter\ndescription: >\n  Before\n  ---\n  After\n---\n# Delimiter"
        )

        XCTAssertEqual(parsed.description, "Before --- After")
        XCTAssertEqual(parsed.title, "Delimiter")
        XCTAssertTrue(parsed.issues.isEmpty)
    }

    func testExtractsHeadingAndFirstDescriptiveParagraphWithoutFrontmatter() {
        let text = """
        # Repository Tools

        Build and inspect repository metadata
        without changing the working tree.

        ## Commands

        More details.
        """

        let parsed = FrontmatterParser.parse(text)

        XCTAssertNil(parsed.name)
        XCTAssertNil(parsed.description)
        XCTAssertEqual(parsed.title, "Repository Tools")
        XCTAssertEqual(
            parsed.firstDescriptiveParagraph,
            "Build and inspect repository metadata without changing the working tree."
        )
        XCTAssertTrue(parsed.issues.contains { $0.message.contains("frontmatter") })
    }

    func testInvalidFrontmatterRemainsRepresentable() {
        let parsed = FrontmatterParser.parse("---\nname: [broken\n---\n# Broken")

        XCTAssertFalse(parsed.issues.isEmpty)
        XCTAssertEqual(parsed.title, "Broken")
    }

    func testReportsMissingBoundaryAndContinuesExtractingBodyMetadata() {
        let parsed = FrontmatterParser.parse("---\nname: demo\n# Demo\n\nUseful fallback text.")

        XCTAssertFalse(parsed.issues.isEmpty)
        XCTAssertEqual(parsed.title, "Demo")
        XCTAssertEqual(parsed.firstDescriptiveParagraph, "Useful fallback text.")
    }

    func testReportsMissingRequiredFrontmatterFieldsWithoutDiscardingFallbacks() {
        let parsed = FrontmatterParser.parse("---\nname: demo\n---\n# Demo\n\nUseful fallback text.")

        XCTAssertTrue(parsed.issues.contains { $0.message.contains("description") })
        XCTAssertEqual(parsed.name, "demo")
        XCTAssertEqual(parsed.title, "Demo")
        XCTAssertEqual(parsed.firstDescriptiveParagraph, "Useful fallback text.")
    }

    func testBodyParagraphContainingColonIsNotTreatedAsFrontmatter() {
        let parsed = FrontmatterParser.parse(
            "---\nname: usage\ndescription: Local description\n---\n# Usage\n\nUsage: Run this command."
        )

        XCTAssertEqual(parsed.firstDescriptiveParagraph, "Usage: Run this command.")
        XCTAssertTrue(parsed.issues.isEmpty)
    }

    func testOversizedFrontmatterYieldsParseFailureDiagnostic() {
        // Audit R9: a multi-megabyte frontmatter must not reach Yams.compose
        // unbounded; it surfaces a parse-failure diagnostic instead.
        let huge = String(repeating: "key: value\n", count: FrontmatterParser.maximumFrontmatterBytes / 8 + 1)
        let parsed = FrontmatterParser.parse("---\n\(huge)---\n# Body")

        XCTAssertTrue(parsed.issues.contains { $0.message.contains("limit") })
    }

    func testFrontmatterUnderLimitStillParses() {
        let parsed = FrontmatterParser.parse("---\nname: ok\ndescription: fine\n---\n# Body")

        XCTAssertEqual(parsed.name, "ok")
        XCTAssertTrue(parsed.issues.isEmpty)
    }
}
