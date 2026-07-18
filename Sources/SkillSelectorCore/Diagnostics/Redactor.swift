import Foundation

public struct Redactor: Sendable {
    public static let redactedValue = "<redacted>"
    public static let redactedRemoteBody = "<redacted remote response body>"

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

    public func redact(environment: [String: String]) -> [String: String] {
        environment.mapValues { redact($0) }.reduce(into: [:]) { result, pair in
            let key = pair.key
            let originalValue = environment[key] ?? ""
            result[key] = isSensitiveEnvironmentKey(key) || isTokenShaped(originalValue)
                ? Self.redactedValue
                : pair.value
        }
    }

    public func redact(arguments: [String]) -> [String] {
        enum PendingRedaction {
            case secret
            case header
        }
        var result: [String] = []
        var pendingRedaction: PendingRedaction?
        for argument in arguments {
            if let pending = pendingRedaction {
                switch pending {
                case .secret: result.append(Self.redactedValue)
                case .header: result.append(redactHeader(argument))
                }
                pendingRedaction = nil
                continue
            }
            if isHeaderFlag(argument) {
                result.append(argument)
                pendingRedaction = .header
                continue
            }
            if isSensitiveFlag(argument) {
                result.append(argument)
                pendingRedaction = .secret
                continue
            }
            if let equals = argument.firstIndex(of: "=") {
                let flag = String(argument[..<equals])
                if isSensitiveFlag(flag) {
                    result.append(flag + "=" + Self.redactedValue)
                    continue
                }
            }
            result.append(redact(argument))
        }
        return result
    }

    public func redactRemoteResponseBody(_ body: String) -> String {
        _ = body
        return Self.redactedRemoteBody
    }

    private func redactPaths(in value: String) -> String {
        pathReplacements.reduce(value) { current, item in
            replacePath(item.path, with: item.replacement, in: current)
        }
    }

    private func replacePath(_ path: String, with replacement: String, in value: String) -> String {
        guard !path.isEmpty else { return value }
        let pattern = NSRegularExpression.escapedPattern(for: path) + #"(?=$|/|[\s,;:)\]}])"#
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

    private func redactHeader(_ argument: String) -> String {
        guard let colon = argument.firstIndex(of: ":") else { return redact(argument) }
        let name = argument[..<colon]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let sensitiveNames = Set([
            "authorization", "proxy-authorization", "cookie", "set-cookie", "x-api-key",
        ])
        guard sensitiveNames.contains(name) else { return redact(argument) }
        let valueStart = argument.index(after: colon)
        let whitespace = argument[valueStart...].prefix { $0.isWhitespace }
        return String(argument[...colon]) + whitespace + Self.redactedValue
    }

    private func isSensitiveFlag(_ argument: String) -> Bool {
        let normalized = argument
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        return [
            "token", "access-token", "api-key", "apikey", "password", "passwd",
            "secret", "client-secret", "authorization", "cookie", "private-key",
        ].contains(normalized)
    }

    private func isHeaderFlag(_ argument: String) -> Bool {
        argument == "-H" || argument == "--header"
    }

    private func isSensitiveEnvironmentKey(_ key: String) -> Bool {
        let components = key.uppercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let sensitive = Set([
            "TOKEN", "SECRET", "PASSWORD", "PASSWD", "CREDENTIAL", "CREDENTIALS",
            "AUTHORIZATION", "COOKIE", "PRIVATEKEY",
        ])
        if components.contains(where: sensitive.contains) { return true }
        let pairs = zip(components, components.dropFirst())
        return pairs.contains { first, second in
            (first == "API" && second == "KEY")
                || (first == "PRIVATE" && second == "KEY")
                || (first == "ACCESS" && second == "TOKEN")
                || (first == "CLIENT" && second == "SECRET")
        }
    }

    private func isTokenShaped(_ value: String) -> Bool {
        let patterns = [
            #"^(?:gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,}|npm_[A-Za-z0-9]{20,}|sk-[A-Za-z0-9_-]{20,})$"#,
            #"^[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}$"#,
        ]
        return patterns.contains { pattern in
            value.range(of: pattern, options: .regularExpression) != nil
        }
    }
}
