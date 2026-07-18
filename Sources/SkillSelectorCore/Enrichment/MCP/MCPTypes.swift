import Foundation

public enum MCPConfigSource: String, Codable, CaseIterable, Hashable, Sendable {
    case claude
    case codex
    case generic
}

public enum MCPServerSupport: String, Codable, Hashable, Sendable {
    case supported
    case unsupportedLegacySSE
    case invalidConfiguration
}

public enum MCPTransport: Hashable, Sendable {
    case stdio(
        executable: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: String?
    )
    case streamableHTTP(endpoint: URL, headers: [String: String])
    case legacySSE(URL)
}

public struct MCPServerConfiguration: Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let source: MCPConfigSource
    public let configurationURL: URL
    public let transport: MCPTransport
    public let support: MCPServerSupport
    public let isEnabled: Bool
    public let enabledToolNames: Set<String>
    public let commandApproval: ApprovedCommand?
    public let isPackageRunner: Bool

    public init(
        id: String,
        name: String,
        source: MCPConfigSource,
        configurationURL: URL,
        transport: MCPTransport,
        support: MCPServerSupport,
        isEnabled: Bool = false,
        enabledToolNames: Set<String> = [],
        commandApproval: ApprovedCommand? = nil,
        isPackageRunner: Bool = false
    ) {
        self.id = id
        self.name = name
        self.source = source
        self.configurationURL = configurationURL
        self.transport = transport
        self.support = support
        self.isEnabled = isEnabled
        self.enabledToolNames = enabledToolNames
        self.commandApproval = commandApproval
        self.isPackageRunner = isPackageRunner
    }

    public func withState(isEnabled: Bool, enabledToolNames: Set<String>) -> MCPServerConfiguration {
        MCPServerConfiguration(
            id: id,
            name: name,
            source: source,
            configurationURL: configurationURL,
            transport: transport,
            support: support,
            isEnabled: isEnabled,
            enabledToolNames: enabledToolNames,
            commandApproval: commandApproval,
            isPackageRunner: isPackageRunner
        )
    }
}

public enum MCPJSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([MCPJSONValue])
    case object([String: MCPJSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([MCPJSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: MCPJSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public var objectValue: [String: MCPJSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    public var arrayValue: [MCPJSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    public var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    public var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }
}

public struct MCPToolAnnotations: Codable, Hashable, Sendable {
    public let readOnlyHint: Bool?
    public let destructiveHint: Bool?
    public let idempotentHint: Bool?
    public let openWorldHint: Bool?

    public init(
        readOnlyHint: Bool? = nil,
        destructiveHint: Bool? = nil,
        idempotentHint: Bool? = nil,
        openWorldHint: Bool? = nil
    ) {
        self.readOnlyHint = readOnlyHint
        self.destructiveHint = destructiveHint
        self.idempotentHint = idempotentHint
        self.openWorldHint = openWorldHint
    }
}

public struct MCPTool: Codable, Hashable, Sendable, Identifiable {
    public var id: String { name }
    public let name: String
    public let description: String?
    public let inputSchema: MCPJSONValue
    public let annotations: MCPToolAnnotations?
    public let isEnabled: Bool

    public init(
        name: String,
        description: String?,
        inputSchema: MCPJSONValue,
        annotations: MCPToolAnnotations?,
        isEnabled: Bool = false
    ) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.annotations = annotations
        self.isEnabled = isEnabled
    }

    public var requiresPerCallConfirmation: Bool {
        annotations?.readOnlyHint != true || annotations?.destructiveHint != false
    }

    private enum CodingKeys: String, CodingKey {
        case name, description, inputSchema, annotations, isEnabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        inputSchema = try container.decode(MCPJSONValue.self, forKey: .inputSchema)
        annotations = try container.decodeIfPresent(MCPToolAnnotations.self, forKey: .annotations)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
    }
}

public struct MCPToolContent: Codable, Hashable, Sendable {
    public let type: String
    public let text: String?

    public init(type: String, text: String? = nil) {
        self.type = type
        self.text = text
    }
}

public struct MCPToolResult: Codable, Hashable, Sendable {
    public let content: [MCPToolContent]
    public let structuredContent: MCPJSONValue?
    public let isError: Bool

    public init(content: [MCPToolContent], structuredContent: MCPJSONValue?, isError: Bool) {
        self.content = content
        self.structuredContent = structuredContent
        self.isError = isError
    }

    private enum CodingKeys: String, CodingKey { case content, structuredContent, isError }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        content = try container.decodeIfPresent([MCPToolContent].self, forKey: .content) ?? []
        structuredContent = try container.decodeIfPresent(MCPJSONValue.self, forKey: .structuredContent)
        isError = try container.decodeIfPresent(Bool.self, forKey: .isError) ?? false
    }
}

public enum MCPClientError: Error, Equatable, Sendable {
    case disabled
    case unsupportedTransport
    case approvalRequired
    case invalidExecutable(String)
    case invalidEndpoint
    case launchFailed(String)
    case timedOut
    case cancelled
    case responseTooLarge
    case invalidResponse
    case serverError(code: Int, message: String)
    case toolNotEnabled(String)
    case toolConfirmationRequired(String)
    case toolReportedError
}

public protocol MCPClient: Sendable {
    func listTools() async throws -> [MCPTool]
    func call(tool: String, arguments: [String: MCPJSONValue]) async throws -> MCPToolResult
    func close() async
}

public extension MCPClient {
    func close() async {}
}

public typealias MCPToolConfirmation = @Sendable (String, MCPTool) async -> Bool

struct MCPRPCResponse: Decodable {
    struct RPCError: Decodable { let code: Int; let message: String }
    let jsonrpc: String
    let id: Int?
    let result: MCPJSONValue?
    let error: RPCError?
}

enum MCPProtocolCodec {
    static func request(method: String, id: Int?, params: MCPJSONValue = .object([:])) throws -> Data {
        var object: [String: MCPJSONValue] = [
            "jsonrpc": .string("2.0"),
            "method": .string(method),
            "params": params,
        ]
        if let id { object["id"] = .number(Double(id)) }
        return try JSONEncoder().encode(MCPJSONValue.object(object))
    }

    static func response(_ data: Data, expectedID: Int) throws -> MCPJSONValue {
        let response: MCPRPCResponse
        do { response = try JSONDecoder().decode(MCPRPCResponse.self, from: data) }
        catch { throw MCPClientError.invalidResponse }
        guard response.jsonrpc == "2.0", response.id == expectedID else {
            throw MCPClientError.invalidResponse
        }
        if let error = response.error {
            throw MCPClientError.serverError(code: error.code, message: error.message)
        }
        guard let result = response.result else { throw MCPClientError.invalidResponse }
        return result
    }

    static func tools(from result: MCPJSONValue, enabled: Set<String>) throws -> [MCPTool] {
        guard let values = result.objectValue?["tools"]?.arrayValue else {
            throw MCPClientError.invalidResponse
        }
        return try values.map { value in
            let data = try JSONEncoder().encode(value)
            let decoded = try JSONDecoder().decode(MCPTool.self, from: data)
            return MCPTool(
                name: decoded.name,
                description: decoded.description,
                inputSchema: decoded.inputSchema,
                annotations: decoded.annotations,
                isEnabled: enabled.contains(decoded.name)
            )
        }
    }

    static func toolResult(from result: MCPJSONValue) throws -> MCPToolResult {
        do {
            return try JSONDecoder().decode(MCPToolResult.self, from: JSONEncoder().encode(result))
        } catch {
            throw MCPClientError.invalidResponse
        }
    }
}

public enum MCPMetadataMappingError: Error, Equatable, Sendable {
    case invalidStructuredResult
}

public enum MCPMetadataCandidateMapper {
    public static func map(_ result: MCPToolResult) throws -> MetadataCandidate {
        guard !result.isError,
              let object = result.structuredContent?.objectValue,
              let description = validatedText(object["description"]?.stringValue, maximumBytes: 10_000),
              let sourceIdentifier = validatedText(object["sourceIdentifier"]?.stringValue, maximumBytes: 1_000),
              let rawEvidenceURL = validatedText(object["evidenceURL"]?.stringValue, maximumBytes: 4_096),
              let evidenceURL = URL(string: rawEvidenceURL),
              let scheme = evidenceURL.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              evidenceURL.host != nil else {
            throw MCPMetadataMappingError.invalidStructuredResult
        }
        let skillSubdirectory: String?
        if let rawSubdirectory = object["skillSubdirectory"] {
            guard let value = rawSubdirectory.stringValue,
                  validRelativePath(value) else {
                throw MCPMetadataMappingError.invalidStructuredResult
            }
            skillSubdirectory = value
        } else {
            skillSubdirectory = nil
        }
        return MetadataCandidate(
            provider: .mcp,
            sourceIdentifier: sourceIdentifier,
            skillSubdirectory: skillSubdirectory,
            description: description,
            evidenceURL: evidenceURL,
            sourceBinding: nil
        )
    }

    private static func validatedText(_ value: String?, maximumBytes: Int) -> String? {
        guard let value,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.utf8.count <= maximumBytes,
              value.unicodeScalars.allSatisfy({ scalar in
                  !CharacterSet.controlCharacters.contains(scalar)
                      || scalar == "\n" || scalar == "\r" || scalar == "\t"
              }) else { return nil }
        return value
    }

    private static func validRelativePath(_ value: String) -> Bool {
        guard let value = validatedText(value, maximumBytes: 1_000),
              !value.hasPrefix("/"),
              !value.hasSuffix("/"),
              !value.contains("\\") else { return false }
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        return !components.isEmpty && components.allSatisfy { component in
            !component.isEmpty && component != "." && component != ".."
        }
    }
}

public enum MCPConfigDiscoveryError: Error, Equatable, Sendable {
    case unreadableConfiguration(URL)
    case invalidConfiguration(URL)
}

public protocol MCPPreferenceStoring: AnyObject, Sendable {
    func isServerEnabled(_ id: String) -> Bool
    func setServer(_ id: String, enabled: Bool)
    func enabledTools(for serverID: String) -> Set<String>
    func setTool(_ name: String, serverID: String, enabled: Bool)
}

/// The production preference adapter. Tests and previews should inject an
/// in-memory `MCPPreferenceStoring` implementation instead of creating a
/// persistent UserDefaults suite.
public final class MCPPreferenceStore: MCPPreferenceStoring, @unchecked Sendable {
    private static let enabledServersKey = "SkillSelector.mcp.enabledServers"
    private static let enabledToolsKey = "SkillSelector.mcp.enabledTools"

    private let defaults: UserDefaults
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func isServerEnabled(_ id: String) -> Bool {
        lock.withLock { enabledServerIDs().contains(id) }
    }

    public func setServer(_ id: String, enabled: Bool) {
        lock.withLock {
            var values = enabledServerIDs()
            if enabled { values.insert(id) } else { values.remove(id) }
            defaults.set(Array(values).sorted(), forKey: Self.enabledServersKey)
        }
    }

    public func enabledTools(for serverID: String) -> Set<String> {
        lock.withLock { enabledToolsDictionary()[serverID, default: []] }
    }

    public func setTool(_ name: String, serverID: String, enabled: Bool) {
        lock.withLock {
            var values = enabledToolsDictionary()
            if enabled { values[serverID, default: []].insert(name) }
            else { values[serverID, default: []].remove(name) }
            if let data = try? JSONEncoder().encode(values) {
                defaults.set(data, forKey: Self.enabledToolsKey)
            }
        }
    }

    private func enabledServerIDs() -> Set<String> {
        Set(defaults.stringArray(forKey: Self.enabledServersKey) ?? [])
    }

    private func enabledToolsDictionary() -> [String: Set<String>] {
        guard let data = defaults.data(forKey: Self.enabledToolsKey),
              let values = try? JSONDecoder().decode([String: Set<String>].self, from: data) else {
            return [:]
        }
        return values
    }
}
