import Foundation

/// The transport an MCP server speaks, as declared in an Agent's config.
public enum McpTransport: String, Codable, Hashable, Sendable {
    case stdio
    case http
    case sse

    /// Transport inferred from a config entry's fields, standard-compatible:
    /// `command` implies stdio, a `type` field is honored first, and
    /// `url`/`httpHeaders` imply streamable HTTP. `sse`/`streamable-http`
    /// spellings normalize to a single value.
    public static func infer(typeField: String?, command: String?, url: String?) -> McpTransport {
        if let typeField {
            switch typeField.lowercased() {
            case "stdio": return .stdio
            case "sse": return .sse
            case "streamable-http", "streamable_http", "http": return .http
            default: break
            }
        }
        if command != nil { return .stdio }
        return url != nil ? .http : .stdio
    }
}

/// An MCP server declared in an Agent's config file. Configuration only —
/// never probes anything; the poll/status side lives in `McpProbing`.
public struct McpServerDescriptor: Identifiable, Hashable, Sendable {
    /// Stable identity: agent + server name + declaring config path.
    public let id: String
    public let name: String
    public let agentID: String?
    public let transport: McpTransport
    /// stdio servers: the executable and its arguments.
    public let command: String?
    public let arguments: [String]
    /// http/sse servers: the endpoint URL.
    public let url: String?
    /// The config file this server was declared in (absolute), for reveal.
    public let configFile: String
    /// Root the config belongs to (a project's `.mcp.json`) or nil for
    /// global (user-level) config under the home root.
    public let projectRootID: String?

    public init(
        name: String,
        agentID: String?,
        transport: McpTransport,
        command: String?,
        arguments: [String],
        url: String?,
        configFile: String,
        projectRootID: String?
    ) {
        self.name = name
        self.agentID = agentID
        self.transport = transport
        self.command = command
        self.arguments = arguments
        self.url = url
        self.configFile = configFile
        self.projectRootID = projectRootID
        let agentTag = agentID ?? "shared"
        self.id = "\(agentTag)/\(name)/\(configFile)"
    }

    /// A short, display-friendly launch line: command plus args, or URL.
    public var launchSummary: String {
        switch transport {
        case .stdio:
            var line = command ?? ""
            if !arguments.isEmpty {
                line += " " + arguments.prefix(6).joined(separator: " ")
                if arguments.count > 6 { line += " …" }
            }
            return line
        case .http, .sse:
            return url ?? ""
        }
    }
}