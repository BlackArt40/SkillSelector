import Foundation

public struct Redactor: Sendable {
    public static let redactedValue = "<redacted>"

    private struct PathReplacement: Sendable {
        let path: String
        let replacement: String
    }

    private let pathReplacements: [PathReplacement]

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        projectDirectories: [URL] = []
    ) {
        var replacements = projectDirectories.enumerated().map { offset, url in
            PathReplacement(
                path: url.standardizedFileURL.path,
                replacement: "<project:\(offset + 1)>"
            )
        }
        replacements.append(PathReplacement(
            path: homeDirectory.standardizedFileURL.path,
            replacement: "<home>"
        ))
        pathReplacements = replacements
            .filter { $0.path != "/" }
            .sorted { lhs, rhs in
                if lhs.path.count != rhs.path.count { return lhs.path.count > rhs.path.count }
                return lhs.path < rhs.path
            }
    }

    public func redact(_ value: String) -> String {
        redactAssignments(in: redactAuthorization(in: redactPaths(in: value)))
    }

    private func redactPaths(in value: String) -> String {
        pathReplacements.reduce(value) { current, item in
            replacePath(item.path, with: item.replacement, in: current)
        }
    }

    private func replacePath(_ path: String, with replacement: String, in value: String) -> String {
        guard !path.isEmpty else { return value }
        let pattern = "(?i)" + NSRegularExpression.escapedPattern(for: path)
            + #"(?=$|/|[\s,;:.!?\)\]\}'\"“”‘’])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return value }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.stringByReplacingMatches(
            in: value,
            range: range,
            withTemplate: NSRegularExpression.escapedTemplate(for: replacement)
        )
    }

    private func applying(pattern: String, template: String, to value: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return value }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.stringByReplacingMatches(in: value, range: range, withTemplate: template)
    }

    private var redactedTemplate: String {
        "$1" + NSRegularExpression.escapedTemplate(for: Self.redactedValue)
    }

    private func redactAuthorization(in value: String) -> String {
        var current = value
        // Labeled Authorization header with an explicit scheme (original
        // narrow rule, kept for byte-for-byte compatible results).
        current = applying(
            pattern: #"(?i)\b(authorization\s*:\s*)(?:bearer|basic)\s+[^\s,;]+"#,
            template: redactedTemplate,
            to: current
        )
        // Fallback for every other Authorization scheme (digest, token,
        // negotiation …): swallow the whole header value up to the next
        // segment separator so non-bearer schemes no longer leak.
        current = applying(
            pattern: #"(?i)\b(authorization\s*:\s*)(?![\s;,]*$)[^\r\n;,]*[^\r\n\s;,]"#,
            template: redactedTemplate,
            to: current
        )
        // Bare "Bearer <token>" without the header label (original rule).
        current = applying(
            pattern: #"(?i)\b(bearer\s+)[A-Za-z0-9._~-]{8,}"#,
            template: redactedTemplate,
            to: current
        )
        // Bare credentials after a "token " label (GitHub style).
        current = applying(
            pattern: #"(?i)\b(token\s+)((?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]+|github_pat_[A-Za-z0-9_]+)"#,
            template: redactedTemplate,
            to: current
        )
        // Unlabeled credential prefixes (sk-…, ghp_… and friends).
        current = applying(
            pattern: #"\b((?:sk|ghp|gho|ghu|ghs|ghr)[_-])[A-Za-z0-9._~-]{8,}"#,
            template: redactedTemplate,
            to: current
        )
        // URL userinfo: https://user:password@host keeps the user, drops the
        // password. host:port without a trailing "@" never matches, so
        // explicit ports stay intact.
        current = applying(
            pattern: #"(?i)\b(https?://[^/\s:@]+:)[^/\s@]+(@)"#,
            template: "$1" + NSRegularExpression.escapedTemplate(for: Self.redactedValue) + "$2",
            to: current
        )
        return current
    }

    private func redactAssignments(in value: String) -> String {
        // The key may be wrapped in quotes so JSON-style config shapes
        // ("api_key": "sk-…") are covered — the most common MCP env form.
        let pattern = #"(?i)\b((?:['\"])?(?:token|access[_-]?token|api[_-]?key|password|passwd|secret|client[_-]?secret)(?:['\"])?\s*[=:]\s*)(?:\"[^\"]*\"|'[^']*'|[^\s,;]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return value }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.stringByReplacingMatches(
            in: value,
            range: range,
            withTemplate: "$1" + NSRegularExpression.escapedTemplate(for: Self.redactedValue)
        )
    }
}
