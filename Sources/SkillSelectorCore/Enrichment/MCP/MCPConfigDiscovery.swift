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
        var currentName: String?
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = stripTOMLComment(String(rawLine)).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                let section = String(line.dropFirst().dropLast())
                if section.hasPrefix("mcp_servers.") {
                    currentName = unquote(String(section.dropFirst("mcp_servers.".count)))
                    if let currentName { sections[currentName, default: [:]] = sections[currentName, default: [:]] }
                } else {
                    currentName = nil
                }
                continue
            }
            guard let currentName, let equal = line.firstIndex(of: "=") else { continue }
            let key = line[..<equal].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: equal)...].trimmingCharacters(in: .whitespaces)
            if key == "args" { sections[currentName]?[key] = parseStringArray(value) }
            else if key == "command" || key == "url" || key == "type" {
                sections[currentName]?[key] = unquote(value)
            }
        }
        return sections.compactMap { makeServer(name: $0.key, dictionary: $0.value, input: input) }
    }

    private func makeServer(name: String, dictionary: [String: Any], input: Input) -> MCPServerConfiguration? {
        let baseIdentifier = "\(input.source.rawValue):\(input.fingerprintPath):\(name)"
        if let command = dictionary["command"] as? String, !command.isEmpty {
            let executable = resolvedExecutable(command)
            let arguments = dictionary["args"] as? [String] ?? []
            let environment = (dictionary["env"] as? [String: Any])?.reduce(into: [String: String]()) {
                if let value = $1.value as? String { $0[$1.key] = value }
            } ?? [:]
            let configurationFingerprint = CommandApproval.fingerprint(
                executablePath: executable,
                arguments: arguments + environment.sorted(by: { $0.key < $1.key }).map {
                    "env:\($0.key)=\($0.value)"
                },
                configurationFingerprint: baseIdentifier
            )
            let identifier = "\(baseIdentifier):\(configurationFingerprint)"
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
                transport: .stdio(executable: executable, arguments: arguments, environment: environment),
                support: .supported,
                commandApproval: approval,
                isPackageRunner: Self.packageRunners.contains(URL(fileURLWithPath: executable).lastPathComponent.lowercased())
            )
        }
        guard let rawURL = dictionary["url"] as? String, let url = URL(string: rawURL) else { return nil }
        let type = (dictionary["type"] as? String)?.lowercased()
        let legacy = type == "sse" || url.path.lowercased().hasSuffix("/sse")
        let configurationFingerprint = CommandApproval.fingerprint(
            executablePath: rawURL,
            arguments: [type ?? "streamable-http"],
            configurationFingerprint: baseIdentifier
        )
        let identifier = "\(baseIdentifier):\(configurationFingerprint)"
        return MCPServerConfiguration(
            id: identifier,
            name: name,
            source: input.source,
            configurationURL: input.url,
            transport: legacy ? .legacySSE(url) : .streamableHTTP(url),
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

    private func parseStringArray(_ value: String) -> [String] {
        guard let data = value.data(using: .utf8),
              let values = try? JSONSerialization.jsonObject(with: data) as? [String] else { return [] }
        return values
    }

    private func unquote(_ value: String) -> String {
        guard value.count >= 2, value.first == "\"", value.last == "\"" else { return value }
        if let data = value.data(using: .utf8),
           let decoded = try? JSONSerialization.jsonObject(with: data) as? String { return decoded }
        return String(value.dropFirst().dropLast())
    }
}
