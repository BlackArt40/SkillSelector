import Foundation

private struct MCPHTTPPayload: Sendable {
    let statusCode: Int
    let headers: [String: String]
    let contentType: String?
    let data: Data

    func header(_ name: String) -> String? {
        for (key, value) in headers where key.caseInsensitiveCompare(name) == .orderedSame {
            return value
        }
        return nil
    }
}

public actor HTTPMCPClient: MCPClient {
    private let configuration: MCPServerConfiguration
    private let session: URLSession
    private let ownsSession: Bool
    private let timeout: TimeInterval
    private let maximumResponseBytes: Int
    private let confirmation: MCPToolConfirmation
    private var nextRequestID = 1

    public init(
        configuration: MCPServerConfiguration,
        timeout: TimeInterval = 30,
        maximumResponseBytes: Int = 1_048_576,
        confirmation: @escaping MCPToolConfirmation = { _, _ in false }
    ) {
        self.configuration = configuration
        self.timeout = timeout
        self.maximumResponseBytes = maximumResponseBytes
        self.confirmation = confirmation
        session = URLSession(configuration: .ephemeral)
        ownsSession = true
    }

    public init(
        configuration: MCPServerConfiguration,
        session: URLSession,
        timeout: TimeInterval = 30,
        maximumResponseBytes: Int = 1_048_576,
        confirmation: @escaping MCPToolConfirmation = { _, _ in false }
    ) {
        self.configuration = configuration
        self.session = session
        self.timeout = timeout
        self.maximumResponseBytes = maximumResponseBytes
        self.confirmation = confirmation
        ownsSession = false
    }

    public func listTools() async throws -> [MCPTool] {
        let result = try await exchange(method: "tools/list")
        return try MCPProtocolCodec.tools(from: result, enabled: configuration.enabledToolNames)
    }

    public func call(tool: String, arguments: [String: MCPJSONValue]) async throws -> MCPToolResult {
        let tools = try await listTools()
        guard let definition = tools.first(where: { $0.name == tool }), definition.isEnabled else {
            throw MCPClientError.toolNotEnabled(tool)
        }
        if definition.requiresPerCallConfirmation,
           await !confirmation(configuration.id, definition) {
            throw MCPClientError.toolConfirmationRequired(tool)
        }
        let result = try await exchange(
            method: "tools/call",
            params: .object(["name": .string(tool), "arguments": .object(arguments)])
        )
        let decoded = try MCPProtocolCodec.toolResult(from: result)
        if decoded.isError { throw MCPClientError.toolReportedError }
        return decoded
    }

    public func close() async {
        if ownsSession { session.invalidateAndCancel() }
    }

    private func exchange(method: String, params: MCPJSONValue = .object([:])) async throws -> MCPJSONValue {
        let endpoint = try validatedEndpoint()
        guard timeout > 0, maximumResponseBytes > 0 else { throw MCPClientError.invalidResponse }
        var sessionID: String?
        do {
            let initializeID = takeRequestID()
            let initialized = try await send(
                endpoint: endpoint,
                body: MCPProtocolCodec.request(
                    method: "initialize",
                    id: initializeID,
                    params: .object([
                        "protocolVersion": .string("2025-03-26"),
                        "capabilities": .object([:]),
                        "clientInfo": .object([
                            "name": .string("SkillSelector"),
                            "version": .string("1"),
                        ]),
                    ])
                ),
                sessionID: nil,
                allowEmpty: false
            )
            sessionID = validatedSessionID(initialized.header("Mcp-Session-Id"))
            let initializedValue = try MCPProtocolCodec.response(initialized.data, expectedID: initializeID)
            guard initializedValue.objectValue?["protocolVersion"]?.stringValue != nil else {
                throw MCPClientError.invalidResponse
            }
            _ = try await send(
                endpoint: endpoint,
                body: MCPProtocolCodec.request(method: "notifications/initialized", id: nil),
                sessionID: sessionID,
                allowEmpty: true
            )
            let targetID = takeRequestID()
            let target = try await send(
                endpoint: endpoint,
                body: MCPProtocolCodec.request(method: method, id: targetID, params: params),
                sessionID: sessionID,
                allowEmpty: false
            )
            let result = try MCPProtocolCodec.response(target.data, expectedID: targetID)
            await deleteSession(endpoint: endpoint, sessionID: sessionID)
            return result
        } catch {
            await deleteSession(endpoint: endpoint, sessionID: sessionID)
            throw mapTransportError(error)
        }
    }

    private func takeRequestID() -> Int {
        defer { nextRequestID += 1 }
        return nextRequestID
    }

    private func validatedEndpoint() throws -> URL {
        guard configuration.isEnabled else { throw MCPClientError.disabled }
        guard configuration.support == .supported,
              case .streamableHTTP(let endpoint) = configuration.transport else {
            throw MCPClientError.unsupportedTransport
        }
        guard let scheme = endpoint.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              endpoint.host != nil else {
            throw MCPClientError.invalidEndpoint
        }
        return endpoint
    }

    private func validatedSessionID(_ value: String?) -> String? {
        guard let value,
              value.utf8.count <= 1_024,
              !value.isEmpty,
              !value.contains("\r"),
              !value.contains("\n") else { return nil }
        return value
    }

    private func send(
        endpoint: URL,
        body: Data,
        sessionID: String?,
        allowEmpty: Bool
    ) async throws -> MCPHTTPPayload {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        let payload = try await load(request)
        guard (200..<300).contains(payload.statusCode) else {
            throw MCPClientError.serverError(
                code: payload.statusCode,
                message: HTTPURLResponse.localizedString(forStatusCode: payload.statusCode)
            )
        }
        if payload.contentType?.lowercased().contains("text/event-stream") == true {
            throw MCPClientError.unsupportedTransport
        }
        guard allowEmpty || !payload.data.isEmpty else { throw MCPClientError.invalidResponse }
        return payload
    }

    private func load(_ request: URLRequest) async throws -> MCPHTTPPayload {
        let session = session
        let limit = maximumResponseBytes
        let deadline = timeout
        do {
            return try await withThrowingTaskGroup(of: MCPHTTPPayload.self) { group in
                group.addTask {
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let response = response as? HTTPURLResponse else {
                        throw MCPClientError.invalidResponse
                    }
                    var data = Data()
                    data.reserveCapacity(min(limit, 64 * 1_024))
                    for try await byte in bytes {
                        if data.count == limit { throw MCPClientError.responseTooLarge }
                        data.append(byte)
                    }
                    return MCPHTTPPayload(
                        statusCode: response.statusCode,
                        headers: response.allHeaderFields.reduce(into: [:]) { values, element in
                            values[String(describing: element.key)] = String(describing: element.value)
                        },
                        contentType: response.value(forHTTPHeaderField: "Content-Type"),
                        data: data
                    )
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(deadline))
                    throw MCPClientError.timedOut
                }
                guard let first = try await group.next() else { throw MCPClientError.invalidResponse }
                group.cancelAll()
                return first
            }
        } catch {
            throw mapTransportError(error)
        }
    }

    private func deleteSession(endpoint: URL, sessionID: String?) async {
        guard let sessionID else { return }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "DELETE"
        request.timeoutInterval = min(timeout, 5)
        request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        let session = session
        _ = try? await Task.detached { try await session.data(for: request) }.value
    }

    private func mapTransportError(_ error: Error) -> Error {
        if let error = error as? MCPClientError { return error }
        if error is CancellationError { return MCPClientError.cancelled }
        if let error = error as? URLError {
            if error.code == .timedOut { return MCPClientError.timedOut }
            if error.code == .cancelled { return MCPClientError.cancelled }
        }
        return MCPClientError.invalidResponse
    }
}
