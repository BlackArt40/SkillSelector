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

    func testBuildReturnsNilForWhitespaceOnlyInput() {
        XCTAssertNil(MarkdownRenderer.buildAttributedString(from: ["", "   "]))
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

    func testAdjacentHeadingsKeepTheirLineBreaks() {
        // Regression guard: the parser marks each heading as a separate block
        // but omits the newline between them, which would jam them on one line.
        let rendered = MarkdownRenderer.buildAttributedString(from: [
            "## Components", "### Spacing And Layout",
        ])

        XCTAssertTrue(plainText(rendered).contains("Components\nSpacing And Layout"))
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

        XCTAssertEqual(plainText(rendered), "line one\n")
    }

    func testUnorderedAndOrderedListsRenderItemsWithoutMarkers() {
        // The system parser consumes the bullet/number markers into
        // presentation intent; the item text is what remains.
        let rendered = MarkdownRenderer.buildAttributedString(from: [
            "- first", "* second", "1. third", "12. fourth",
        ])

        let text = plainText(rendered)
        XCTAssertTrue(text.contains("first"))
        XCTAssertTrue(text.contains("second"))
        XCTAssertTrue(text.contains("third"))
        XCTAssertTrue(text.contains("fourth"))
        XCTAssertFalse(text.contains("- first"))
        XCTAssertFalse(text.contains("* second"))
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

    func testUnterminatedBoldPairRendersLiterally() {
        // The system parser keeps an unterminated emphasis marker as text.
        let rendered = MarkdownRenderer.buildAttributedString(from: ["a **bold"])

        XCTAssertEqual(plainText(rendered), "a **bold\n")
    }

    // MARK: - Block separation

    func testParagraphFollowedByCodeBlockKeepsLineBreak() {
        // Regression guard: the parser drops the newline between a paragraph
        // and a following code block, jamming "Example:firecrawl …" together.
        let rendered = MarkdownRenderer.buildAttributedString(from: [
            "Example:", "```bash", "firecrawl scrape --pretty &", "wait", "```",
        ])

        XCTAssertTrue(plainText(rendered).contains("Example:\nfirecrawl scrape --pretty"))
    }

    func testInlineCodeDoesNotSplitParagraph() {
        // Regression guard: inline code spans share the paragraph's element
        // identity, so the newline must land at the paragraph's end only.
        let rendered = MarkdownRenderer.buildAttributedString(from: [
            "Combining `branding` and `images` costs one credit.",
            "",
            "If the screenshot returns a remote URL, download it.",
        ])

        let text = plainText(rendered)
        XCTAssertTrue(text.contains("Combining branding and images costs one credit.\n"))
        XCTAssertTrue(text.contains("credit.\nIf the screenshot"))
    }

    func testListItemWithInlineCodeGetsSingleMarker() {
        // Regression guard: marker must be inserted once per item, at the
        // item's first run — not at every inline-code run inside it.
        let rendered = MarkdownRenderer.buildAttributedString(from: [
            "1. The `branding` and `images` formats.",
        ])

        XCTAssertEqual(plainText(rendered), "  1. The branding and images formats.\n")
    }

    func testListBulletsAreIndentedAndTinted() {
        // Regression guard: the bullet must read as a list glyph — indented
        // and muted — rather than body text.
        let rendered = MarkdownRenderer.buildAttributedString(from: [
            "- first", "- second",
        ])

        let text = plainText(rendered)
        XCTAssertEqual(text, "  •  first\n  •  second\n")

        let bullets = rendered?.runs.filter { $0.foregroundColor == AppTheme.muted } ?? []
        XCTAssertFalse(bullets.isEmpty)
    }
}

extension MarkdownRendererTests {
    func testMarkdownFencedBlockStaysLiteralCode() {
        // ```markdown templates render as code blocks like any other fence:
        // their "#"/"##" stay literal text on the panel background.
        let rendered = MarkdownRenderer.buildAttributedString(from: [
            "```markdown", "# Literature Review: [Topic]", "",
            "## Abstract", "[2-3 paragraph summary]", "```",
        ])

        let text = plainText(rendered)
        XCTAssertTrue(text.contains("# Literature Review: [Topic]"))
        XCTAssertTrue(text.contains("## Abstract"))
        XCTAssertTrue(text.contains("[2-3 paragraph summary]"))
        // Headings are not consumed: the literal "##" marker survives.
        XCTAssertTrue(text.contains("## Abstract\n[2-3 paragraph summary]"))
    }

    func testBashFencedBlockStaysLiteralCode() {
        let rendered = MarkdownRenderer.buildAttributedString(from: [
            "```bash", "echo \"# not a heading\"", "```",
        ])

        let text = plainText(rendered)
        XCTAssertTrue(text.contains("# not a heading"))
    }
}

extension MarkdownRendererTests {
    func testInlineCodeIsTintedAmber() {
        let rendered = MarkdownRenderer.buildAttributedString(from: ["run `make test` now"])

        let codeRun = rendered?.runs.first {
            $0.inlinePresentationIntent?.contains(.code) == true
        }
        XCTAssertEqual(codeRun?.foregroundColor, AppTheme.codeInline)
    }

    func testBlockquoteIsTintedViolet() {
        let rendered = MarkdownRenderer.buildAttributedString(from: ["> quoted guidance"])

        let quoteRun = rendered?.runs.first { run in
            run.presentationIntent?.components.contains { component in
                if case .blockQuote = component.kind { return true }
                return false
            } == true
        }
        XCTAssertEqual(quoteRun?.foregroundColor, AppTheme.blockquote)
    }

    func testTopLevelHeadingUsesAccent() {
        let rendered = MarkdownRenderer.buildAttributedString(from: ["# Main Title"])

        let headingRun = rendered?.runs.first { run in
            run.presentationIntent?.components.contains { component in
                if case .header = component.kind { return true }
                return false
            } == true
        }
        XCTAssertEqual(headingRun?.foregroundColor, AppTheme.accent)
    }
}

extension MarkdownRendererTests {
    func testCodeBlockUsesContrastingPanelAndForegroundText() {
        let rendered = MarkdownRenderer.buildAttributedString(from: [
            "```bash", "echo hi", "```",
        ])

        let blockRun = rendered?.runs.first { run in
            run.presentationIntent?.components.contains { component in
                if case .codeBlock = component.kind { return true }
                return false
            } == true
        }
        XCTAssertEqual(blockRun?.backgroundColor, AppTheme.codeBlockBackground)
        XCTAssertEqual(blockRun?.foregroundColor, AppTheme.foreground)
    }
}

extension MarkdownRendererTests {
    func testSoftLineBreaksWithinParagraphArePreserved() {
        // Regression guard: "workflow:\ntopic:\ntarget_count:" must stay on
        // separate lines instead of being folded into one jammed line.
        let rendered = MarkdownRenderer.buildAttributedString(from: [
            "workflow: firecrawl-research-papers",
            "topic: [topic]",
            "target_count: [number]",
        ])

        XCTAssertEqual(
            plainText(rendered),
            "workflow: firecrawl-research-papers\ntopic: [topic]\ntarget_count: [number]\n"
        )
    }

    func testSoftBreakHardeningSkipsFencedCode() {
        // Regression guard: hardening must not add trailing spaces to code
        // lines inside fences.
        let rendered = MarkdownRenderer.buildAttributedString(from: [
            "```bash", "echo a", "echo b", "```",
        ])

        XCTAssertTrue(plainText(rendered).contains("echo a\necho b"))
    }
}
