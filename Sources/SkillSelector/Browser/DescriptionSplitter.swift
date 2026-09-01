import Foundation

/// Splits plain text into translation-friendly chunks for the macOS
/// Translation framework.
///
/// A single `translate()` call with a long string stalls the system
/// session, so long paragraphs are broken at sentence boundaries into
/// ≤ `maxSegmentLength`-character segments. Closing delimiters and
/// trailing sentence punctuation stay attached ("asked for?)." is one
/// segment, never "asked for?)" + "."), and the caller rejoins
/// same-paragraph segments with a single space, so the split points
/// are invisible in the translated output.
enum DescriptionSplitter {
    /// Hard cap per segment; longer input to `translate()` stalls the session.
    static let maxSegmentLength = 200

    /// Closing delimiters absorbed into the sentence that ends with
    /// sentence-ending punctuation — "standards?) and" splits as
    /// "standards?) " + "and", never "standards?" + ") and".
    static let sentenceClosingDelimiters: [Character] = [")", "\"", "'", "]", "}"]

    /// Commas and colons right after the sentence-ending punctuation are
    /// absorbed too — a comma can never start a new sentence, so
    /// `"is this accessible?", or when…` stays one segment instead of
    /// splitting before the comma.
    static let sentenceContinuationPunctuation: [Character] = [",", ";", ":", "，", "；", "：", "、"]

    /// Breaks a paragraph at sentence-ending punctuation (`.`, `!`, `?`),
    /// keeping the punctuation attached. A period only ends a sentence
    /// when whitespace or end-of-text follows (possibly after closing
    /// delimiters) — mid-word periods in abbreviations and domains
    /// ("e.g.", "qq.com", "1.2.3") never split. Closing delimiters and
    /// any further sentence-ending punctuation right after stay with the
    /// sentence, and following spaces are dropped — the caller rejoins
    /// with a single space, so the split point is invisible in the
    /// output. Any still-huge sentence is hard-split.
    static func sentenceSegments(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            current.append(character)
            if "!.?".contains(character) {
                if character == "." {
                    // Mid-word periods ("e.g.", "qq.com", "version 1.2.3")
                    // are not sentence ends — only split when whitespace
                    // or end-of-text follows the period, possibly after
                    // closing delimiters (`"review since X".`).
                    var ws = text.index(after: index)
                    while ws < text.endIndex, sentenceClosingDelimiters.contains(text[ws]) {
                        ws = text.index(after: ws)
                    }
                    if ws < text.endIndex, !text[ws].isWhitespace {
                        index = text.index(after: index)
                        continue
                    }
                }
                // Absorb closing delimiters, further sentence-ending
                // punctuation, and continuation commas immediately after
                // — "for?)." and `"accessible?",` each stay whole.
                var lookahead = text.index(after: index)
                while lookahead < text.endIndex,
                      sentenceClosingDelimiters.contains(text[lookahead])
                        || "!.?".contains(text[lookahead])
                        || sentenceContinuationPunctuation.contains(text[lookahead]) {
                    current.append(text[lookahead])
                    lookahead = text.index(after: lookahead)
                }
                // Drop following spaces — the joiner supplies one.
                while lookahead < text.endIndex, text[lookahead] == " " {
                    lookahead = text.index(after: lookahead)
                }
                sentences.append(current)
                current = ""
                index = lookahead
                continue
            }
            index = text.index(after: index)
        }
        if !current.isEmpty {
            sentences.append(current)
        }
        return sentences.flatMap { $0.count > maxSegmentLength ? lengthSegments($0) : [$0] }
    }

    /// Punctuation a hard-split may cut after when no space is within the
    /// lookback window — keeps space-less text (Chinese/Japanese) from
    /// being split mid-word ("底层" never becomes "底" + "层"). A period
    /// is handled separately: only a sentence-ending period is a valid
    /// boundary, never a mid-word one ("SKILL.md" stays whole).
    static let hardCutPunctuation: [Character] = [
        ",", ";", ":", "!", "?",
        "，", "。", "；", "：", "！", "？", "、",
    ]

    /// Hard-splits a still-overlong string into ≤ `maxSegmentLength`
    /// chunks. Breaks land on word boundaries: the nearest space (or
    /// newline) within a 40-char window is preferred, then sentence
    /// punctuation — so the split point stays invisible in the rejoined
    /// output instead of cutting mid-word or right before a trailing
    /// period. Falls back to a raw cut only for a long unbroken token.
    static func lengthSegments(_ text: String) -> [String] {
        let lookbackLimit = 40
        var chunks: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: maxSegmentLength, limitedBy: text.endIndex) ?? text.endIndex
            var boundary = end
            if end < text.endIndex {
                var lookback = 0
                while lookback < lookbackLimit, boundary > start {
                    let previous = text.index(before: boundary)
                    if text[previous] == " " || text[previous].isNewline {
                        boundary = previous // cut before the space; the joiner supplies it
                        break
                    }
                    if text[previous] == "." {
                        // A period is a boundary only when it ends a
                        // sentence (whitespace or end follows, possibly
                        // after closing delimiters) — "SKILL.md" never
                        // splits into "SKILL." + "md".
                        var after = text.index(after: previous)
                        while after < text.endIndex,
                              sentenceClosingDelimiters.contains(text[after]) {
                            after = text.index(after: after)
                        }
                        if after == text.endIndex || text[after].isWhitespace {
                            boundary = text.index(after: previous)
                            break
                        }
                        boundary = previous
                        lookback += 1
                        continue
                    }
                    if Self.hardCutPunctuation.contains(text[previous]) {
                        boundary = text.index(after: previous) // cut after the punctuation
                        break
                    }
                    boundary = previous
                    lookback += 1
                }
                if boundary == start { boundary = end }
            }
            chunks.append(String(text[start..<boundary]))
            if boundary < text.endIndex, text[boundary] == " " {
                start = text.index(after: boundary)
            } else {
                start = boundary
            }
        }
        return chunks
    }
}

// MARK: - Markdown → plain text

extension DescriptionSplitter {
    /// Strips common Markdown markers from a string, leaving plain text
    /// suitable for translation: images keep their alt text, links keep
    /// their label, inline code and emphasis markers are removed only in
    /// their paired (markdown) form — lone underscores in identifiers
    /// (`foo_bar`) and lone asterisks (`a * b`) survive — and leading
    /// heading / quote / list markers are dropped per line.
    static func plainText(fromMarkdown text: String) -> String {
        var result = text
        // Images: ![alt](url) → alt
        result = result.replacingOccurrences(
            of: #"!\[([^\]]*)\]\([^)]*\)"#,
            with: "$1",
            options: .regularExpression
        )
        // Links: [label](url) → label
        result = result.replacingOccurrences(
            of: #"\[([^\]]*)\]\([^)]*\)"#,
            with: "$1",
            options: .regularExpression
        )
        // Inline code: `code` → code
        result = result.replacingOccurrences(
            of: #"`([^`\n]+)`"#,
            with: "$1",
            options: .regularExpression
        )
        // Bold: **word** / __word__ → word (paired only)
        result = result.replacingOccurrences(
            of: #"\*\*([^*\n]+?)\*\*"#,
            with: "$1",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"__([^_\n]+?)__"#,
            with: "$1",
            options: .regularExpression
        )
        // Italic: *word* / _word_ → word. Lookarounds keep lone markers
        // inside identifiers intact ("foo_bar", "a * b"), and the marker
        // must wrap non-space content so "3 * 4" (multiplication) and
        // spaced asterisks are never treated as emphasis.
        result = result.replacingOccurrences(
            of: #"(?<![A-Za-z0-9])\*([^*\s][^*\n]*?[^*\s])\*(?![A-Za-z0-9])"#,
            with: "$1",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"(?<![A-Za-z0-9])_([^_\s][^_\n]*?[^_\s])_(?![A-Za-z0-9])"#,
            with: "$1",
            options: .regularExpression
        )
        // Leading heading / quote / bullet markers and ordered list digits
        let lines = result.components(separatedBy: "\n")
        return lines.map { line in
            let cleaned = line.replacingOccurrences(
                of: #"^[#>*\-+]+(?:\s+|$)"#,
                with: "",
                options: .regularExpression
            )
            return cleaned.replacingOccurrences(
                of: #"^\d+[.)]\s+"#,
                with: "",
                options: .regularExpression
            )
        }
        .joined(separator: "\n")
    }
}
