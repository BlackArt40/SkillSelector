import SkillSelectorCore
import XCTest

/// Tests for the GFM table segmenter feeding `MarkdownBodyView`.
///
/// MarkdownUI 2.4.1 renders tables only through a `TableView` gated behind
/// macOS 13 with no fallback, so at a macOS 12 deployment target its table
/// path would render empty. The segmenter pulls tables out of the document —
/// on every macOS version — while keeping every non-table fragment a
/// byte-exact substring of the source so MarkdownUI still owns the rest.
final class GFMTableTests: XCTestCase {
    // MARK: Table parsing

    func testSimpleTableParsesHeaderAlignmentsAndRows() {
        let source = """
        | Name | Value |
        | ---- | ----- |
        | alpha | 1 |
        | beta | 2 |
        """

        let segments = GFMTableSegmenter.segments(in: source)

        XCTAssertEqual(segments.count, 1)
        guard case .table(let table) = segments.first else {
            return XCTFail("Expected a single table segment, got \(segments)")
        }
        XCTAssertEqual(table.header, ["Name", "Value"])
        XCTAssertEqual(table.alignments, [.leading, .leading])
        XCTAssertEqual(table.rows, [["alpha", "1"], ["beta", "2"]])
    }

    /// `:---` (or plain `---`) maps to leading, `:---:` to center, `---:` to
    /// trailing — one alignment per delimiter cell.
    func testDelimiterRowMapsAllThreeAlignments() {
        let source = """
        | Left | Center | Right | Plain |
        | :--- | :----: | ----: | ----- |
        | a | b | c | d |
        """

        let segments = GFMTableSegmenter.segments(in: source)

        guard case .table(let table) = segments.first else {
            return XCTFail("Expected a table segment, got \(segments)")
        }
        XCTAssertEqual(table.alignments, [.leading, .center, .trailing, .leading])
        XCTAssertEqual(table.rows, [["a", "b", "c", "d"]])
    }

    /// `\|` inside a cell is a literal pipe, not a separator; surrounding
    /// cell whitespace is trimmed.
    func testEscapedPipeBecomesLiteralAndCellsAreTrimmed() {
        let source = """
        | Signal \\| Noise | Note |
        | --- | --- |
        |  a \\| b  |  padded  |
        """

        let segments = GFMTableSegmenter.segments(in: source)

        guard case .table(let table) = segments.first else {
            return XCTFail("Expected a table segment, got \(segments)")
        }
        XCTAssertEqual(table.header, ["Signal | Noise", "Note"])
        XCTAssertEqual(table.rows, [["a | b", "padded"]])
    }

    /// Pseudo-tables inside ``` and ~~~ fences never become table segments —
    /// the whole document stays one byte-exact markdown fragment.
    func testPseudoTableInsideFenceStaysMarkdownByteForByte() {
        let backticks = """
        Before.

        ```
        | a | b |
        | - | - |
        ```

        After.
        """
        XCTAssertEqual(GFMTableSegmenter.segments(in: backticks), [.markdown(backticks)])

        let tildes = """
        ~~~
        | x | y |
        | - | - |
        ~~~
        """
        XCTAssertEqual(GFMTableSegmenter.segments(in: tildes), [.markdown(tildes)])
    }

    /// A document without a table round-trips as one markdown fragment equal
    /// to the input, including piped lines that lack a delimiter row.
    func testNonTableDocumentPassesThroughAsSingleMarkdownSegment() {
        let source = """
        # Title

        Paragraph with `code` and [link](https://example.com).

        - one
        - two

        | just | pipes |
        | without | delimiter |
        """

        XCTAssertEqual(GFMTableSegmenter.segments(in: source), [.markdown(source)])
    }

    /// Rows with a different cell count than the delimiter row are normalized
    /// GFM-style: extras truncated, gaps padded with empty strings.
    func testRaggedRowsAreTruncatedAndPaddedToHeaderCount() {
        let source = """
        | A | B | C |
        | --- | --- | --- |
        | 1 | 2 |
        | x | y | z | extra |
        """

        let segments = GFMTableSegmenter.segments(in: source)

        guard case .table(let table) = segments.first else {
            return XCTFail("Expected a table segment, got \(segments)")
        }
        XCTAssertEqual(table.rows, [["1", "2", ""], ["x", "y", "z"]])
    }

    /// Plain text hard against a table (no blank lines) splits into three
    /// segments in source order, with the markdown fragments byte-faithful —
    /// reassembling them around the table reproduces the input exactly.
    func testTableBetweenPlainTextYieldsThreeByteFaithfulSegments() {
        let source = "Intro line\n| a | b |\n| - | - |\n| 1 | 2 |\nOutro line"

        let segments = GFMTableSegmenter.segments(in: source)

        XCTAssertEqual(segments.count, 3)
        guard case .markdown(let before) = segments[0] else {
            return XCTFail("Expected a leading markdown segment, got \(segments)")
        }
        guard case .table(let table) = segments[1] else {
            return XCTFail("Expected a table segment, got \(segments)")
        }
        guard case .markdown(let after) = segments[2] else {
            return XCTFail("Expected a trailing markdown segment, got \(segments)")
        }
        XCTAssertEqual(before, "Intro line\n")
        XCTAssertEqual(table.header, ["a", "b"])
        XCTAssertEqual(table.rows, [["1", "2"]])
        XCTAssertEqual(after, "\nOutro line")
        XCTAssertEqual(before + "| a | b |\n| - | - |\n| 1 | 2 |" + after, source)
    }

    /// A second row whose cells don't match `:?-+:?` is not a delimiter row,
    /// and a header/delimiter cell-count mismatch also refuses the table —
    /// both stay verbatim markdown.
    func testMalformedDelimiterRowIsNotATable() {
        let malformedCell = "| a | b |\n| - | not-a-dash |"
        XCTAssertEqual(GFMTableSegmenter.segments(in: malformedCell), [.markdown(malformedCell)])

        let mismatchedCount = "| a | b |\n| - | - | - |"
        XCTAssertEqual(GFMTableSegmenter.segments(in: mismatchedCount), [.markdown(mismatchedCount)])
    }
}
