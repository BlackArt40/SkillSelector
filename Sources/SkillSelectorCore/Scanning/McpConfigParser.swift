import Foundation
import Yams

/// A server parsed out of one config file, before it is assigned an Agent
/// or a root. Format-agnostic: both the JSON (mcp.json family) and TOML
/// (Codex) renderers produce these.
public struct ParsedMcpServer: Hashable, Sendable {
    public let name: String
    public let transport: McpTransport
    public let command: String?
    public let arguments: [String]
    public let url: String?

    public init(name: String, transport: McpTransport, command: String?, arguments: [String], url: String?) {
        self.name = name
        self.transport = transport
        self.command = command
        self.arguments = arguments
        self.url = url
    }
}

public enum McpConfigParserError: Error, LocalizedError {
    case unsupportedFormat(String)
    case malformedJSON(String)
    case malformedTOML(Int, String)
    case malformedYAML(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let format):
            return "Unsupported MCP config format: \(format)"
        case .malformedJSON(let detail):
            return "Malformed MCP JSON config: \(detail)"
        case .malformedTOML(let line, let detail):
            return "Malformed MCP TOML config at line \(line): \(detail)"
        case .malformedYAML(let detail):
            return "Malformed MCP YAML config: \(detail)"
        }
    }
}

/// Parses MCP server declarations out of config files. Supports:
///
/// - **JSON family** (`mcpServers` key): both the map shape used by Claude
///   Code / the .mcp.json draft standard (`"mcpServers": { name: {…} }`) and
///   the array shape used by Cursor (`"mcpServers": [{name:…, …}]`). Cursor's
///   `type` values (`stdio`/`http`/`sse`) and the `command`/`args` vs
///   `url`/`headers` split both work.
/// - **TOML** (Codex `config.toml`): only the `[mcp_servers.<name>]`
///   sub-tables — `command`, `args`, `url`, `env` etc. A deliberately tiny
///   TOML subset (strings, arrays of strings, booleans, integers); anything
///   else in the file (profiles, model_providers, …) is ignored.
public enum McpConfigParser {
    static let serverKeysJSON = ["mcpServers", "servers"]

    public static func parse(_ data: Data, format: String) throws -> [ParsedMcpServer] {
        switch format {
        case "json", "jsonc":
            return try parseJSON(data)
        case "toml":
            guard let text = String(data: data, encoding: .utf8) else {
                throw McpConfigParserError.malformedTOML(0, "not valid UTF-8")
            }
            return try parseTOML(text)
        case "yaml":
            guard let text = String(data: data, encoding: .utf8) else {
                throw McpConfigParserError.malformedYAML("not valid UTF-8")
            }
            return try parseYAML(text)
        default:
            throw McpConfigParserError.unsupportedFormat(format)
        }
    }

    // MARK: JSON

    static func parseJSON(_ data: Data) throws -> [ParsedMcpServer] {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw McpConfigParserError.malformedJSON(error.localizedDescription)
        }
        guard let root = object as? [String: Any] else {
            throw McpConfigParserError.malformedJSON("top-level value is not an object")
        }
        for key in serverKeysJSON {
            if let servers = root[key] {
                return extractServers(servers)
            }
        }
        // OpenCode's `mcp` key (opencode.json): local servers carry a
        // command ARRAY, remote ones a url; `enabled: false` hides an
        // entry. Checked after the standard keys so a config that also
        // declares `mcpServers` keeps the standard reading.
        if let mcp = root["mcp"] {
            return opencodeServers(mcp)
        }
        // Cursor also persists a "mcpServers" key only when configured; a
        // config without it nests nothing.
        return []
    }

    private static func opencodeServers(_ value: Any) -> [ParsedMcpServer] {
        guard let map = value as? [String: Any] else { return [] }
        return map.compactMap { name, raw in
            guard let entry = raw as? [String: Any] else { return nil }
            if entry["enabled"] as? Bool == false { return nil }
            let command: String?
            let arguments: [String]
            if let array = entry["command"] as? [String], !array.isEmpty {
                command = array[0]
                arguments = Array(array.dropFirst())
            } else if let string = entry["command"] as? String {
                command = string
                arguments = entry["args"] as? [String] ?? []
            } else {
                command = nil
                arguments = []
            }
            let url = entry["url"] as? String
            return ParsedMcpServer(
                name: name,
                transport: .infer(typeField: entry["type"] as? String, command: command, url: url),
                command: command,
                arguments: arguments,
                url: url
            )
        }.sorted { $0.name < $1.name }
    }

    // MARK: YAML — Goose's `extensions` map

    /// Parses the `extensions` map out of Goose's `~/.config/goose/
    /// config.yaml`: stdio entries carry `cmd` (+ optional `args`), remote
    /// ones a `uri` with `type: sse|streamable_http`; `enabled: false`
    /// hides an entry. Everything else in the file (providers, models, …)
    /// is ignored.
    static func parseYAML(_ text: String) throws -> [ParsedMcpServer] {
        let object: Any
        do {
            object = try Yams.load(yaml: text) ?? [:]
        } catch {
            throw McpConfigParserError.malformedYAML(error.localizedDescription)
        }
        guard let root = object as? [String: Any],
              let extensions = root["extensions"] as? [String: Any] else {
            return []
        }
        return extensions.compactMap { name, raw in
            guard let entry = raw as? [String: Any] else { return nil }
            if entry["enabled"] as? Bool == false { return nil }
            let command = (entry["cmd"] as? String) ?? (entry["command"] as? String)
            let arguments = (entry["args"] as? [Any])?.compactMap { $0 as? String } ?? []
            let url = (entry["uri"] as? String) ?? (entry["url"] as? String)
            return ParsedMcpServer(
                name: name,
                transport: .infer(typeField: entry["type"] as? String, command: command, url: url),
                command: command,
                arguments: arguments,
                url: url
            )
        }.sorted { $0.name < $1.name }
    }

    private static func extractServers(_ value: Any) -> [ParsedMcpServer] {
        if let map = value as? [String: Any] {
            return map.compactMap { name, raw in
                guard let entry = raw as? [String: Any] else { return nil }
                return server(from: entry, named: name)
            }.sorted { $0.name < $1.name }
        }
        if let array = value as? [[String: Any]] {
            return array.compactMap { entry in
                guard let name = entry["name"] as? String else { return nil }
                return server(from: entry, named: name)
            }.sorted { $0.name < $1.name }
        }
        return []
    }

    private static func server(from entry: [String: Any], named name: String) -> ParsedMcpServer? {
        let typeField = entry["type"] as? String
        let command = entry["command"] as? String
        let url = entry["url"] as? String
        let transport = McpTransport.infer(typeField: typeField, command: command, url: url)
        let arguments: [String]
        if let args = entry["args"] as? [String] {
            arguments = args
        } else if let args = entry["arguments"] as? [String] {
            arguments = args
        } else {
            arguments = []
        }
        return ParsedMcpServer(
            name: name,
            transport: transport,
            command: command,
            arguments: arguments,
            url: url
        )
    }

    // MARK: TOML subset

    /// Parses `[mcp_servers.<name>]` tables out of Codex config.toml.
    /// Line-oriented; supports `key = "string"`, `key = 'literal'`,
    /// `key = [ "a", "b" ]`, `key = true|false`, integers, and `#` comments.
    static func parseTOML(_ text: String) throws -> [ParsedMcpServer] {
        var serversByName: [String: [String: TomlValue]] = [:]
        var currentServer: String?
        let lines = text.components(separatedBy: "\n")

        for (offset, rawLine) in lines.enumerated() {
            let line = stripComment(rawLine).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("[") {
                guard line.hasSuffix("]") else {
                    throw McpConfigParserError.malformedTOML(offset + 1, "unterminated table header")
                }
                let table = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                let components = table.split(separator: ".").map(String.init)
                // Only `[mcp_servers.<name>]` (exactly two dotted segments)
                // opens a server. Sub-tables like `[mcp_servers.foo.env]`
                // belong to that server's `env` block (Codex declares
                // environment variables that way); they must not be parsed
                // as separate servers.
                if components.count == 2, components[0] == "mcp_servers" {
                    currentServer = components[1]
                } else {
                    currentServer = nil
                }
                continue
            }

            guard let equals = line.firstIndex(of: "="),
                  line[..<equals].trimmingCharacters(in: .whitespaces).contains(".") == false,
                  let server = currentServer else {
                continue
            }
            let rawName = line[..<equals].trimmingCharacters(in: .whitespaces)
            let valueText = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            guard let value = try parseTomlValue(valueText, line: offset + 1) else { continue }
            serversByName[server, default: [:]][rawName] = value
        }

        return serversByName.map { name, fields -> ParsedMcpServer in
            let command = fields["command"]?.stringValue
            let url = fields["url"]?.stringValue
            let transport = McpTransport.infer(typeField: nil, command: command, url: url)
            let arguments = fields["args"]?.arrayValue ?? fields["arguments"]?.arrayValue ?? []
            return ParsedMcpServer(
                name: name,
                transport: transport,
                command: command,
                arguments: arguments,
                url: url
            )
        }.sorted { $0.name < $1.name }
    }

    private static func stripComment(_ line: String) -> String {
        var inString = false
        var quote: Character = "\0"
        for (index, ch) in line.enumerated() {
            if ch == "\"" || ch == "'" {
                if !inString {
                    inString = true
                    quote = ch
                } else if ch == quote {
                    inString = false
                }
            } else if ch == "#", !inString {
                return String(line.prefix(index))
            }
        }
        return line
    }

    private enum TomlValue {
        case string(String)
        case bool(Bool)
        case int(Int)
        case array([String])

        var stringValue: String? {
            if case .string(let value) = self { return value }
            return nil
        }

        var arrayValue: [String]? {
            if case .array(let values) = self { return values }
            return nil
        }
    }

    private static func parseTomlValue(_ text: String, line: Int) throws -> TomlValue? {
        if text.hasPrefix("[") {
            guard text.hasSuffix("]") else {
                throw McpConfigParserError.malformedTOML(line, "unterminated array")
            }
            let inner = String(text.dropFirst().dropLast())
            // Split array elements honoring quoted strings.
            var elements: [String] = []
            var current = ""
            var inString = false
            var quote: Character = "\0"
            for ch in inner {
                if ch == "\"" || ch == "'" {
                    if !inString {
                        inString = true
                        quote = ch
                        current.append(ch)
                    } else if ch == quote {
                        inString = false
                        current.append(ch)
                    } else {
                        current.append(ch)
                    }
                } else if ch == "," && !inString {
                    elements.append(current)
                    current = ""
                } else {
                    current.append(ch)
                }
            }
            elements.append(current)
            let values = elements.map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .map(unquote)
            return .array(values)
        }
        if let first = text.first, (first == "\"" || first == "'") {
            return .string(unquote(text))
        }
        switch text.lowercased() {
        case "true": return .bool(true)
        case "false": return .bool(false)
        default: break
        }
        if let int = Int(text) { return .int(int) }
        return nil
    }

    private static func unquote(_ value: String) -> String {
        var trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.count >= 2,
           (trimmed.first == "\"" && trimmed.last == "\"")
            || (trimmed.first == "'" && trimmed.last == "'") {
            trimmed.removeFirst()
            trimmed.removeLast()
        }
        return trimmed
    }
}