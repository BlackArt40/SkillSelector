import SkillSelectorCore
import SwiftUI

/// Renders Skill document bodies with the system `AttributedString(markdown:)`
/// parser (no hand-written markdown engine), then materializes concrete
/// font/color attributes for the parts macOS `Text` does not style from
/// presentation intents on its own:
///
/// - heading levels get explicit sizes/weights;
/// - code spans/blocks get a monospaced font;
/// - list items get a newline and a bullet/number marker;
/// - only http/https destinations survive as clickable links; anything else
///   (file:, javascript:, app schemes) is stripped to inert text with the
///   raw destination disclosed next to the label.
enum MarkdownRenderer {
    /// Lines after the frontmatter block, or the whole text when there is no
    /// frontmatter. Delegates to the parser's shared boundary detection so the
    /// renderer cannot drift from how the document is parsed.
    static func extractBody(_ source: String) -> [String] {
        FrontmatterParser.bodyLines(from: source)
    }

    static func buildAttributedString(from lines: [String]) -> AttributedString? {
        let text = hardenSoftBreaks(in: lines)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .full
        options.failurePolicy = .returnPartiallyParsedIfPossible
        guard var result = try? AttributedString(markdown: text, options: options) else {
            return nil
        }
        sanitizeLinks(in: &result)
        materializeStyles(in: &result)
        insertBlockBreaks(in: &result)
        return result.characters.isEmpty ? nil : result
    }

    /// The system parser folds soft line breaks (a single newline inside a
    /// paragraph) into spaces, so "workflow: …\ntopic: …" would render as one
    /// jammed line. CommonMark's hard break — two trailing spaces before the
    /// newline — survives the parser, so every single newline between two
    /// non-empty lines is hardened before parsing, preserving the source line
    /// structure. Fenced code content is left untouched: trailing spaces
    /// there are meaningful.
    private static func hardenSoftBreaks(in lines: [String]) -> String {
        var result: [String] = []
        var inFence = false
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                result.append(line)
                continue
            }
            let hasNextContent = index + 1 < lines.count
                && !lines[index + 1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if !inFence, !line.isEmpty, hasNextContent {
                result.append(line + "  ")
            } else {
                result.append(line)
            }
        }
        return result.joined(separator: "\n")
    }

    /// URL schemes that are safe to expose as a clickable link inside an
    /// untrusted Skill document.
    ///
    /// Everything else — `file:`, `shortcuts:`, `javascript:`, arbitrary app
    /// schemes — can hand execution to another process running *outside* the
    /// App Sandbox, so those destinations are rendered as inert text instead.
    private static let allowedLinkSchemes: Set<String> = ["http", "https"]

    /// Whether a resolved URL may be handed to the system opener.
    static func isAllowedLink(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return allowedLinkSchemes.contains(scheme)
    }

    /// Returns a URL only when the destination is safe to open from a link tap.
    ///
    /// Relative references are rejected too: the renderer has no base URL, so
    /// how they would resolve at click time is undefined.
    static func sanitizedLinkURL(_ urlString: String) -> URL? {
        guard let url = URL(string: urlString), isAllowedLink(url) else { return nil }
        return url
    }

    /// Strips the `link` attribute from every run whose destination is not
    /// http/https, and discloses the raw destination right after the label as
    /// inert text — so "click here" can never hide a `file:` or app-scheme
    /// target from the reader.
    private static func sanitizeLinks(in attributed: inout AttributedString) {
        var insertions: [(range: Range<AttributedString.Index>, text: String)] = []
        for run in attributed.runs {
            guard let link = run.link, !isAllowedLink(link) else { continue }
            attributed[run.range].link = nil
            insertions.append((run.range, " (\(link.absoluteString))"))
        }
        for insertion in insertions.reversed() {
            attributed.insert(AttributedString(insertion.text), at: insertion.range.upperBound)
        }
    }

    // MARK: Materialized styles

    private static let bodySize: CGFloat = 13
    private static let monoSize: CGFloat = 12.5
    private static let headingSizes: [Int: CGFloat] = [
        1: 21, 2: 18, 3: 16, 4: 15, 5: 14, 6: 13.5,
    ]

    /// Converts the parser's presentation intents into explicit font and
    /// color attributes so the display does not depend on `Text`'s intent
    /// handling (which macOS leaves unstyled for headings and code).
    /// Element colors: h1 uses the accent, inline code amber, blockquotes
    /// violet, links accent-blue — body and headings stay in the neutral
    /// foreground scale. Code blocks and inline code get a surface
    /// background so fenced content (templates, command blocks) is
    /// unmistakably code — their `#`/`##` markers are literal, not headings.
    private static func materializeStyles(in attributed: inout AttributedString) {
        for run in attributed.runs {
            let range = run.range
            var size = bodySize
            var weight: Font.Weight = .regular
            var isItalic = false
            var isMonospaced = false
            var color: Color = AppTheme.foregroundSecondary
            var backgroundColor: Color?

            if let intent = run.inlinePresentationIntent {
                if intent.contains(.code) {
                    isMonospaced = true
                    size = monoSize
                    color = AppTheme.codeInline
                    backgroundColor = AppTheme.surface
                }
                if intent.contains(.emphasized) { isItalic = true }
                if intent.contains(.stronglyEmphasized) { weight = .semibold }
            }
            if let presentation = run.presentationIntent {
                for component in presentation.components {
                    switch component.kind {
                    case .header(let level):
                        size = headingSizes[level] ?? bodySize
                        weight = .semibold
                        color = level == 1 ? AppTheme.accent : AppTheme.foreground
                    case .codeBlock:
                        isMonospaced = true
                        size = 13
                        color = AppTheme.foreground
                        backgroundColor = AppTheme.codeBlockBackground
                    case .blockQuote:
                        color = AppTheme.blockquote
                    default:
                        break
                    }
                }
            }
            if run.link != nil {
                color = AppTheme.accent
                attributed[range].underlineStyle = .single
            }

            var font: Font
            if isMonospaced {
                font = .system(size: size, weight: weight, design: .monospaced)
            } else {
                font = .system(size: size, weight: weight)
            }
            if isItalic { font = font.italic() }
            attributed[range].font = font
            attributed[range].foregroundColor = color
            if let backgroundColor {
                attributed[range].backgroundColor = backgroundColor
            }
        }
    }

    /// The system parser keeps every block element on a single logical run
    /// stream with no newline between blocks — paragraphs, headings, code
    /// blocks, list items and table rows would all render jammed together.
    /// This pass groups runs by their structural element (kind + identity)
    /// and inserts the separators `Text` needs: a newline after every block,
    /// a bullet/number marker at the start of each list item, and a ` | `
    /// between table cells.
    private static func insertBlockBreaks(in attributed: inout AttributedString) {
        struct Key: Hashable {
            let kind: PresentationIntent.Kind
            let identity: Int
        }

        var starts: [Key: AttributedString.Index] = [:]
        var ends: [Key: AttributedString.Index] = [:]
        var listItems: [Key: (ordinal: Int?, isOrdered: Bool)] = [:]
        var cells: [Key: Key] = [:]  // cell element -> containing row element
        var rows = Set<Key>()

        for run in attributed.runs {
            guard let presentation = run.presentationIntent else { continue }
            let components = presentation.components
            let rowComponent = components.first { component in
                if case .tableRow = component.kind { return true }
                if case .tableHeaderRow = component.kind { return true }
                return false
            }
            for component in components {
                let key = Key(kind: component.kind, identity: component.identity)
                starts[key] = min(starts[key] ?? run.range.upperBound, run.range.lowerBound)
                ends[key] = max(ends[key] ?? run.range.lowerBound, run.range.upperBound)
                switch component.kind {
                case .listItem(let ordinal):
                    let ordered = components.contains { component in
                        if case .orderedList = component.kind { return true }
                        return false
                    }
                    listItems[key] = (ordinal, ordered)
                case .tableCell:
                    if let rowComponent {
                        cells[key] = Key(kind: rowComponent.kind, identity: rowComponent.identity)
                    }
                case .tableRow, .tableHeaderRow:
                    rows.insert(key)
                default:
                    break
                }
            }
        }

        var insertions: [(index: AttributedString.Index, text: AttributedString, priority: Int)] = []

        // Newline after every block-level element (paragraphs, headings,
        // quotes, thematic breaks, table rows). Nested elements sharing a
        // boundary dedupe at apply time.
        for (key, end) in ends {
            let needsNewline: Bool
            switch key.kind {
            case .paragraph, .header, .blockQuote, .thematicBreak, .tableRow, .tableHeaderRow:
                needsNewline = true
            default:
                needsNewline = false
            }
            guard needsNewline else { continue }
            if end != attributed.endIndex, attributed.characters[end] == "\n" { continue }
            insertions.append((end, AttributedString("\n"), 1))
        }

        // List items: one marker at the item's first run, one newline at its
        // last run. The marker is indented and tinted muted so it reads as a
        // list glyph rather than body text.
        for (key, info) in listItems {
            guard let start = starts[key], let end = ends[key] else { continue }
            var marker = AttributedString()
            if info.isOrdered, let ordinal = info.ordinal {
                marker = AttributedString("  \(ordinal). ")
            } else {
                marker = AttributedString("  •  ")
            }
            marker.foregroundColor = AppTheme.muted
            insertions.append((start, marker, 0))
            insertions.append((end, AttributedString("\n"), 1))
        }

        // Table cells: separator between cells, but not after the last cell
        // of a row (the row's own newline follows there).
        for (cell, row) in cells {
            guard let cellEnd = ends[cell] else { continue }
            if let rowEnd = ends[row], cellEnd == rowEnd { continue }
            insertions.append((cellEnd, AttributedString(" | "), 1))
        }

        // Apply back-to-front so earlier indices stay valid. At a shared
        // boundary (item end == next item start) the marker must land before
        // the newline, so equal indices order by priority. Duplicate
        // (index, text) pairs — nested elements sharing a boundary — apply
        // once.
        var applied: [(index: AttributedString.Index, text: AttributedString)] = []
        for insertion in insertions.sorted(by: { lhs, rhs in
            if lhs.index != rhs.index { return lhs.index > rhs.index }
            return lhs.priority < rhs.priority
        }) {
            if applied.contains(where: { $0.index == insertion.index && $0.text == insertion.text }) {
                continue
            }
            attributed.insert(insertion.text, at: insertion.index)
            applied.append((insertion.index, insertion.text))
        }
    }
}

extension View {
    /// Enforces the renderer's link policy again at click time.
    ///
    /// This is a second line of defence: even if a link attribute ever slips
    /// past `MarkdownRenderer`, only http/https reaches the system opener.
    /// Anything else is discarded.
    func markdownLinkPolicy() -> some View {
        environment(
            \.openURL,
            OpenURLAction { url in
                MarkdownRenderer.isAllowedLink(url) ? .systemAction : .discarded
            }
        )
    }
}
