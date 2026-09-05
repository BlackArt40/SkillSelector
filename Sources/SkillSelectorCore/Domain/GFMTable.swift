import Foundation

/// One rendered piece of a markdown body: either a markdown fragment handed
/// to MarkdownUI byte-for-byte, or a parsed GFM table rendered by the app's
/// own `GFMTableView`.
///
/// Why the app owns table rendering: MarkdownUI 2.4.1 draws tables only via a
/// `TableView` gated behind `@available(macOS 13.0, *)` with no fallback, so
/// at a macOS 12 deployment target its table path renders empty. The
/// segmenter pulls tables out of the document on every macOS version — no
/// availability forks — and every other construct stays with MarkdownUI.
public enum MarkdownSegment: Equatable, Sendable {
    /// A verbatim fragment of the original document. Fragment boundaries sit
    /// at table edges and never split a fenced code block, so the fragment
    /// can be rendered as an independent markdown document.
    case markdown(String)
    /// A GFM table detected in the document.
    case table(GFMTable)
}

/// A parsed GFM table: header cells, per-column alignment, and data rows.
public struct GFMTable: Equatable, Sendable {
    public enum GFMTableAlignment: Equatable, Sendable {
        case leading
        case center
        case trailing
    }

    public struct Column: Equatable, Sendable {
        public let alignment: GFMTableAlignment

        public init(alignment: GFMTableAlignment) {
            self.alignment = alignment
        }
    }

    /// Header cells: decorative leading/trailing pipes stripped, `\|`
    /// unescaped to a literal pipe, whitespace trimmed.
    public let header: [String]
    /// One alignment per column, derived from the delimiter row.
    public let alignments: [GFMTableAlignment]
    /// Data rows, each normalized to `header.count` cells: extras truncated,
    /// missing cells padded with empty strings.
    public let rows: [[String]]

    public init(header: [String], alignments: [GFMTableAlignment], rows: [[String]]) {
        self.header = header
        self.alignments = alignments
        self.rows = rows
    }
}

/// Splits a markdown document into `.markdown` and `.table` segments.
///
/// Scanning rules:
/// - **Fence-aware**: a line whose trimmed content starts with ```` ``` ````
///   or `~~~` toggles fence state (the same rule as
///   `MarkdownBody.hardenedText`). Fenced lines never form tables, and the
///   state machine runs over the whole document, so a segment boundary can
///   never split a fence pair — each `.markdown` segment is a safe,
///   independent document for MarkdownUI.
/// - **Table shape**: a header row (contains a pipe) directly followed by a
///   delimiter row whose every cell matches `:?-+:?` and whose cell count
///   equals the header's. Data rows are the piped lines after the delimiter
///   row until the first blank, fence, or pipe-less line.
/// - **Byte fidelity**: `.markdown` segments are exact substrings of the
///   input — the newline adjacent to a table edge belongs to the markdown
///   fragment, so segments and tables interleave in source order.
public enum GFMTableSegmenter {
    public static func segments(in text: String) -> [MarkdownSegment] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var segments: [MarkdownSegment] = []
        var markdownLines: [String] = []
        var inFence = false

        // Emits the buffered markdown run. `followedByTable` is true when a
        // table continues after the buffer: the newline between the last
        // buffered line and the table's first line belongs to this fragment.
        // Empty runs — e.g. the boundary sentinel after a table at end of
        // input — produce no segment.
        func flushMarkdown(followedByTable: Bool) {
            guard !markdownLines.isEmpty else { return }
            var fragment = markdownLines.joined(separator: "\n")
            if followedByTable {
                fragment += "\n"
            }
            if !fragment.isEmpty {
                segments.append(.markdown(fragment))
            }
            markdownLines = []
        }

        var index = 0
        while index < lines.count {
            let line = lines[index]
            if isFenceLine(line) {
                inFence.toggle()
                markdownLines.append(line)
                index += 1
                continue
            }
            if inFence {
                markdownLines.append(line)
                index += 1
                continue
            }
            if let header = rowCells(in: line),
                index + 1 < lines.count,
                !isFenceLine(lines[index + 1]),
                let alignments = delimiterAlignments(in: lines[index + 1]),
                alignments.count == header.count
            {
                flushMarkdown(followedByTable: true)
                var rows: [[String]] = []
                var cursor = index + 2
                while cursor < lines.count,
                    !isFenceLine(lines[cursor]),
                    let cells = rowCells(in: lines[cursor])
                {
                    rows.append(normalized(cells, to: header.count))
                    cursor += 1
                }
                segments.append(
                    .table(GFMTable(header: header, alignments: alignments, rows: rows))
                )
                // The newline between the table's last line and whatever
                // follows belongs to the next markdown fragment.
                markdownLines = [""]
                index = cursor
                continue
            }
            markdownLines.append(line)
            index += 1
        }
        flushMarkdown(followedByTable: false)
        return segments
    }

    /// Whether the line opens or closes a fenced code block. Deliberately the
    /// same naive prefix rule as `MarkdownBody.hardenedText` so both layers
    /// agree on where fences begin and end.
    private static func isFenceLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")
    }

    /// Splits a table row into trimmed cells, or nil when the line cannot be
    /// a row (no pipe at all, or nothing but decorative pipes).
    ///
    /// `\|` is an escaped pipe: it never splits cells and becomes a literal
    /// `|` in the cell. A single decorative pipe at each end is optional —
    /// detected exactly, as an escaped trailing pipe is cell content.
    private static func rowCells(in line: String) -> [String]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|") else { return nil }

        var rawSegments: [String] = []
        var current = ""
        let characters = Array(trimmed)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\\", index + 1 < characters.count, characters[index + 1] == "|" {
                current.append("|")
                index += 2
            } else if character == "|" {
                rawSegments.append(current)
                current = ""
                index += 1
            } else {
                current.append(character)
                index += 1
            }
        }
        rawSegments.append(current)

        // The walker splits on every unescaped pipe, so an empty first/last
        // segment means exactly one decorative leading/trailing pipe.
        if rawSegments.first == "" {
            rawSegments.removeFirst()
        }
        if rawSegments.last == "" {
            rawSegments.removeLast()
        }
        let cells = rawSegments.map { $0.trimmingCharacters(in: .whitespaces) }
        return cells.isEmpty ? nil : cells
    }

    /// Column alignments from a delimiter row, or nil when any cell fails
    /// the `:?-+:?` shape.
    private static func delimiterAlignments(in line: String) -> [GFMTable.GFMTableAlignment]? {
        guard let cells = rowCells(in: line), !cells.isEmpty else { return nil }
        var alignments: [GFMTable.GFMTableAlignment] = []
        for cell in cells {
            guard let alignment = alignment(for: cell) else { return nil }
            alignments.append(alignment)
        }
        return alignments
    }

    /// `:?-+:?` → alignment: both colons center, trailing colon right,
    /// everything else left.
    private static func alignment(for cell: String) -> GFMTable.GFMTableAlignment? {
        var body = cell[...]
        var leadingColon = false
        var trailingColon = false
        if body.hasPrefix(":") {
            leadingColon = true
            body = body.dropFirst()
        }
        if body.hasSuffix(":") {
            trailingColon = true
            body = body.dropLast()
        }
        guard !body.isEmpty, body.allSatisfy({ $0 == "-" }) else { return nil }
        if leadingColon && trailingColon { return .center }
        if trailingColon { return .trailing }
        return .leading
    }

    /// GFM tolerance for rows whose cell count differs from the header's:
    /// extra cells are truncated, missing cells padded with empty strings.
    private static func normalized(_ cells: [String], to columnCount: Int) -> [String] {
        var result = Array(cells.prefix(columnCount))
        while result.count < columnCount {
            result.append("")
        }
        return result
    }
}
