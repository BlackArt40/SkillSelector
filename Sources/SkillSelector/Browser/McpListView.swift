import SkillSelectorCore
import SwiftUI

/// The middle `.list-col` column for MCP servers: a header with title and
/// count plus a "Probe All" action, and the scrollable list of server rows.
struct McpListView: View {
    let servers: [McpServerDescriptor]
    let statuses: [String: McpProbeStatus]
    var selection: String?
    var agentNamesByID: [String: String] = [:]
    var isProbing: Bool = false
    var onSelect: ((McpServerDescriptor) -> Void)?
    var onProbeAll: (() -> Void)?
    var onRevealConfig: ((McpServerDescriptor) -> Void)?

    /// In-column text filter (name, command, URL, or config path).
    @State private var searchText = ""

    private var displayedServers: [McpServerDescriptor] {
        let term = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return servers }
        return servers
            .filter { server in
                [server.name, server.command, server.url, server.configFile, server.agentID]
                    .compactMap { $0 }
                    .contains { $0.localizedCaseInsensitiveContains(term) }
            }
            // Name hits float above command/URL-only hits (stable).
            .sorted { lhs, rhs in
                let lhsHit = lhs.name.localizedCaseInsensitiveContains(term)
                let rhsHit = rhs.name.localizedCaseInsensitiveContains(term)
                if lhsHit != rhsHit { return lhsHit }
                return false
            }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle()
                .fill(AppTheme.borderSoft)
                .frame(height: 1)
            if !servers.isEmpty {
                ListSearchBar(placeholderKey: "Search Mcp Placeholder", text: $searchText)
            }
            content
        }
        .background(AppTheme.background)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(verbatim: "MCP")
                .font(AppTheme.display(17, weight: .semibold))
                .foregroundStyle(AppTheme.foreground)
                .lineLimit(1)
            Text(verbatim: "\(displayedServers.count)")
                .font(AppTheme.body(12))
                .foregroundStyle(AppTheme.muted)
            Spacer(minLength: 8)
            if !servers.isEmpty {
                Button {
                    onProbeAll?()
                } label: {
                    HStack(spacing: 4) {
                        if isProbing {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(verbatim: L10n.string("Probe All MCP"))
                    }
                    .font(AppTheme.body(12, weight: .medium))
                    .foregroundStyle(AppTheme.accentActive)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isProbing)
                .help(L10n.string("Probe All MCP"))
                .accessibilityLabel(L10n.string("Probe All MCP"))
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .frame(height: 46)
        .background(AppTheme.background)
    }

    @ViewBuilder
    private var content: some View {
        if servers.isEmpty {
            emptyState
        } else if displayedServers.isEmpty {
            NoResultsView()
        } else {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(displayedServers) { server in
                        McpServerRow(
                            server: server,
                            status: statuses[server.id] ?? .unknown,
                            agentNamesByID: agentNamesByID,
                            isActive: selection == server.id,
                            highlightQuery: searchText,
                            onSelect: { onSelect?(server) },
                            onRevealConfig: { onRevealConfig?(server) }
                        )
                        .padding(.horizontal, 8)
                    }
                }
                .padding(.vertical, 8)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 48)
            Image(systemName: "rectangle.connected.to.line.below")
                .font(.system(size: 26))
                .foregroundStyle(AppTheme.meta)
            Text(verbatim: L10n.string("No MCP Servers"))
                .font(AppTheme.display(17, weight: .semibold))
                .foregroundStyle(AppTheme.foreground)
            Text(verbatim: L10n.string("No MCP Servers Description"))
                .font(AppTheme.body(13))
                .foregroundStyle(AppTheme.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)
            Spacer(minLength: 48)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One `.skill-row`-like row for an MCP server: name, transport/launch line,
/// probe status dot, and a reveal-config action.
struct McpServerRow: View {
    let server: McpServerDescriptor
    let status: McpProbeStatus
    var agentNamesByID: [String: String] = [:]
    let isActive: Bool
    /// Active search text; hits in the name/launch line are highlighted.
    var highlightQuery: String = ""
    var onSelect: (() -> Void)?
    var onRevealConfig: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            statusBadge
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    HighlightedText(
                        text: server.name,
                        query: highlightQuery,
                        font: AppTheme.body(13, weight: .medium),
                        baseColor: isActive ? AppTheme.accentActive : AppTheme.foreground
                    )
                    .lineLimit(1)
                    if let agentName = agentNamesByID[server.agentID ?? ""] {
                        Text(verbatim: agentName)
                            .font(AppTheme.body(11))
                            .foregroundStyle(AppTheme.muted)
                            .lineLimit(1)
                    }
                }
                HighlightedText(
                    text: server.launchSummary,
                    query: highlightQuery,
                    font: AppTheme.mono(11),
                    baseColor: AppTheme.muted
                )
                .lineLimit(1)
                .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            Button {
                onRevealConfig?()
            } label: {
                Image(systemName: "doc")
                    .font(.system(size: 12))
                    .foregroundStyle(AppTheme.muted)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.string("Reveal MCP Config"))
            .accessibilityLabel(L10n.string("Reveal MCP Config"))
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 46)
        .background(isActive ? AppTheme.accentTint : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect?()
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch status {
        case .running:
            statusCircle(color: AppTheme.success)
        case .notRunning:
            statusCircle(color: AppTheme.meta)
        case .failed:
            statusCircle(color: AppTheme.danger)
        case .probing:
            ProgressView()
                .controlSize(.mini)
                .frame(width: 14, height: 14)
        case .unknown:
            statusCircle(color: AppTheme.border)
        }
    }

    private func statusCircle(color: Color) -> some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .padding(.horizontal, 3)
    }
}