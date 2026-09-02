import Foundation

/// Markdown → plain text for contexts that need the words without the
/// markers — currently the description translator's source text.
enum MarkdownPlainText {
    /// Strips Markdown from a string, leaving plain text: images keep
    /// their alt text, links keep their label, paired inline code and
    /// emphasis markers are removed, and lone markers in identifiers
    /// (`foo_bar`) or arithmetic (`a * b`) survive.
    ///
    /// Inline syntax is handed to Foundation's CommonMark parser
    /// (inline-only, whitespace-preserving), which implements the
    /// paired-marker semantics by spec; the parser leaves line-level
    /// constructs untouched, so leading heading / quote / bullet markers
    /// and ordered-list digits are stripped per line afterwards. If the
    /// parser rejects the input the original text is returned unchanged.
    static func extract(from text: String) -> String {
        let inlineStripped = (try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        )).map { String($0.characters) } ?? text
        return inlineStripped
            .components(separatedBy: "\n")
            .map { line in
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
