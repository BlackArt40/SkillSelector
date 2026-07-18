import Foundation

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
                parseFrontmatter(
                    Array(lines[1..<boundary]),
                    into: &fields,
                    issues: &issues
                )
                bodyLines = Array(lines[(boundary + 1)...])
            } else {
                issues.append(ParseIssue(line: 1, code: .missingClosingFrontmatterBoundary))
                parseFrontmatter(
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

    private static func parseFrontmatter(
        _ lines: [String],
        into fields: inout [String: String],
        issues: inout [ParseIssue]
    ) {
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let lineNumber = index + 2
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                index += 1
                continue
            }

            guard line.first?.isWhitespace != true,
                  let colon = line.firstIndex(of: ":") else {
                issues.append(ParseIssue(line: lineNumber, code: .expectedKeyValuePair))
                index += 1
                continue
            }

            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            guard isValidKey(key) else {
                issues.append(ParseIssue(line: lineNumber, code: .invalidFrontmatterKey))
                index += 1
                continue
            }

            let rawValue = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            if rawValue == "|" || rawValue == ">" {
                let blockStart = index + 1
                var blockEnd = blockStart
                while blockEnd < lines.count {
                    let candidate = lines[blockEnd]
                    if !candidate.isEmpty && candidate.first?.isWhitespace != true {
                        break
                    }
                    blockEnd += 1
                }

                let block = Array(lines[blockStart..<blockEnd])
                if block.isEmpty {
                    issues.append(ParseIssue(line: lineNumber, code: .blockValueHasNoContent))
                    fields[key] = ""
                } else if block.contains(where: { !$0.isEmpty && $0.first?.isWhitespace != true }) {
                    issues.append(ParseIssue(line: lineNumber, code: .blockValueMustBeIndented))
                } else {
                    fields[key] = blockValue(block, folded: rawValue == ">")
                }
                index = blockEnd
                continue
            }

            switch scalarValue(rawValue) {
            case .success(let value):
                fields[key] = value
            case .failure(let error):
                issues.append(ParseIssue(line: lineNumber, code: error.code))
            }
            index += 1
        }
    }

    private static func isValidKey(_ key: String) -> Bool {
        !key.isEmpty && key.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
        }
    }

    private static func scalarValue(_ rawValue: String) -> Result<String, ScalarError> {
        guard !rawValue.isEmpty else { return .success("") }

        if rawValue.hasPrefix("\"") {
            guard rawValue.count >= 2, rawValue.hasSuffix("\"") else {
                return .failure(ScalarError(code: .unterminatedQuotedString))
            }
            let inner = String(rawValue.dropFirst().dropLast())
            var result = ""
            var escaping = false
            for character in inner {
                if escaping {
                    switch character {
                    case "n": result.append("\n")
                    case "r": result.append("\r")
                    case "t": result.append("\t")
                    case "\"", "\\": result.append(character)
                    default:
                        return .failure(ScalarError(code: .unsupportedEscapeSequence))
                    }
                    escaping = false
                } else if character == "\\" {
                    escaping = true
                } else {
                    result.append(character)
                }
            }
            guard !escaping else {
                return .failure(ScalarError(code: .unterminatedEscapeSequence))
            }
            return .success(result)
        }

        if rawValue.hasPrefix("'") {
            guard rawValue.count >= 2, rawValue.hasSuffix("'") else {
                return .failure(ScalarError(code: .unterminatedQuotedString))
            }
            return .success(
                String(rawValue.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
            )
        }

        if rawValue.hasPrefix("[") || rawValue.hasPrefix("{") {
            return .failure(ScalarError(code: .collectionsNotSupported))
        }
        if rawValue.hasPrefix("&") || rawValue.hasPrefix("*") || rawValue.hasPrefix("!") {
            return .failure(ScalarError(code: .yamlTagsAndAliasesNotSupported))
        }
        return .success(rawValue)
    }

    private static func blockValue(_ lines: [String], folded: Bool) -> String {
        let nonEmpty = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let indentation = nonEmpty.map(leadingWhitespaceCount).min() ?? 0
        let stripped = lines.map { line -> String in
            guard !line.isEmpty else { return "" }
            return String(line.dropFirst(min(indentation, line.count)))
        }

        if !folded {
            return stripped.joined(separator: "\n").trimmingCharacters(in: .newlines)
        }

        var paragraphs: [String] = []
        var current: [String] = []
        for line in stripped {
            if line.isEmpty {
                if !current.isEmpty {
                    paragraphs.append(current.joined(separator: " "))
                    current.removeAll()
                }
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty {
            paragraphs.append(current.joined(separator: " "))
        }
        return paragraphs.joined(separator: "\n")
    }

    private static func leadingWhitespaceCount(_ line: String) -> Int {
        line.prefix(while: \Character.isWhitespace).count
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
}

private struct ScalarError: Error {
    let code: DiagnosticCode
}
