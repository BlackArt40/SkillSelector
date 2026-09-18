import SkillSelectorCore
import SwiftUI

/// The middle `.list-col` column for MCP servers: a header with title and
/// count plus a "Probe All" action, and the scrollable list of server rows.
struct McpListView: View {
    let servers: [McpServerDescriptor]
    let statuses: [String: McpProbeStatus]
    /// Configs that exist but produced no servers (oversized, unreadable, or
    /// unparseable). Surfaced here so a broken config never reads as "this
    /// Agent has no MCP servers" — which is the whole difference the panel
    /// previously could not make.
    var scanIssues: [McpScanIssue] = []
    /// Ids of servers whose name is also declared in the other scope.
    var conflictingIDs: Set<String> = []
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
            if !servers.isEmpty && !scanIssues.isEmpty {
                issueBanner
            }
            content
        }
        .background(AppTheme.background)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// mcp.html's `#mcp-toolbar`: title + count badge row, then the probe
    /// action beside the search field, all above a 1 px ink hairline.
    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(verbatim: "MCP")
                    .font(AppTheme.body(13, weight: .bold))
                    .foregroundStyle(AppTheme.foreground)
                Text(verbatim: "\(displayedServers.count)")
                    .font(AppTheme.body(12))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(AppTheme.surface)
                    .overlay(Rectangle().stroke(AppTheme.ink, lineWidth: 1))
                    .accessibilityLabel(String.localizedStringWithFormat(
                        L10n.string("MCP List Count"), displayedServers.count
                    ))
            }
            if !servers.isEmpty {
                HStack(spacing: 8) {
                    probeAllButton
                    ListSearchBar(placeholderKey: "Search Mcp Placeholder", text: $searchText, style: .card)
                }
            }
        }
        .padding(16)
        .background(AppTheme.background)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(AppTheme.ink)
                .frame(height: 1)
        }
    }

    /// mcp.html's `#mcp-check-all`: 36 pt card button with a 1 px ink
    /// border and the hard offset shadow, lifting on hover and sinking on
    /// press; the icon becomes a spinner while a probe runs.
    private var probeAllButton: some View {
        Button {
            onProbeAll?()
        } label: {
            HStack(spacing: 6) {
                if isProbing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "play.circle")
                        .font(.system(size: 13))
                }
                Text(verbatim: L10n.string("Probe All MCP"))
            }
            .font(AppTheme.body(13))
            .foregroundStyle(AppTheme.foreground)
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(AppTheme.surface)
            .overlay(Rectangle().stroke(AppTheme.ink, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(ProbeButtonStyle())
        .disabled(isProbing)
        .help(L10n.string("Probe All MCP"))
        .accessibilityLabel(L10n.string("Probe All MCP"))
    }

    @ViewBuilder
    private var content: some View {
        if servers.isEmpty && !scanIssues.isEmpty {
            // Deliberately not the plain empty state: config files were
            // found and could not be read, which is a different problem
            // with a different fix.
            skippedConfigsState
        } else if servers.isEmpty {
            emptyState
        } else if displayedServers.isEmpty {
            NoResultsView()
        } else {
            ScrollView {
                // mcp.html `#mcp-list`: flat full-bleed rows separated by
                // the white hairline, no inter-row gaps.
                VStack(spacing: 0) {
                    ForEach(displayedServers) { server in
                        McpServerRow(
                            server: server,
                            status: statuses[server.id] ?? .unknown,
                            isConflicted: conflictingIDs.contains(server.id),
                            agentNamesByID: agentNamesByID,
                            isActive: selection == server.id,
                            highlightQuery: searchText,
                            onSelect: { onSelect?(server) },
                            onRevealConfig: { onRevealConfig?(server) }
                        )
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        EmptyState(
            icon: "rectangle.connected.to.line.below",
            title: L10n.string("No MCP Servers"),
            message: L10n.string("No MCP Servers Description")
        )
    }

    /// Compact form for when servers *were* found but some configs were not
    /// read: the list below is incomplete, and this is why.
    private var issueBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(scanIssues, id: \.configPath) { issue in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(AppTheme.warn)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: McpExplanations.scanIssueReason(issue))
                            .font(AppTheme.body(11, weight: .medium))
                            .foregroundStyle(AppTheme.foregroundSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(verbatim: issue.configPath)
                            .font(AppTheme.mono(10))
                            .foregroundStyle(AppTheme.muted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(verbatim: McpExplanations.scanIssueNextStep(issue))
                            .font(AppTheme.body(11))
                            .foregroundStyle(AppTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.warn.opacity(0.10))
    }

    /// What the panel shows when every config it found is unreadable.
    private var skippedConfigsState: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                EmptyState(
                    icon: "exclamationmark.triangle",
                    title: L10n.string("MCP Skipped Configs"),
                    message: L10n.string("MCP Skipped Configs Description")
                )
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(scanIssues, id: \.configPath) { issue in
                        issueCard(issue)
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.bottom, 24)
        }
    }

    private func issueCard(_ issue: McpScanIssue) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: McpExplanations.scanIssueReason(issue))
                .font(AppTheme.body(12, weight: .medium))
                .foregroundStyle(AppTheme.foreground)
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: issue.configPath)
                .font(AppTheme.mono(11))
                .foregroundStyle(AppTheme.muted)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: McpExplanations.scanIssueNextStep(issue))
                .font(AppTheme.body(12))
                .foregroundStyle(AppTheme.foregroundSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.warn.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// One mcp.html row (`article`): probe-tinted transport icon, bold name,
/// agent chip, launch line, and a bordered reveal-config button — a flat
/// full-bleed row over the white bottom hairline, selected with the
/// sidebar-accent fill and a 2 px accent bar on the leading edge.
struct McpServerRow: View {
    let server: McpServerDescriptor
    let status: McpProbeStatus
    /// This name is also declared in the other scope; the detail pane
    /// explains what to check.
    var isConflicted: Bool = false
    var agentNamesByID: [String: String] = [:]
    let isActive: Bool
    /// Active search text; hits in the name/launch line are highlighted.
    var highlightQuery: String = ""
    var onSelect: (() -> Void)?
    var onRevealConfig: (() -> Void)?

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 12) {
            statusIcon
                .frame(width: 16)
            HighlightedText(
                text: server.name,
                query: highlightQuery,
                font: AppTheme.body(13, weight: .bold),
                baseColor: AppTheme.foreground
            )
            .lineLimit(1)
            if isConflicted {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(AppTheme.warn)
                    .help(L10n.string("MCP Scope Conflict"))
                    .accessibilityLabel(L10n.string("MCP Scope Conflict"))
            }
            if let agentName = agentNamesByID[server.agentID ?? ""] {
                AgentChip(text: agentName, onActiveRow: isActive)
            }
            HighlightedText(
                text: server.launchSummary,
                query: highlightQuery,
                font: AppTheme.mono(12),
                baseColor: AppTheme.muted
            )
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                onRevealConfig?()
            } label: {
                Image(systemName: "doc")
                    .font(.system(size: 13))
                    .foregroundStyle(AppTheme.accent)
                    .frame(width: 32, height: 32)
                    .background(AppTheme.surface)
                    .overlay(Rectangle().stroke(AppTheme.ink, lineWidth: 1))
                    .contentShape(Rectangle())
            }
            .buttonStyle(RowIconButtonStyle())
            .help(L10n.string("Reveal MCP Config"))
            .accessibilityLabel(L10n.string("Reveal MCP Config"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background {
            if isActive || isHovering {
                AppTheme.sidebarAccent
            }
        }
        .overlay(alignment: .leading) {
            if isActive {
                Rectangle()
                    .fill(AppTheme.accent)
                    .frame(width: 2)
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(AppTheme.border)
                .frame(height: 1)
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture {
            onSelect?()
        }
    }

    /// The design's muted transport glyph doubles as the probe indicator:
    /// the color only speaks once a probe has run, otherwise it stays
    /// muted exactly like the page.
    @ViewBuilder
    private var statusIcon: some View {
        switch status {
        case .running:
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 13))
                .foregroundStyle(AppTheme.success)
        case .notRunning:
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 13))
                .foregroundStyle(AppTheme.meta)
        case .failed:
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 13))
                .foregroundStyle(AppTheme.danger)
        case .probing:
            ProgressView()
                .controlSize(.mini)
                .frame(width: 16, height: 16)
        case .unknown:
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 13))
                .foregroundStyle(AppTheme.foregroundSecondary)
        }
    }
}

/// Hover lift / press sink shared by the row's bordered icon button
/// (mcp.html's inline `transition-all` rules).
private struct RowIconButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .offset(
                x: configuration.isPressed ? 1 : (isHovering ? -1 : 0),
                y: configuration.isPressed ? 1 : (isHovering ? -1 : 0)
            )
            .onHover { isHovering = $0 }
    }
}

/// The toolbar probe button's hover/press transform: shadow rides only
/// while resting, press sinks flat (mcp.html's `transition-all` rules).
private struct ProbeButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        Group {
            if configuration.isPressed {
                configuration.label
            } else {
                configuration.label.hardShadow(.rest)
            }
        }
        .offset(
            x: configuration.isPressed ? 1 : (isHovering ? -1 : 0),
            y: configuration.isPressed ? 1 : (isHovering ? -1 : 0)
        )
        .onHover { isHovering = $0 }
    }
}