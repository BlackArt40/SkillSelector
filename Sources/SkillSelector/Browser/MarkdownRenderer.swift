import SkillSelectorCore
import SwiftUI

enum MarkdownRenderer {
    /// Lines after the frontmatter block, or the whole text when there is no
    /// frontmatter. Delegates to the parser's shared boundary detection so the
    /// renderer cannot drift from how the document is parsed.
    static func extractBody(_ source: String) -> [String] {
        FrontmatterParser.bodyLines(from: source)
    }

    static func buildAttributedString(from lines: [String]) -> AttributedString? {
        var result = AttributedString()
        var inCodeBlock = false
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                inCodeBlock.toggle()
                i += 1
                continue
            }
            if inCodeBlock {
                var code = AttributedString("  " + line)
                code.font = .system(.body, design: .monospaced)
                result.append(code)
                result.append(AttributedString("\n"))
                i += 1
                continue
            }
            if trimmed.isEmpty {
                result.append(AttributedString("\n"))
                i += 1
                continue
            }
            if trimmed.hasPrefix("# ") {
                var h = AttributedString(String(trimmed.dropFirst(2)))
                h.font = .title.bold()
                result.append(h)
                result.append(AttributedString("\n"))
            } else if trimmed.hasPrefix("## ") {
                var h = AttributedString(String(trimmed.dropFirst(3)))
                h.font = .title2.bold()
                result.append(h)
                result.append(AttributedString("\n"))
            } else if trimmed.hasPrefix("### ") {
                var h = AttributedString(String(trimmed.dropFirst(4)))
                h.font = .title3.bold()
                result.append(h)
                result.append(AttributedString("\n"))
            } else if trimmed.hasPrefix("#### ") || trimmed.hasPrefix("##### ") || trimmed.hasPrefix("###### ") {
                let level = trimmed.prefix(while: { $0 == "#" }).count
                var h = AttributedString(String(trimmed.dropFirst(level + 1)))
                h.font = .headline.bold()
                result.append(h)
                result.append(AttributedString("\n"))
            } else if trimmed.hasPrefix("|") && i + 1 < lines.count && lines[i + 1].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                let (tableLines, consumed) = collectTable(lines: lines, start: i)
                renderTable(tableLines, into: &result)
                i += consumed
                continue
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                let parsed = parseInline(String(trimmed.dropFirst(2)))
                var item = AttributedString("  • ")
                item.font = .body
                result.append(item)
                result.append(parsed)
                result.append(AttributedString("\n"))
            } else if trimmed.first?.isNumber == true && trimmed.dropFirst().hasPrefix(". ") {
                let parsed = parseInline(String(trimmed.dropFirst(2)))
                var item = AttributedString("  " + String(trimmed.prefix(while: { $0 != "." })) + ". ")
                item.font = .body
                result.append(item)
                result.append(parsed)
                result.append(AttributedString("\n"))
            } else {
                result.append(parseInline(line))
                result.append(AttributedString("\n"))
            }
            i += 1
        }
        return result.characters.isEmpty ? nil : result
    }

    private static func collectTable(lines: [String], start: Int) -> ([[String]], Int) {
        var tableLines: [[String]] = []
        var i = start
        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("|") else { break }
            let content = trimmed.replacingOccurrences(of: "|", with: "")
                .replacingOccurrences(of: "-", with: "")
                .replacingOccurrences(of: " ", with: "")
            if content.isEmpty {
                i += 1
                continue
            }
            let cells = trimmed
                .components(separatedBy: "|")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if !cells.isEmpty {
                tableLines.append(cells)
            }
            i += 1
        }
        return (tableLines, i - start)
    }

    private static func renderTable(_ rows: [[String]], into result: inout AttributedString) {
        guard !rows.isEmpty else { return }
        let colCount = rows.map(\.count).max() ?? 0
        guard colCount > 0 else { return }
        for (rowIdx, row) in rows.enumerated() {
            let isHeader = rowIdx == 0
            let cells = (0..<colCount).map { col in
                col < row.count ? row[col].replacingOccurrences(of: "`", with: "") : ""
            }
            var line = AttributedString(cells.joined(separator: "    "))
            if isHeader {
                line.font = .body.bold()
            } else {
                line.font = .body
            }
            result.append(line)
            result.append(AttributedString("\n"))
        }
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

    private static func looksLikePath(_ text: String) -> Bool {
        text.contains("/") || text.contains("\\") || text.hasSuffix(".md") || text.hasSuffix(".swift")
            || text.hasSuffix(".json") || text.hasSuffix(".yml") || text.hasSuffix(".yaml")
            || text.hasSuffix(".txt") || text.hasSuffix(".sh") || text.hasSuffix(".py")
            || text.hasSuffix(".js") || text.hasSuffix(".ts") || text.hasSuffix(".go")
            || text.hasSuffix(".rs") || text.hasSuffix(".toml") || text.hasSuffix(".cfg")
    }

    private static func parseInline(_ text: String) -> AttributedString {
        var result = AttributedString()
        var i = text.startIndex
        while i < text.endIndex {
            if text[i] == "`" {
                if let end = text[i...].dropFirst().firstIndex(of: "`") {
                    let codeStart = text.index(after: i)
                    let codeText = String(text[codeStart..<end])
                    if looksLikePath(codeText) {
                        // Paths get their own tint for readability, but are never
                        // linked: turning them into `file://` links let a malicious
                        // Skill document launch executables outside the App Sandbox,
                        // and trained readers to click them.
                        var path = AttributedString(codeText)
                        path.font = .system(.body, design: .monospaced)
                        path.foregroundColor = .secondary
                        result.append(path)
                    } else {
                        var code = AttributedString(codeText)
                        code.font = .system(.body, design: .monospaced)
                        code.foregroundColor = .orange
                        result.append(code)
                    }
                    i = text.index(after: end)
                    continue
                }
            }
            if text[i] == "*" && text.index(after: i) < text.endIndex && text[text.index(after: i)] == "*" {
                let boldStart = text.index(i, offsetBy: 2)
                if let endRange = text[boldStart...].range(of: "**") {
                    var bold = AttributedString(String(text[boldStart..<endRange.lowerBound]))
                    bold.font = .body.bold()
                    result.append(bold)
                    i = endRange.upperBound
                    continue
                }
            }
            if text[i] == "*" {
                let italicStart = text.index(after: i)
                if let end = text[italicStart...].firstIndex(of: "*") {
                    var italic = AttributedString(String(text[italicStart..<end]))
                    italic.font = .body.italic()
                    result.append(italic)
                    i = text.index(after: end)
                    continue
                }
            }
            if text[i] == "[" {
                let linkTextStart = text.index(after: i)
                if let closeBracket = text[linkTextStart...].firstIndex(of: "]"),
                   text.index(after: closeBracket) < text.endIndex,
                   text[text.index(after: closeBracket)] == "(" {
                    let linkText = String(text[linkTextStart..<closeBracket])
                    let urlStart = text.index(closeBracket, offsetBy: 2)
                    if let closeParen = text[urlStart...].firstIndex(of: ")") {
                        let urlString = String(text[urlStart..<closeParen])
                        if let url = sanitizedLinkURL(urlString) {
                            var link = AttributedString(linkText)
                            link.foregroundColor = .blue
                            link.underlineStyle = .single
                            link.link = url
                            result.append(link)
                        } else {
                            // Unsupported scheme. Keep the label and disclose the
                            // raw destination so the reader can judge it, but do
                            // not make it clickable.
                            var label = AttributedString(linkText)
                            label.font = .body
                            result.append(label)
                            var target = AttributedString(" (\(urlString))")
                            target.font = .system(.body, design: .monospaced)
                            target.foregroundColor = .secondary
                            result.append(target)
                        }
                        i = text.index(after: closeParen)
                        continue
                    }
                }
            }
            var single = AttributedString(String(text[i]))
            single.font = .body
            result.append(single)
            i = text.index(after: i)
        }
        return result
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
