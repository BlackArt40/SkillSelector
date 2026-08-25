import SkillSelectorCore
import SwiftUI

/// The Agent detail pane: Skill top, and the Agent's MCP servers below,
/// sized to its rows. The MCP section is absent entirely when the Agent
/// wires none; it shows at most `maxVisibleMcpServers` rows.
struct AgentDetailView: View {
    let skill: SkillSnapshot?
    let agentID: String
    let rootsByID: [String: AuthorizedRootSnapshot]
    let agentNamesByID: [String: String]
    let mcpServers: [McpServerDescriptor]
    let mcpStatuses: [String: McpProbeStatus]
    var onRevealInFinder: ((SkillSnapshot) -> Void)?
    var onOpenInEditor: ((SkillSnapshot) -> Void)?
    var onSelectMcp: ((McpServerDescriptor) -> Void)?
    var onRevealConfig: ((McpServerDescriptor) -> Void)?
    var onProbeAll: (() -> Void)?
    var isProbingMcp: Bool = false

    /// How many MCP rows the Agent detail shows at most; beyond this the
    /// list is clipped to the first servers.
    private static let maxVisibleMcpServers = 5

    private var agentMcpServers: [McpServerDescriptor] {
        mcpServers.filter { $0.agentID == agentID }
    }

    var body: some View {
        // No MCP servers for this Agent: the column is absent entirely —
        // the Skill detail takes the full pane. With servers, the MCP
        // section sits below a divider and sizes itself to its rows.
        Group {
            if agentMcpServers.isEmpty {
                skillDetail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    skillDetail
                        .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                    Rectangle()
                        .fill(AppTheme.borderSoft)
                        .frame(height: 1)
                    agentMcpSection
                }
            }
        }
        .background(AppTheme.background)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(AppTheme.borderSoft)
                .frame(width: 1)
        }
    }

    private var skillDetail: some View {
        SkillDetailView(
            skill: skill,
            rootsByID: rootsByID,
            agentNamesByID: agentNamesByID,
            onRevealInFinder: onRevealInFinder,
            onOpenInEditor: onOpenInEditor
        )
    }

    private var agentMcpSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(verbatim: L10n.string("MCP"))
                    .font(AppTheme.display(15, weight: .semibold))
                    .foregroundStyle(AppTheme.foreground)
                Text(verbatim: "\(agentMcpServers.count)")
                    .font(AppTheme.body(12))
                    .foregroundStyle(AppTheme.muted)
                Spacer(minLength: 8)
                if !agentMcpServers.isEmpty {
                    Button {
                        onProbeAll?()
                    } label: {
                        HStack(spacing: 4) {
                            if isProbingMcp {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text(verbatim: L10n.string("Probe All MCP"))
                                .font(AppTheme.body(12, weight: .medium))
                        }
                        .foregroundStyle(AppTheme.accentActive)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isProbingMcp)
                    .help(L10n.string("Probe All MCP"))
                    .accessibilityLabel(L10n.string("Probe All MCP"))
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 40)

            Rectangle()
                .fill(AppTheme.borderSoft)
                .frame(height: 1)

            mcpRows
                .frame(maxWidth: .infinity, maxHeight: rowsHeight)
        }
    }

    /// Fixed 48 pt per row (46 min-height row + 2 pt LazyVStack spacing),
    /// plus 12 pt vertical padding, capped at 5 — "最多显示 5 个". Fewer
    /// rows shrink the section with the content instead of reserving
    /// empty space.
    private var rowsHeight: CGFloat {
        let visible = min(agentMcpServers.count, Self.maxVisibleMcpServers)
        return CGFloat(visible) * 48 + 12
    }

    @ViewBuilder
    private var mcpRows: some View {
        let visible = Array(agentMcpServers.prefix(Self.maxVisibleMcpServers))
        LazyVStack(spacing: 2) {
            ForEach(visible) { server in
                McpServerRow(
                    server: server,
                    status: mcpStatuses[server.id] ?? .unknown,
                    agentNamesByID: agentNamesByID,
                    isActive: false,
                    onSelect: { onSelectMcp?(server) },
                    onRevealConfig: { onRevealConfig?(server) }
                )
                .padding(.horizontal, 8)
            }
        }
        .padding(.vertical, 6)
    }
}