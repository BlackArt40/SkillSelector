import XCTest
@testable import SkillSelector

final class MarkdownRendererTests: XCTestCase {
    private func plainText(_ rendered: AttributedString?) -> String {
        rendered.map { String($0.characters) } ?? ""
    }

    // MARK: - extractBody

    func testExtractBodyReturnsAllLinesWithoutFrontmatter() {
        let source = "# Title\n\nSome text"

        XCTAssertEqual(MarkdownRenderer.extractBody(source), ["# Title", "", "Some text"])
    }

    func testExtractBodyStripsFrontmatterBlock() {
        let source = "---\nname: demo\ndescription: text\n---\n# Body\ncontent"

        XCTAssertEqual(MarkdownRenderer.extractBody(source), ["# Body", "content"])
    }

    func testExtractBodyToleratesWhitespaceAroundDelimiters() {
        let source = "  ---  \nname: demo\n --- \nbody"

        XCTAssertEqual(MarkdownRenderer.extractBody(source), ["body"])
    }

    func testExtractBodyWithUnclosedFrontmatterKeepsSourceAsBody() {
        let source = "---\nname: demo\nno closing delimiter"

        XCTAssertEqual(
            MarkdownRenderer.extractBody(source),
            ["---", "name: demo", "no closing delimiter"]
        )
    }

    func testExtractBodyWithOnlyFrontmatterReturnsEmpty() {
        let source = "---\nname: demo\n---"

        XCTAssertEqual(MarkdownRenderer.extractBody(source), [])
    }

    func testExtractBodyIgnoresLeadingContentBeforeOpeningDelimiter() {
        // "---" is only a frontmatter delimiter on the very first line.
        let source = "# Title\n---\nnot frontmatter"

        XCTAssertEqual(MarkdownRenderer.extractBody(source), ["# Title", "---", "not frontmatter"])
    }

    // MARK: - buildAttributedString

    func testBuildReturnsNilForEmptyInput() {
        XCTAssertNil(MarkdownRenderer.buildAttributedString(from: []))
    }

    func testBuildRendersBlankLinesAsEmptyParagraphs() {
        let rendered = MarkdownRenderer.buildAttributedString(from: ["", "   "])

        XCTAssertEqual(plainText(rendered), "\n\n")
    }

    func testPlainParagraphPassesThrough() {
        let rendered = MarkdownRenderer.buildAttributedString(from: ["hello world"])

        XCTAssertEqual(plainText(rendered), "hello world\n")
    }

    func testHeadingsRenderTheirText() {
        let rendered = MarkdownRenderer.buildAttributedString(from: [
            "# One", "## Two", "### Three", "#### Four",
        ])

        let text = plainText(rendered)
        XCTAssertTrue(text.contains("One"))
        XCTAssertTrue(text.contains("Two"))
        XCTAssertTrue(text.contains("Three"))
        XCTAssertTrue(text.contains("Four"))
        XCTAssertFalse(text.contains("#"))
    }

    func testCodeBlockKeepsContentWithoutTogglingOnInnerText() {
        let rendered = MarkdownRenderer.buildAttributedString(from: [
            "```", "let x = 1", "```", "after",
        ])

        let text = plainText(rendered)
        XCTAssertTrue(text.contains("let x = 1"))
        XCTAssertTrue(text.contains("after"))
        XCTAssertFalse(text.contains("```"))
    }

    func testUnclosedCodeBlockRendersRemainingLinesAsCode() {
        let rendered = MarkdownRenderer.buildAttributedString(from: ["```", "line one"])

        XCTAssertEqual(plainText(rendered), "  line one\n")
    }

    func testUnorderedAndOrderedListsRenderBulletsAndNumbers() {
        let rendered = MarkdownRenderer.buildAttributedString(from: [
            "- first", "* second", "1. third", "12. fourth",
        ])

        XCTAssertEqual(
            plainText(rendered),
            "  • first\n  • second\n  1.  third\n12. fourth\n"
        )
    }

    func testTableRendersRowsAndSkipsSeparatorRow() {
        let rendered = MarkdownRenderer.buildAttributedString(from: [
            "| Name | Value |",
            "| --- | --- |",
            "| alpha | 1 |",
        ])

        let text = plainText(rendered)
        XCTAssertTrue(text.contains("Name"))
        XCTAssertTrue(text.contains("Value"))
        XCTAssertTrue(text.contains("alpha"))
        XCTAssertFalse(text.contains("---"))
    }

    func testSinglePipeLineIsNotTreatedAsTable() {
        let rendered = MarkdownRenderer.buildAttributedString(from: ["| lonely"])

        XCTAssertEqual(plainText(rendered), "| lonely\n")
    }

    func testInlineMarkdownLinkProducesLinkAttribute() {
        let rendered = MarkdownRenderer.buildAttributedString(from: [
            "see [docs](https://example.com/docs) now",
        ])

        let text = plainText(rendered)
        XCTAssertTrue(text.contains("see docs now"))
        XCTAssertFalse(text.contains("https://example.com/docs"))

        let links = rendered.map { attributed in
            attributed.runs.compactMap(\.link)
        } ?? []
        XCTAssertEqual(links, [URL(string: "https://example.com/docs")!])
    }

    func testInlineCodeLookingLikePathIsNotClickable() {
        // Regression guard: paths used to be rendered as `file://` links, which
        // let a malicious Skill document launch an executable outside the sandbox
        // on a single click — and trained readers to click them.
        let rendered = MarkdownRenderer.buildAttributedString(from: [
            "open `scripts/build.sh` here",
        ])

        let links = rendered.map { attributed in
            attributed.runs.compactMap(\.link)
        } ?? []
        XCTAssertTrue(links.isEmpty)
        XCTAssertTrue(plainText(rendered).contains("scripts/build.sh"))
    }

    // MARK: - Link scheme policy

    func testUnsupportedLinkSchemesAreRenderedInert() {
        let hostileDestinations = [
            "file:///tmp/pwn.command",
            "shortcuts://run-shortcut?name=Exfiltrate",
            "javascript:void0",
            "x-apple-shortcuts://x",
            "FILE:///tmp/pwn.command",
            "//evil.example.com/x",
            "./relative.md",
        ]

        for destination in hostileDestinations {
            let rendered = MarkdownRenderer.buildAttributedString(from: [
                "see [doc](\(destination)) now",
            ])
            let links = rendered.map { attributed in
                attributed.runs.compactMap(\.link)
            } ?? []

            XCTAssertTrue(links.isEmpty, "\(destination) must not be clickable")
            XCTAssertTrue(
                plainText(rendered).contains(destination),
                "\(destination) should still be disclosed as plain text"
            )
        }
    }

    func testWebSchemesRemainClickableRegardlessOfCase() {
        for destination in ["http://example.com", "HTTPS://example.com/docs"] {
            let rendered = MarkdownRenderer.buildAttributedString(from: [
                "see [docs](\(destination)) now",
            ])
            let links = rendered.map { attributed in
                attributed.runs.compactMap(\.link)
            } ?? []

            XCTAssertEqual(links, [URL(string: destination)!])
        }
    }

    func testSanitizedLinkURLAcceptsOnlyWebSchemes() {
        XCTAssertNotNil(MarkdownRenderer.sanitizedLinkURL("https://example.com"))
        XCTAssertNotNil(MarkdownRenderer.sanitizedLinkURL("http://example.com"))
        XCTAssertNil(MarkdownRenderer.sanitizedLinkURL("file:///etc/passwd"))
        XCTAssertNil(MarkdownRenderer.sanitizedLinkURL("shortcuts://run"))
        XCTAssertNil(MarkdownRenderer.sanitizedLinkURL("relative/path.md"))
        XCTAssertNil(MarkdownRenderer.sanitizedLinkURL(""))
    }

    func testIsAllowedLinkMatchesSchemePolicy() {
        XCTAssertTrue(MarkdownRenderer.isAllowedLink(URL(string: "https://example.com")!))
        XCTAssertFalse(MarkdownRenderer.isAllowedLink(URL(fileURLWithPath: "/tmp/pwn.command")))
        XCTAssertFalse(MarkdownRenderer.isAllowedLink(URL(string: "shortcuts://run")!))
    }

    func testInlineCodeWithoutPathShapeHasNoLink() {
        let rendered = MarkdownRenderer.buildAttributedString(from: [
            "run `make test` now",
        ])

        let links = rendered.map { attributed in
            attributed.runs.compactMap(\.link)
        } ?? []
        XCTAssertTrue(links.isEmpty)
        XCTAssertTrue((plainText(rendered)).contains("make test"))
    }

    func testBoldAndItalicMarkersAreConsumed() {
        let rendered = MarkdownRenderer.buildAttributedString(from: [
            "a **bold** b *italic* c",
        ])

        let text = plainText(rendered)
        XCTAssertEqual(text, "a bold b italic c\n")
    }

    func testUnterminatedSingleMarkerRendersLiterally() {
        let rendered = MarkdownRenderer.buildAttributedString(from: ["a *b"])

        XCTAssertEqual(plainText(rendered), "a *b\n")
    }

    func testUnterminatedBoldPairIsConsumedWithoutMarkers() {
        let rendered = MarkdownRenderer.buildAttributedString(from: ["a **bold"])

        XCTAssertEqual(plainText(rendered), "a bold\n")
    }
}
