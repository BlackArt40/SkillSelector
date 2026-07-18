import Foundation
import Observation
import SkillSelectorCore
import SwiftUI

@MainActor
@Observable
private final class MCPSettingsModel {
    private let approval: CommandApproval
    private let preferences: MCPPreferenceStore
    private(set) var servers: [MCPServerConfiguration] = []
    private(set) var toolsByServer: [String: [MCPTool]] = [:]
    private(set) var loadingServerIDs: Set<String> = []
    private(set) var failedServerIDs: Set<String> = []

    init(
        preferences: MCPPreferenceStore = MCPPreferenceStore(),
        approval: CommandApproval = CommandApproval()
    ) {
        self.preferences = preferences
        self.approval = approval
    }

    func discover(using appModel: AppModel) {
        do {
            servers = try appModel.discoverMCPConfigurations()
            failedServerIDs.removeAll()
        } catch {
            servers = []
        }
    }

    func serverEnabled(_ server: MCPServerConfiguration) -> Bool {
        preferences.isServerEnabled(server.id)
    }

    func setServer(_ server: MCPServerConfiguration, enabled: Bool) {
        preferences.setServer(server.id, enabled: enabled)
        if !enabled {
            toolsByServer.removeValue(forKey: server.id)
            failedServerIDs.remove(server.id)
        }
    }

    func toolEnabled(_ tool: MCPTool, server: MCPServerConfiguration) -> Bool {
        preferences.enabledTools(for: server.id).contains(tool.name)
    }

    func setTool(_ tool: MCPTool, server: MCPServerConfiguration, enabled: Bool) {
        preferences.setTool(tool.name, serverID: server.id, enabled: enabled)
        if var tools = toolsByServer[server.id],
           let index = tools.firstIndex(where: { $0.name == tool.name }) {
            tools[index] = MCPTool(
                name: tool.name,
                description: tool.description,
                inputSchema: tool.inputSchema,
                annotations: tool.annotations,
                isEnabled: enabled
            )
            toolsByServer[server.id] = tools
        }
    }

    func approvalRequired(_ server: MCPServerConfiguration) -> Bool {
        guard let command = server.commandApproval else { return false }
        return approval.state(for: command) == .approvalRequired
    }

    func approve(_ server: MCPServerConfiguration) {
        guard let command = server.commandApproval else { return }
        approval.approve(command)
    }

    func loadTools(for server: MCPServerConfiguration, using appModel: AppModel) async {
        guard serverEnabled(server), server.support == .supported else { return }
        let configured = server.withState(
            isEnabled: true,
            enabledToolNames: preferences.enabledTools(for: server.id)
        )
        loadingServerIDs.insert(server.id)
        failedServerIDs.remove(server.id)
        do {
            toolsByServer[server.id] = try await appModel.loadMCPTools(configuration: configured)
        } catch {
            failedServerIDs.insert(server.id)
        }
        loadingServerIDs.remove(server.id)
    }
}

struct MCPSettingsView: View {
    @Environment(AppModel.self) private var appModel
    @State private var model = MCPSettingsModel()
    @State private var approvalCandidate: MCPServerConfiguration?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(L10n.string("MCP Servers"), systemImage: "point.3.connected.trianglepath.dotted")
                .font(.headline)
            if model.servers.isEmpty {
                Text(verbatim: L10n.string("No MCP server configurations found."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.servers) { server in
                            serverRow(server)
                            if server.id != model.servers.last?.id { Divider() }
                        }
                    }
                }
                .frame(maxHeight: 300)
            }
        }
        .task { model.discover(using: appModel) }
        .alert(
            L10n.string("Approve Exact MCP Command"),
            isPresented: Binding(
                get: { approvalCandidate != nil },
                set: { if !$0 { approvalCandidate = nil } }
            ),
            presenting: approvalCandidate
        ) { server in
            Button(L10n.string("Approve")) {
                model.approve(server)
                approvalCandidate = nil
            }
            Button(L10n.string("Cancel"), role: .cancel) { approvalCandidate = nil }
        } message: { server in
            Text(verbatim: commandDisplay(server))
        }
    }

    @ViewBuilder
    private func serverRow(_ server: MCPServerConfiguration) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Toggle(isOn: Binding(
                get: { model.serverEnabled(server) },
                set: { model.setServer(server, enabled: $0) }
            )) {
                HStack(spacing: 8) {
                    Image(systemName: transportIcon(server.transport))
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    Text(verbatim: server.name)
                        .fontWeight(.medium)
                    Text(verbatim: server.source.rawValue.capitalized)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text(verbatim: transportDisplay(server.transport))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(2)
            if server.support == .unsupportedLegacySSE {
                Label(L10n.string("Legacy SSE is not supported."), systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if model.serverEnabled(server) {
                HStack(spacing: 8) {
                    if server.commandApproval != nil, model.approvalRequired(server) {
                        Button(L10n.string("Approve Exact Command")) {
                            approvalCandidate = server
                        }
                    }
                    Button {
                        Task { await model.loadTools(for: server, using: appModel) }
                    } label: {
                        Label(L10n.string("Load Tools"), systemImage: "arrow.clockwise")
                    }
                    .disabled(
                        model.loadingServerIDs.contains(server.id)
                            || (server.commandApproval != nil && model.approvalRequired(server))
                    )
                    if model.loadingServerIDs.contains(server.id) { ProgressView().controlSize(.small) }
                }
                if model.failedServerIDs.contains(server.id) {
                    Text(verbatim: L10n.string("Unable to load MCP tools."))
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                ForEach(model.toolsByServer[server.id] ?? []) { tool in
                    toolRow(tool, server: server)
                }
            }
        }
        .padding(.vertical, 10)
    }

    private func toolRow(_ tool: MCPTool, server: MCPServerConfiguration) -> some View {
        Toggle(isOn: Binding(
            get: { model.toolEnabled(tool, server: server) },
            set: { model.setTool(tool, server: server, enabled: $0) }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: tool.name)
                    .font(.system(.caption, design: .monospaced).weight(.medium))
                Text(verbatim: !tool.requiresPerCallConfirmation
                    ? L10n.string("Server read-only hint")
                    : L10n.string("Confirmation required for every call"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 24)
    }

    private func transportIcon(_ transport: MCPTransport) -> String {
        switch transport {
        case .stdio: "terminal"
        case .streamableHTTP: "network"
        case .legacySSE: "bolt.horizontal.circle"
        }
    }

    private func transportDisplay(_ transport: MCPTransport) -> String {
        switch transport {
        case .stdio(let executable, let arguments, _, _):
            ([executable] + arguments).map(displayArgument).joined(separator: " ")
        case .streamableHTTP(let url, _), .legacySSE(let url):
            url.absoluteString
        }
    }

    private func commandDisplay(_ server: MCPServerConfiguration) -> String {
        transportDisplay(server.transport)
    }

    private func displayArgument(_ argument: String) -> String {
        guard argument.contains(where: { $0.isWhitespace || $0 == "\"" }) else { return argument }
        return "\"\(argument.replacingOccurrences(of: "\"", with: "\\\""))\""
    }
}
