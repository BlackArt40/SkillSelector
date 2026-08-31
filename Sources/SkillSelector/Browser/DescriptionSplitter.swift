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
                // Absorb closing delimiters and further sentence-ending
                // punctuation immediately after — "for?)." stays whole.
                var lookahead = text.index(after: index)
                while lookahead < text.endIndex,
                      sentenceClosingDelimiters.contains(text[lookahead])
                        || "!.?".contains(text[lookahead]) {
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

    /// Hard-splits a still-overlong string into ≤ `maxSegmentLength`
    /// chunks, backing up to the nearest space (within a 40-char window)
    /// so breaks land on word boundaries — the split point stays
    /// invisible in the rejoined output instead of cutting mid-word or
    /// right before a trailing period.
    static func lengthSegments(_ text: String) -> [String] {
        let lookbackLimit = 40
        var chunks: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: maxSegmentLength, limitedBy: text.endIndex) ?? text.endIndex
            var boundary = end
            if end < text.endIndex {
                // Back up to the last space before the cap and cut before
                // it — the space is skipped so the joiner's single space
                // applies. Fall back to the hard cut when no space is
                // found (a long unbroken token).
                var lookback = 0
                while lookback < lookbackLimit, boundary > start {
                    let previous = text.index(before: boundary)
                    if text[previous] == " " {
                        boundary = previous
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
