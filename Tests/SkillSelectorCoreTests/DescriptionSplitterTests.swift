import Foundation
import XCTest
@testable import SkillSelector

/// Regression tests for the sentence splitter used to chunk long skill
/// descriptions before translation. The macOS Translation framework
/// stalls on a single `translate()` call with a long string, so long
/// paragraphs are split at sentence boundaries; the split points must be
/// invisible in the output — no stray delimiters, no introduced spaces.
final class DescriptionSplitterTests: XCTestCase {
    /// The exact text the user reported: "standards?) and" must stay
    /// whole and "asked for?)." must absorb both the paren and the
    /// trailing period — never "asked for?)" + ".".
    func testUserReportedCodeReviewDescription() {
        let text = #"Review the changes since a fixed point (commit, branch, tag, or merge-base) along two axes — Standards (does the code follow this repo's documented coding standards?) and Spec (does the code match what the originating issue/PRD asked for?). Runs both reviews in parallel sub-agents and reports them side by side. Use when the user wants to review a branch, a PR, work-in-progress changes, or asks to "review since X"."#

        let segments = DescriptionSplitter.sentenceSegments(text)

        XCTAssertEqual(segments.count, 4, "问号句、问号+句号句、普通句、引用句应各为一段")
        XCTAssertTrue(segments[0].hasSuffix("coding standards?)"), "? 与 ) 不应分离")
        XCTAssertTrue(segments[1].hasPrefix("and Spec"), "下一段不应残留括号或前导空格")
        XCTAssertTrue(segments[1].hasSuffix("asked for?)."), "?) 与句末 . 应整体保留")
        XCTAssertTrue(segments[2].hasPrefix("Runs both reviews"))
        XCTAssertTrue(segments[3].hasSuffix(#"review since X"."#), "尾部引号应保留")

        // The split point must be invisible: single-space rejoining must
        // reproduce the original byte-for-byte.
        XCTAssertEqual(segments.joined(separator: " "), text)
    }

    /// Consecutive punctuation ("?!", "!?", "...") must not be split
    /// into separate segments.
    func testConsecutivePunctuationStaysTogether() {
        XCTAssertEqual(
            DescriptionSplitter.sentenceSegments("Really?! Wow... Ok."),
            ["Really?!", "Wow...", "Ok."]
        )
    }

    /// A closing quote followed by the sentence period stays one segment.
    func testTrailingQuoteStaysWithSentence() {
        XCTAssertEqual(
            DescriptionSplitter.sentenceSegments(#"He said "yes". Next."#),
            [#"He said "yes"."#, "Next."]
        )
    }

    /// Closing brackets before a question mark stay with the sentence.
    func testClosingBracketAbsorbed() {
        XCTAssertEqual(
            DescriptionSplitter.sentenceSegments("Check the map[1]? Next."),
            ["Check the map[1]?", "Next."]
        )
    }

    /// Short inputs with a single sentence are not over-split.
    func testShortSentenceIsSingleSegment() {
        XCTAssertEqual(
            DescriptionSplitter.sentenceSegments("Short text."),
            ["Short text."]
        )
    }

    /// No sentence-ending punctuation at all → one segment.
    func testNoPunctuationIsSingleSegment() {
        XCTAssertEqual(
            DescriptionSplitter.sentenceSegments("A single sentence without punctuation"),
            ["A single sentence without punctuation"]
        )
    }

    /// Empty input produces no segments (never a crash).
    func testEmptyInput() {
        XCTAssertEqual(DescriptionSplitter.sentenceSegments(""), [])
    }

    /// Multiple spaces after punctuation collapse to the joiner's single
    /// space — never a leading-space segment.
    func testMultipleSpacesCollapse() {
        let segments = DescriptionSplitter.sentenceSegments("First.  Second.   Third.")
        XCTAssertEqual(segments, ["First.", "Second.", "Third."])
        XCTAssertEqual(segments.joined(separator: " "), "First. Second. Third.")
    }

    /// A still-huge single sentence is hard-split into ≤200-char chunks
    /// that rejoin (with a single space) to the original — never a lone
    /// "." or a torn word at the boundary.
    func testLongSentenceHardSplit() {
        let long = String(repeating: "word ", count: 60) + "end." // 301 chars
        XCTAssertGreaterThan(long.count, DescriptionSplitter.maxSegmentLength)

        let segments = DescriptionSplitter.sentenceSegments(long)
        XCTAssertGreaterThan(segments.count, 1)
        for segment in segments {
            XCTAssertLessThanOrEqual(segment.count, DescriptionSplitter.maxSegmentLength)
        }
        // Every cut lands on a single-space boundary, so single-space
        // rejoining reproduces the original exactly.
        XCTAssertEqual(segments.joined(separator: " "), long)
    }

    /// The real-world case the sweep flagged: a 201-char sentence whose
    /// 200-char hard cut would land right before the final period. The
    /// word-boundary lookback keeps "research." whole — no lone ".".
    func testHardSplitBacksUpToWordBoundary() {
        let text = #"Trigger with "user research plan", "interview guide", "usability test", "survey design", "research questions", or when the user needs help with any aspect of understanding their users through research."#
        XCTAssertEqual(text.count, 201)
        XCTAssertGreaterThan(text.count, DescriptionSplitter.maxSegmentLength)

        let segments = DescriptionSplitter.sentenceSegments(text)
        for segment in segments {
            XCTAssertLessThanOrEqual(segment.count, DescriptionSplitter.maxSegmentLength)
            XCTAssertFalse(segment == ".", "句末句号不应被切出为孤立段")
            XCTAssertFalse(segment.hasPrefix(" "), "段首不应有空格")
        }
        XCTAssertEqual(segments.joined(separator: " "), text)
    }

    /// Domains and abbreviations with internal periods ("qq.com",
    /// "e.g.", "1.2.3") must never be torn apart by the splitter.
    func testMidWordPeriodsDoNotSplit() {
        XCTAssertEqual(
            DescriptionSplitter.sentenceSegments("Deploy to docs.qq.com and verify."),
            ["Deploy to docs.qq.com and verify."]
        )
        XCTAssertEqual(
            DescriptionSplitter.sentenceSegments("Use e.g. dist/ and i.e. src/."),
            ["Use e.g.", "dist/ and i.e.", "src/."]
        )
        XCTAssertEqual(
            DescriptionSplitter.sentenceSegments("Version 1.2.3 is ready."),
            ["Version 1.2.3 is ready."]
        )
        // U.S.A.: the inner periods are mid-word (never "U. S. A."), the
        // trailing "A." followed by a space is a sentence boundary — the
        // abbreviation stays one segment and rejoining reproduces the
        // original exactly.
        let usa = DescriptionSplitter.sentenceSegments("Works in the U.S.A. today.")
        XCTAssertEqual(usa, ["Works in the U.S.A.", "today."])
        XCTAssertEqual(usa.joined(separator: " "), "Works in the U.S.A. today.")
    }

    /// A comma right after a quoted question belongs to the sentence —
    /// `"is this accessible?", or when…` never splits before the comma.
    func testCommaAfterQuotedQuestionStaysWithSentence() {
        let text = #"Trigger with "audit accessibility", "check a11y", "is this accessible?", or when reviewing a design for color contrast."#
        let segments = DescriptionSplitter.sentenceSegments(text)
        XCTAssertEqual(segments.count, 2)
        XCTAssertTrue(segments[0].hasSuffix("accessible?\","), "逗号应留在问号句末尾")
        XCTAssertFalse(segments[1].hasPrefix(","), "下一段不应以逗号开头")
        XCTAssertEqual(segments.joined(separator: " "), text)
    }

    /// A mid-word period in a hard-split window ("SKILL.md") is never a
    /// cut boundary — the chunk must not end with "SKILL." or start with
    /// "md".
    func testHardCutKeepsMidWordPeriodIntact() {
        let text = String(repeating: "字", count: 160) + "SKILL.md" + String(repeating: "字", count: 40)
        XCTAssertGreaterThan(text.count, DescriptionSplitter.maxSegmentLength)

        let chunks = DescriptionSplitter.lengthSegments(text)
        XCTAssertGreaterThan(chunks.count, 1)
        for chunk in chunks {
            XCTAssertFalse(chunk.hasSuffix("SKILL."), "不应切断 SKILL.md")
            XCTAssertFalse(chunk.hasPrefix("md"), "不应切断 SKILL.md")
            XCTAssertLessThanOrEqual(chunk.count, DescriptionSplitter.maxSegmentLength)
        }
    }

    /// Every segment must stay within the length cap that keeps the
    /// system translation session responsive.
    func testAllSegmentsWithinCap() {
        let text = String(repeating: "Question? ", count: 40) // > 200
        for segment in DescriptionSplitter.sentenceSegments(text) {
            XCTAssertLessThanOrEqual(segment.count, DescriptionSplitter.maxSegmentLength)
        }
    }

    // MARK: Markdown → plain text (translation source)

    func testPlainTextStripsImagesAndLinksKeepingLabels() {
        let result = MarkdownPlainText.extract(from: """
            Feature ![icon](image.png) and [docs](https://example.com) here.
            """)
        XCTAssertTrue(result.contains("Feature icon and docs here."), "图片保留 alt、链接保留 label：\(result)")
    }

    func testPlainTextStripsPairedEmphasisButKeepsIdentifiers() {
        let result = MarkdownPlainText.extract(from: """
            Use `npm run build`, **bold note**, and look at foo_bar or SKILL.md.
            """)
        XCTAssertTrue(result.contains("Use npm run build, bold note, and look at foo_bar or SKILL.md."),
                      "成对标记剥离、标识符保留：\(result)")
        XCTAssertTrue(result.contains("foo_bar"), "foo_bar 的下划线不被剥离：\(result)")
        XCTAssertFalse(result.contains("**"), "** 成对剥离：\(result)")
        XCTAssertFalse(result.contains("`"), "反引号成对剥离：\(result)")
    }

    func testPlainTextKeepsLoneMarkersIntact() {
        XCTAssertEqual(
            MarkdownPlainText.extract(from: "rate a * b and 3 * 4"),
            "rate a * b and 3 * 4",
            "不成对的星号保留"
        )
        XCTAssertEqual(
            MarkdownPlainText.extract(from: "path/to_x stays"),
            "path/to_x stays",
            "字母数字包围的下划线保留"
        )
    }

    func testPlainTextStripsLineMarkers() {
        XCTAssertEqual(
            MarkdownPlainText.extract(from: "# Heading\n- item\n1. first"),
            "Heading\nitem\nfirst"
        )
    }
}
