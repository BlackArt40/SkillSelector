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
    /// keeping the punctuation attached. Closing delimiters and any
    /// further sentence-ending punctuation right after stay with the
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

    /// Hard-splits a still-overlong string into ≤ `maxSegmentLength` chunks.
    static func lengthSegments(_ text: String) -> [String] {
        var chunks: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: maxSegmentLength, limitedBy: text.endIndex) ?? text.endIndex
            chunks.append(String(text[start..<end]))
            start = end
        }
        return chunks
    }
}
