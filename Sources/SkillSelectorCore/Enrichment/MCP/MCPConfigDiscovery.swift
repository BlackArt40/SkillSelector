import CryptoKit
import Foundation

public struct MCPConfigDiscovery: Sendable {
    public init() {}

    public func discover(in rootURL: URL) throws -> [MCPServerConfiguration] {
        let root = rootURL.standardizedFileURL
        var discovered: [MCPServerConfiguration] = []
        for input in Self.inputs(root: root) where FileManager.default.fileExists(atPath: input.url.path) {
            let data: Data
            do { data = try Data(contentsOf: input.url, options: [.mappedIfSafe]) }
            catch { throw MCPConfigDiscoveryError.unreadableConfiguration(input.url) }
            do {
                switch input.format {
                case .json:
                    discovered.append(contentsOf: try parseJSON(data, input: input))
                case .toml:
                    discovered.append(contentsOf: try parseCodexTOML(data, input: input))
                }
            } catch let error as MCPConfigDiscoveryError {
                throw error
            } catch {
                throw MCPConfigDiscoveryError.invalidConfiguration(input.url)
            }
        }
        return discovered.sorted {
            if $0.name != $1.name { return $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return $0.id < $1.id
        }
    }

    private enum Format { case json, toml }

    private struct Input {
        let url: URL
        let source: MCPConfigSource
        let format: Format
        let fingerprintPath: String
    }

    private static func inputs(root: URL) -> [Input] {
        [
            Input(url: root.appendingPathComponent(".claude.json"), source: .claude, format: .json, fingerprintPath: ".claude.json"),
            Input(url: root.appendingPathComponent(".claude/mcp.json"), source: .claude, format: .json, fingerprintPath: ".claude/mcp.json"),
            Input(url: root.appendingPathComponent(".codex/config.toml"), source: .codex, format: .toml, fingerprintPath: ".codex/config.toml"),
            Input(url: root.appendingPathComponent(".codex/mcp.json"), source: .codex, format: .json, fingerprintPath: ".codex/mcp.json"),
            Input(url: root.appendingPathComponent("mcp.json"), source: .generic, format: .json, fingerprintPath: "mcp.json"),
        ]
    }

    private func parseJSON(_ data: Data, input: Input) throws -> [MCPServerConfiguration] {
        guard data.count <= 1_048_576,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MCPConfigDiscoveryError.invalidConfiguration(input.url)
        }
        let container = (root["mcpServers"] as? [String: Any])
            ?? (root["servers"] as? [String: Any])
            ?? root
        return container.compactMap { name, raw in
            guard let dictionary = raw as? [String: Any] else { return nil }
            return makeServer(name: name, dictionary: dictionary, input: input)
        }
    }

    private func parseCodexTOML(_ data: Data, input: Input) throws -> [MCPServerConfiguration] {
        guard data.count <= 1_048_576, let text = String(data: data, encoding: .utf8) else {
            throw MCPConfigDiscoveryError.invalidConfiguration(input.url)
        }
        var sections: [String: [String: Any]] = [:]
        var serverBlocks: [String: String] = [:]
        var currentName: String?
        var currentNestedPath: [String] = []
        var pendingAssignment = ""

        func applyPendingAssignment() {
            defer { pendingAssignment = "" }
            guard let currentName,
                  let equal = firstTOMLEquals(in: pendingAssignment) else { return }
            let key = unquote(pendingAssignment[..<equal].trimmingCharacters(in: .whitespacesAndNewlines))
            let value = pendingAssignment[pendingAssignment.index(after: equal)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let parsed = parseTOMLValue(value)
            setTOMLValue(
                parsed,
                for: currentNestedPath + [key],
                in: &sections[currentName, default: [:]]
            )
        }

        // Keep physical lines for the identity digest while accumulating
        // multiline values for the limited configuration fields we execute.
        for rawLine in text.components(separatedBy: "\n") {
            let line = stripTOMLComment(String(rawLine)).trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("["), line.hasSuffix("]") {
                applyPendingAssignment()
                let section = String(line.dropFirst().dropLast())
                if section.hasPrefix("mcp_servers.") {
                    let path = splitTOMLList(
                        String(section.dropFirst("mcp_servers.".count)),
                        separator: "."
                    )
                    currentName = path.first.map(unquote)
                    currentNestedPath = path.dropFirst().map(unquote)
                    if let currentName {
                        sections[currentName, default: [:]] = sections[currentName, default: [:]]
                        serverBlocks[currentName, default: ""] += rawLine + "\n"
                    }
                } else {
                    currentName = nil
                    currentNestedPath = []
                }
                continue
            }
            if let currentName {
                serverBlocks[currentName, default: ""] += rawLine + "\n"
            }
            guard currentName != nil, !line.isEmpty else { continue }
            pendingAssignment += pendingAssignment.isEmpty ? line : "\n\(line)"
            if tomlValueIsComplete(pendingAssignment) {
                applyPendingAssignment()
            }
        }
        applyPendingAssignment()
        return sections.compactMap {
            makeServer(
                name: $0.key,
                dictionary: $0.value,
                input: input,
                sourceDigest: sha256Hex(serverBlocks[$0.key, default: ""])
            )
        }
    }

    private func makeServer(
        name: String,
        dictionary: [String: Any],
        input: Input,
        sourceDigest: String? = nil
    ) -> MCPServerConfiguration? {
        let baseIdentifier = "\(input.source.rawValue):\(input.fingerprintPath):\(name)"
        let configurationFingerprint = canonicalConfigurationFingerprint(
            dictionary,
            baseIdentifier: baseIdentifier,
            sourceDigest: sourceDigest
        )
        let identifier = "\(baseIdentifier):\(configurationFingerprint)"
        if let command = dictionary["command"] as? String, !command.isEmpty {
            let executable = resolvedExecutable(command)
            let arguments = dictionary["args"] as? [String] ?? []
            let environment = stringDictionary(dictionary["env"])
            let workingDirectory = (dictionary["cwd"] as? String).map {
                resolvedPath($0, relativeTo: input.url.deletingLastPathComponent())
            }
            let approval = ApprovedCommand(
                executablePath: executable,
                arguments: arguments,
                configurationFingerprint: identifier
            )
            return MCPServerConfiguration(
                id: identifier,
                name: name,
                source: input.source,
                configurationURL: input.url,
                transport: .stdio(
                    executable: executable,
                    arguments: arguments,
                    environment: environment,
                    workingDirectory: workingDirectory
                ),
                support: .supported,
                commandApproval: approval,
                isPackageRunner: Self.packageRunners.contains(URL(fileURLWithPath: executable).lastPathComponent.lowercased())
            )
        }
        guard let rawURL = dictionary["url"] as? String, let url = URL(string: rawURL) else { return nil }
        let type = (dictionary["type"] as? String)?.lowercased()
        let legacy = type == "sse" || url.path.lowercased().hasSuffix("/sse")
        let headers = stringDictionary(dictionary["headers"] ?? dictionary["http_headers"])
        return MCPServerConfiguration(
            id: identifier,
            name: name,
            source: input.source,
            configurationURL: input.url,
            transport: legacy ? .legacySSE(url) : .streamableHTTP(endpoint: url, headers: headers),
            support: legacy ? .unsupportedLegacySSE : .supported
        )
    }

    private static let packageRunners: Set<String> = ["npx", "uvx", "pnpx", "bunx"]
    private static let executableDirectories = [
        "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
    ]

    private func resolvedExecutable(_ value: String) -> String {
        if value.hasPrefix("/") { return URL(fileURLWithPath: value).standardizedFileURL.path }
        guard !value.isEmpty, !value.contains("/"), !value.contains("\\") else { return value }
        for directory in Self.executableDirectories {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(value).path
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return value
    }

    private func resolvedPath(_ value: String, relativeTo baseURL: URL) -> String {
        let url = value.hasPrefix("/")
            ? URL(fileURLWithPath: value)
            : baseURL.appendingPathComponent(value)
        return url.standardizedFileURL.path
    }

    private func stringDictionary(_ raw: Any?) -> [String: String] {
        (raw as? [String: Any])?.reduce(into: [:]) { result, element in
            if let value = element.value as? String { result[element.key] = value }
        } ?? [:]
    }

    private func canonicalConfigurationFingerprint(
        _ dictionary: [String: Any],
        baseIdentifier: String,
        sourceDigest: String? = nil
    ) -> String {
        let canonicalData = (try? JSONSerialization.data(
            withJSONObject: dictionary,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )) ?? Data()
        var identityArguments = [canonicalData.base64EncodedString()]
        if let sourceDigest { identityArguments.append(sourceDigest) }
        return CommandApproval.fingerprint(
            executablePath: "mcp-server-configuration",
            arguments: identityArguments,
            configurationFingerprint: baseIdentifier
        )
    }

    private func sha256Hex(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func stripTOMLComment(_ value: String) -> String {
        var quoted = false
        var escaped = false
        for index in value.indices {
            let character = value[index]
            if character == "\\" && quoted { escaped.toggle(); continue }
            if character == "\"" && !escaped { quoted.toggle() }
            if character == "#" && !quoted { return String(value[..<index]) }
            escaped = false
        }
        return value
    }

    private func parseTOMLValue(_ value: String) -> Any {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if (trimmed.hasPrefix("\"") && trimmed.hasSuffix("\""))
            || (trimmed.hasPrefix("'") && trimmed.hasSuffix("'")) {
            return unquote(trimmed)
        }
        if trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
            let values = splitTOMLList(String(trimmed.dropFirst().dropLast()), separator: ",")
                .map { parseTOMLValue($0) }
            if values.allSatisfy({ $0 is String }) { return values.compactMap { $0 as? String } }
            return values
        }
        if trimmed.hasPrefix("{"), trimmed.hasSuffix("}") {
            var result: [String: Any] = [:]
            for entry in splitTOMLList(String(trimmed.dropFirst().dropLast()), separator: ",") {
                guard let equal = entry.firstIndex(of: "=") else { continue }
                let key = unquote(entry[..<equal].trimmingCharacters(in: .whitespaces))
                result[key] = parseTOMLValue(
                    entry[entry.index(after: equal)...].trimmingCharacters(in: .whitespaces)
                )
            }
            return result
        }
        if trimmed == "true" { return true }
        if trimmed == "false" { return false }
        if let integer = Int(trimmed) { return integer }
        if let number = Double(trimmed) { return number }
        return trimmed
    }

    private func splitTOMLList(_ value: String, separator: Character) -> [String] {
        var values: [String] = []
        var start = value.startIndex
        var quotedBy: Character?
        var escaped = false
        var depth = 0
        for index in value.indices {
            let character = value[index]
            if character == "\\" && quotedBy == "\"" { escaped.toggle(); continue }
            if (character == "\"" || character == "'") && !escaped {
                quotedBy = quotedBy == nil ? character : (quotedBy == character ? nil : quotedBy)
            } else if quotedBy == nil {
                if character == "[" || character == "{" { depth += 1 }
                if character == "]" || character == "}" { depth -= 1 }
                if character == separator && depth == 0 {
                    values.append(String(value[start..<index]).trimmingCharacters(in: .whitespacesAndNewlines))
                    start = value.index(after: index)
                }
            }
            escaped = false
        }
        values.append(String(value[start...]).trimmingCharacters(in: .whitespacesAndNewlines))
        return values.filter { !$0.isEmpty }
    }

    private func firstTOMLEquals(in value: String) -> String.Index? {
        var quotedBy: Character?
        var escaped = false
        for index in value.indices {
            let character = value[index]
            if character == "\\" && quotedBy == "\"" { escaped.toggle(); continue }
            if (character == "\"" || character == "'") && !escaped {
                quotedBy = quotedBy == nil ? character : (quotedBy == character ? nil : quotedBy)
            } else if character == "=" && quotedBy == nil {
                return index
            }
            escaped = false
        }
        return nil
    }

    private func tomlValueIsComplete(_ assignment: String) -> Bool {
        guard let equal = firstTOMLEquals(in: assignment) else { return false }
        let value = assignment[assignment.index(after: equal)...]
        var quotedBy: Character?
        var escaped = false
        var nesting = 0
        for character in value {
            if character == "\\" && quotedBy == "\"" { escaped.toggle(); continue }
            if (character == "\"" || character == "'") && !escaped {
                quotedBy = quotedBy == nil ? character : (quotedBy == character ? nil : quotedBy)
            } else if quotedBy == nil {
                if character == "[" || character == "{" { nesting += 1 }
                if character == "]" || character == "}" { nesting -= 1 }
            }
            escaped = false
        }
        return quotedBy == nil && nesting == 0
    }

    private func setTOMLValue(_ value: Any, for path: [String], in dictionary: inout [String: Any]) {
        guard let key = path.first else { return }
        guard path.count > 1 else {
            dictionary[key] = value
            return
        }
        var nested = dictionary[key] as? [String: Any] ?? [:]
        setTOMLValue(value, for: Array(path.dropFirst()), in: &nested)
        dictionary[key] = nested
    }

    private func unquote(_ value: String) -> String {
        guard value.count >= 2 else { return value }
        if value.first == "'", value.last == "'" { return String(value.dropFirst().dropLast()) }
        guard value.first == "\"", value.last == "\"" else { return value }
        if let data = value.data(using: .utf8),
           let decoded = try? JSONSerialization.jsonObject(with: data) as? String { return decoded }
        return String(value.dropFirst().dropLast())
    }
}
