import Foundation
import Yams

public enum FrontmatterParser {
    public static func parse(_ text: String) -> ParsedSkillDocument {
        let lines = normalizedLines(text)
        var fields: [String: String] = [:]
        var issues: [ParseIssue] = []
        var bodyLines = lines
        var skipsFrontmatterPairsInBody = false
        let hasFrontmatter = lines.first == "---"

        if hasFrontmatter {
            if let boundary = lines.dropFirst().firstIndex(of: "---") {
                parseFrontmatterBlock(
                    Array(lines[1..<boundary]),
                    into: &fields,
                    issues: &issues
                )
                bodyLines = Array(lines[(boundary + 1)...])
            } else {
                issues.append(ParseIssue(line: 1, code: .missingClosingFrontmatterBoundary))
                parseFrontmatterBlock(
                    Array(lines.dropFirst().prefix(while: { !isMarkdownBodyLine($0) })),
                    into: &fields,
                    issues: &issues
                )
                bodyLines = Array(lines.dropFirst())
                skipsFrontmatterPairsInBody = true
            }
        }

        if hasFrontmatter {
            for requiredKey in ["name", "description"]
            where fields[requiredKey]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                issues.append(
                    ParseIssue(code: .missingRequiredFrontmatterField, arguments: [requiredKey])
                )
            }
        } else {
            issues.append(ParseIssue(line: 1, code: .missingFrontmatterBoundary))
        }

        let bodyMetadata = extractBodyMetadata(
            from: bodyLines,
            skippingFrontmatterPairs: skipsFrontmatterPairsInBody
        )
        return ParsedSkillDocument(
            name: fields["name"],
            description: fields["description"],
            title: bodyMetadata.title,
            firstDescriptiveParagraph: bodyMetadata.paragraph,
            fields: fields,
            issues: issues
        )
    }

    private static func normalizedLines(_ text: String) -> [String] {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
    }

    /// Lines after the closing frontmatter boundary when the text opens with
    /// one, otherwise the whole text.
    ///
    /// Single implementation of body-extraction for the display path; parsing
    /// itself requires a `---` delimiter in column zero, while this helper
    /// tolerates whitespace around the delimiters because it also feeds the
    /// renderer.
    public static func bodyLines(from text: String) -> [String] {
        let lines = normalizedLines(text)
        let opensWithBoundary = lines.first?.trimmingCharacters(in: .whitespaces) == "---"
        guard opensWithBoundary,
              let boundary = lines.dropFirst().firstIndex(where: {
                  $0.trimmingCharacters(in: .whitespaces) == "---"
              }) else {
            return lines
        }
        return Array(lines[(boundary + 1)...])
    }

    /// Parses the frontmatter block with Yams. Nested mappings and sequences
    /// (e.g. `metadata:` sub-objects, `allowed-tools:` lists) are fully
    /// supported and simply ignored for display — only top-level scalar
    /// values become `fields`. A genuine YAML syntax error produces a single
    /// `.yamlParseFailed` diagnostic instead of the previous per-line
    /// conservative errors.
    private static func parseFrontmatterBlock(
        _ lines: [String],
        into fields: inout [String: String],
        issues: inout [ParseIssue]
    ) {
        let yaml = lines.joined(separator: "\n")
        guard !yaml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let node: Node?
        do {
            node = try Yams.compose(yaml: yaml)
        } catch {
            issues.append(
                ParseIssue(
                    code: .yamlParseFailed,
                    arguments: [error.localizedDescription]
                )
            )
            return
        }

        guard case .mapping(let mapping) = node else {
            // A scalar or sequence root cannot carry named fields.
            return
        }
        for (keyNode, valueNode) in mapping {
            guard case .scalar(let keyScalar) = keyNode,
                  case .scalar(let valueScalar) = valueNode else {
                continue
            }
            // Trim block/chomp artifacts (Yams keeps a trailing newline on
            // folded scalars) the same way the hand-written parser did.
            fields[keyScalar.string] = valueScalar.string
                .trimmingCharacters(in: .newlines)
        }
    }

    private static func isMarkdownBodyLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("#") || trimmed.hasPrefix("```")
    }

    private static func extractBodyMetadata(
        from lines: [String],
        skippingFrontmatterPairs: Bool
    ) -> (title: String?, paragraph: String?) {
        let title = lines.lazy.compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("# ") else { return nil }
            let value = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }.first

        var paragraphLines: [String] = []
        var insideFence = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                insideFence.toggle()
                continue
            }
            if insideFence { continue }
            if trimmed.isEmpty {
                if !paragraphLines.isEmpty { break }
                continue
            }
            if trimmed == "---"
                || trimmed.hasPrefix("#")
                || (skippingFrontmatterPairs && looksLikeFrontmatterPair(trimmed)) {
                if !paragraphLines.isEmpty { break }
                continue
            }
            if trimmed.hasPrefix("-") || trimmed.hasPrefix("*") || trimmed.hasPrefix(">") {
                if !paragraphLines.isEmpty { break }
                continue
            }
            paragraphLines.append(trimmed)
        }

        return (
            title,
            paragraphLines.isEmpty ? nil : paragraphLines.joined(separator: " ")
        )
    }

    private static func looksLikeFrontmatterPair(_ line: String) -> Bool {
        guard let colon = line.firstIndex(of: ":") else { return false }
        return isValidKey(String(line[..<colon]))
    }

    private static func isValidKey(_ key: String) -> Bool {
        !key.isEmpty && key.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
        }
    }
}
