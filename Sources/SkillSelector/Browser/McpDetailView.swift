import SkillSelectorCore
import SwiftUI

/// The right `.detail` column for one MCP server, laid out exactly like
/// `SkillDetailView`: hero (tile + name + config path + badges), an action
/// bar, a status section, and a key/value configuration grid.
struct McpDetailView: View {
    let server: McpServerDescriptor?
    let status: McpProbeStatus
    var agentNamesByID: [String: String] = [:]
    var onProbe: (() -> Void)?
    var onRevealConfig: ((McpServerDescriptor) -> Void)?

    private var isProbing: Bool {
        status == .probing
    }

    var body: some View {
        if let server {
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    hero(server)
                    actionBar(server)
                    statusSection
                    configurationSection(server)
                }
                .padding(.horizontal, 32)
                .padding(.top, 32)
                .padding(.bottom, 48)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(AppTheme.background)
            .navigationTitle(server.name)
        } else {
            emptyState
                .background(AppTheme.background)
        }
    }

    // MARK: Hero

    private func hero(_ server: McpServerDescriptor) -> some View {
        HStack(alignment: .top, spacing: 20) {
            SkillTileView(
                title: skillTileLetter(for: server.name),
                size: 72,
                cornerRadius: 18,
                active: false
            )
            .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: server.name)
                    .font(AppTheme.display(28, weight: .semibold))
                    .foregroundStyle(AppTheme.foreground)
                    .lineLimit(1)
                    .textSelection(.enabled)
                Text(verbatim: server.configFile)
                    .font(AppTheme.mono(12))
                    .foregroundStyle(AppTheme.muted)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .padding(.top, 3)
                HStack(spacing: 8) {
                    PillBadge(text: transportLabel(server.transport), style: .link)
                    if let agentName = agentNamesByID[server.agentID ?? ""] {
                        PillBadge(text: agentName, style: .link)
                    } else {
                        PillBadge(text: L10n.string("Shared MCP Server"), style: .link)
                    }
                }
                .padding(.top, 12)
            }
        }
    }

    // MARK: Action bar

    private func actionBar(_ server: McpServerDescriptor) -> some View {
        HStack(spacing: 8) {
            actionButton(
                icon: Image(systemName: "folder"),
                title: L10n.string("Reveal in Finder"),
                role: .secondary
            ) {
                onRevealConfig?(server)
            }
            Button {
                onProbe?()
            } label: {
                HStack(spacing: 6) {
                    if isProbing {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(verbatim: isProbing ? L10n.string("Probing…") : L10n.string("Probe MCP"))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(ActionButtonStyle(role: isProbing ? .secondary : .primary))
            .disabled(isProbing)
            .help(L10n.string("Probe MCP"))
            .accessibilityLabel(L10n.string("Probe MCP"))
            Spacer(minLength: 8)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Status (mirrors the Skill's Core Role section)

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeading(L10n.string("Status"))
            HStack(spacing: 8) {
                statusDot
                Text(verbatim: statusText)
                    .font(AppTheme.body(14))
                    .foregroundStyle(AppTheme.foregroundSecondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Text(verbatim: L10n.string("Probe Hint"))
                .font(AppTheme.body(13))
                .foregroundStyle(AppTheme.muted)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private var statusDot: some View {
        switch status {
        case .running:
            statusDotView(color: AppTheme.success)
        case .notRunning:
            statusDotView(color: AppTheme.meta)
        case .failed:
            statusDotView(color: AppTheme.danger)
        case .probing:
            ProgressView()
                .controlSize(.small)
                .frame(width: 10, height: 10)
        case .unknown:
            statusDotView(color: AppTheme.border)
        }
    }

    private func statusDotView(color: Color) -> some View {
        Circle()
            .fill(color)
            .frame(width: 10, height: 10)
            .padding(.horizontal, 2)
    }

    private var statusText: String {
        switch status {
        case .running: L10n.string("Running")
        case .notRunning: L10n.string("Not Running")
        case .failed(let reason):
            L10n.string("Failed") + (reason.isEmpty ? "" : ": \(reason)")
        case .probing: L10n.string("Probing…")
        case .unknown: L10n.string("Not Probed")
        }
    }

    // MARK: Configuration (mirrors the Skill's Locations grid)

    private func configurationSection(_ server: McpServerDescriptor) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeading(L10n.string("Configuration"))
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                keyValue(L10n.string("Transport"), value: transportLabel(server.transport), monospaced: true)
                switch server.transport {
                case .stdio:
                    keyValue(L10n.string("Command"), value: server.command ?? "", monospaced: true)
                    if !server.arguments.isEmpty {
                        keyValue(
                            L10n.string("Arguments"),
                            value: server.arguments.joined(separator: " "),
                            monospaced: true
                        )
                    }
                case .http, .sse:
                    keyValue(L10n.string("Endpoint"), value: server.url ?? "", monospaced: true)
                }
                keyValue(L10n.string("Scope"), value: scopeLabel(server), monospaced: false)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func keyValue(_ label: String, value: String, monospaced: Bool) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(verbatim: label)
                .font(AppTheme.body(13))
                .foregroundStyle(AppTheme.muted)
                .frame(width: 108, alignment: .leading)
            Text(verbatim: value)
                .font(monospaced ? AppTheme.mono(12) : AppTheme.body(13))
                .foregroundStyle(AppTheme.foreground)
                .textSelection(.enabled)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func scopeLabel(_ server: McpServerDescriptor) -> String {
        if let projectRootID = server.projectRootID {
            return L10n.string("Project") + " · \(projectRootID)"
        }
        return L10n.string("Global")
    }

    private func transportLabel(_ transport: McpTransport) -> String {
        switch transport {
        case .stdio: "stdio"
        case .http: "HTTP (streamable)"
        case .sse: "SSE"
        }
    }

    // MARK: Shared

    private func sectionHeading(_ title: String) -> some View {
        Text(verbatim: title)
            .font(AppTheme.display(14, weight: .semibold))
            .foregroundStyle(AppTheme.foreground)
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 16) {
            AppIconView(size: 96)
                .opacity(0.9)
            Text(verbatim: L10n.string("Select an MCP Server"))
                .font(AppTheme.display(28, weight: .semibold))
                .foregroundStyle(AppTheme.foreground)
            Text(verbatim: L10n.string("Select an MCP Server Description"))
                .font(AppTheme.body(14))
                .foregroundStyle(AppTheme.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}