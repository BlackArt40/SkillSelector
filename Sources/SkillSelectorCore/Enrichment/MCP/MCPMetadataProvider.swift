import Foundation

public struct MCPMetadataProvider: MetadataProvider {
    private let rootURL: URL
    private let authorizedHomeURL: URL?
    private let preferences: any MCPPreferenceStoring
    private let approval: CommandApproval
    private let discovery: MCPConfigDiscovery

    public init(
        rootURL: URL,
        authorizedHomeURL: URL? = nil,
        preferences: any MCPPreferenceStoring = MCPPreferenceStore(),
        approval: CommandApproval = CommandApproval(),
        discovery: MCPConfigDiscovery = MCPConfigDiscovery()
    ) {
        self.rootURL = rootURL.standardizedFileURL
        self.authorizedHomeURL = authorizedHomeURL?.standardizedFileURL
        self.preferences = preferences
        self.approval = approval
        self.discovery = discovery
    }

    public func hasEnabledConfiguration() -> Bool {
        guard let servers = try? discovery.discover(in: rootURL) else { return false }
        return servers.contains { server in
            server.support == .supported
                && preferences.isServerEnabled(server.id)
                && !preferences.enabledTools(for: server.id).isEmpty
        }
    }

    public func candidates(for query: MetadataQuery) async throws -> [MetadataCandidate] {
        let name = try MetadataProviderSupport.validatedQueryName(query.name)
        let servers: [MCPServerConfiguration]
        do { servers = try discovery.discover(in: rootURL) }
        catch { throw MetadataProviderError.invalidResponse(provider: .mcp) }

        var candidates: [MetadataCandidate] = []
        var firstFailure: Error?
        for server in servers where server.support == .supported && preferences.isServerEnabled(server.id) {
            let enabledTools = preferences.enabledTools(for: server.id)
            guard !enabledTools.isEmpty else { continue }
            let configured = server.withState(isEnabled: true, enabledToolNames: enabledTools)
            for tool in enabledTools.sorted() {
                let client = makeClient(configuration: configured)
                do {
                    let result = try await client.call(
                        tool: tool,
                        arguments: ["name": .string(name)]
                    )
                    candidates.append(try MCPMetadataCandidateMapper.map(result))
                } catch MCPClientError.toolConfirmationRequired {
                    // Unknown and non-read-only tools are never invoked by enrichment.
                } catch {
                    firstFailure = firstFailure ?? error
                }
                await client.close()
            }
        }
        let unique = Array(Set(candidates)).sorted {
            if $0.sourceIdentifier != $1.sourceIdentifier {
                return $0.sourceIdentifier.localizedStandardCompare($1.sourceIdentifier) == .orderedAscending
            }
            return $0.evidenceURL.absoluteString < $1.evidenceURL.absoluteString
        }
        if unique.isEmpty, firstFailure != nil {
            throw MetadataProviderError.invalidResponse(provider: .mcp)
        }
        return unique
    }

    private func makeClient(configuration: MCPServerConfiguration) -> any MCPClient {
        switch configuration.transport {
        case .stdio:
            StdioMCPClient(
                configuration: configuration,
                approval: approval,
                authorizedHomeURL: authorizedHomeURL
            )
        case .streamableHTTP:
            HTTPMCPClient(configuration: configuration)
        case .legacySSE:
            DisabledMCPClient()
        }
    }
}

private struct DisabledMCPClient: MCPClient {
    func listTools() async throws -> [MCPTool] { throw MCPClientError.unsupportedTransport }
    func call(tool: String, arguments: [String: MCPJSONValue]) async throws -> MCPToolResult {
        throw MCPClientError.unsupportedTransport
    }
}
