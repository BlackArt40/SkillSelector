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

    private func redactAuthorization(in value: String) -> String {
        let authorizationPattern = #"(?i)\b(authorization\s*:\s*)(?:bearer|basic)\s+[^\s,;]+"#
        guard let authorizationRegex = try? NSRegularExpression(pattern: authorizationPattern) else {
            return value
        }
        let firstRange = NSRange(value.startIndex..<value.endIndex, in: value)
        let withoutAuthorization = authorizationRegex.stringByReplacingMatches(
            in: value,
            range: firstRange,
            withTemplate: "$1" + NSRegularExpression.escapedTemplate(for: Self.redactedValue)
        )
        let bearerPattern = #"(?i)\b(bearer\s+)[A-Za-z0-9._~-]{8,}"#
        guard let bearerRegex = try? NSRegularExpression(pattern: bearerPattern) else {
            return withoutAuthorization
        }
        let secondRange = NSRange(
            withoutAuthorization.startIndex..<withoutAuthorization.endIndex,
            in: withoutAuthorization
        )
        return bearerRegex.stringByReplacingMatches(
            in: withoutAuthorization,
            range: secondRange,
            withTemplate: "$1" + NSRegularExpression.escapedTemplate(for: Self.redactedValue)
        )
    }

    private func redactAssignments(in value: String) -> String {
        let pattern = #"(?i)\b((?:token|access[_-]?token|api[_-]?key|password|passwd|secret|client[_-]?secret)\s*[=:]\s*)(?:\"[^\"]*\"|'[^']*'|[^\s,;]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return value }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.stringByReplacingMatches(
            in: value,
            range: range,
            withTemplate: "$1" + NSRegularExpression.escapedTemplate(for: Self.redactedValue)
        )
    }
}
