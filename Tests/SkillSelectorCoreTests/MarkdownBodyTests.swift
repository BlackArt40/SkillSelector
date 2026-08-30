import SkillSelectorCore
import XCTest
@testable import SkillSelector

/// Tests for the Textual-backed Markdown pipeline.
///
/// Rendering itself now belongs to the Textual dependency, so these tests
/// pin the parts that are still app-owned and pure:
///
/// - **body extraction** — the `FrontmatterParser.bodyLines` boundary
///   detection the three document views feed the renderer with (formerly
///   `MarkdownRenderer.extractBody`);
/// - **soft-break hardening** — `MarkdownBody.hardenedText`, which keeps
///   CommonMark's "single newline → space" from jamming source line
///   structure (fenced code is left untouched);
/// - **link policy** — `MarkdownLinkPolicy.isAllowedLink`, the http/https
///   gate applied at click time.
final class MarkdownBodyTests: XCTestCase {
    // MARK: Body extraction (FrontmatterParser.bodyLines)

    func testExtractBodyReturnsAllLinesWithoutFrontmatter() {
        let source = "# Title\n\nSome text"

        XCTAssertEqual(FrontmatterParser.bodyLines(from: source), ["# Title", "", "Some text"])
    }

    func testExtractBodyStripsFrontmatterBlock() {
        let source = "---\nname: demo\ndescription: text\n---\n# Body\ncontent"

        XCTAssertEqual(FrontmatterParser.bodyLines(from: source), ["# Body", "content"])
    }

    func testExtractBodyToleratesWhitespaceAroundDelimiters() {
        let source = "  ---  \nname: demo\n --- \nbody"

        XCTAssertEqual(FrontmatterParser.bodyLines(from: source), ["body"])
    }

    func testExtractBodyWithUnclosedFrontmatterKeepsSourceAsBody() {
        let source = "---\nname: demo\nno closing delimiter"

        XCTAssertEqual(
            FrontmatterParser.bodyLines(from: source),
            ["---", "name: demo", "no closing delimiter"]
        )
    }

    func testExtractBodyWithOnlyFrontmatterReturnsEmpty() {
        let source = "---\nname: demo\n---"

        XCTAssertEqual(FrontmatterParser.bodyLines(from: source), [])
    }

    func testExtractBodyIgnoresLeadingContentBeforeOpeningDelimiter() {
        // "---" is only a frontmatter delimiter on the very first line.
        let source = "# Title\n---\nnot frontmatter"

        XCTAssertEqual(
            FrontmatterParser.bodyLines(from: source),
            ["# Title", "---", "not frontmatter"]
        )
    }

    // MARK: Soft-break hardening (MarkdownBody.hardenedText)

    /// A single newline between two non-empty lines becomes a hard break
    /// (two trailing spaces) so the parser preserves the source line
    /// structure instead of folding "workflow: …\ntopic: …" into one line.
    func testHardenedTextHardensSingleNewlines() {
        let lines = ["workflow: alpha", "topic: beta", "Paragraph."]

        XCTAssertEqual(
            MarkdownBody.hardenedText(from: lines),
            "workflow: alpha  \ntopic: beta  \nParagraph."
        )
    }

    /// Lines inside fenced code blocks keep their exact content — trailing
    /// spaces there are meaningful and must not be added.
    func testHardenedTextLeavesFencesUntouched() {
        let lines = ["```", "line one", "line two", "```", "", "After."]

        XCTAssertEqual(
            MarkdownBody.hardenedText(from: lines),
            "```\nline one\nline two\n```\n\nAfter."
        )
    }

    /// Blank lines break the hardening run, and the final line (no following
    /// content) is never hardened.
    func testHardenedTextSkipsBlankAndTrailingLines() {
        let lines = ["a", "", "b"]

        XCTAssertEqual(MarkdownBody.hardenedText(from: lines), "a\n\nb")
    }

    // MARK: Link policy (MarkdownLinkPolicy.isAllowedLink)

    func testLinkPolicyAllowsHttpAndHttps() {
        XCTAssertTrue(MarkdownLinkPolicy.isAllowedLink(URL(string: "https://example.com")!))
        XCTAssertTrue(MarkdownLinkPolicy.isAllowedLink(URL(string: "http://example.com")!))
    }

    func testLinkPolicyRejectsNonHttpSchemes() {
        XCTAssertFalse(MarkdownLinkPolicy.isAllowedLink(URL(fileURLWithPath: "/tmp/pwn.command")))
        XCTAssertFalse(MarkdownLinkPolicy.isAllowedLink(URL(string: "shortcuts://run")!))
        XCTAssertFalse(MarkdownLinkPolicy.isAllowedLink(URL(string: "file:///etc/passwd")!))
    }
}
