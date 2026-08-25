import AppKit
import Foundation
import SkillSelectorCore

/// MCP detection support in the app model.
///
/// The server list (`mcpServers`) is a live mapping of the authorized
/// roots' config files — recomputed on every refresh, never persisted (the
/// files on disk are the source of truth, exactly like `unhealthyRootIDs`).
/// Probe statuses (`mcpProbeStatuses`) are transient snapshots: `.unknown`
/// until the user asks, then a one-shot verdict per server. Both properties
/// are observable so SwiftUI re-renders when they change.
extension AppModel {
    /// The authorized `.home` (or system) root whose user-level configs are
    /// MCP sources; project roots carry the project-level configs.
    private var mcpHomeRoot: AuthorizedRootSnapshot? {
        authorizedRoots.first { $0.kind == .home || $0.kind == .system }
    }

    private var mcpProjectRoots: [AuthorizedRootSnapshot] {
        authorizedRoots.filter { $0.kind == .project }
    }

    /// Re-parses the MCP server list from the current authorized roots.
    /// Called by `reloadSnapshot()` — the same point where skills refresh —
    /// so authorize/revoke/refresh all keep the list current.
    func reloadMcpServers() {
        // Reading the config files needs the roots' security-scoped access;
        // hold every resolvable lease for the (small) read pass.
        var accesses: [AuthorizedRootAccess] = []
        if let bookmarks {
            let roots = [mcpHomeRoot].compactMap(\.self) + mcpProjectRoots
            for root in roots {
                if let access = try? bookmarks.resolve(id: root.id) {
                    accesses.append(access)
                }
            }
        }
        defer { accesses.forEach { $0.lease.close() } }

        let scanner = McpScanner()
        mcpServers = scanner.scan(homeRoot: mcpHomeRoot, projectRoots: mcpProjectRoots)
        mcpProbeStatuses = [:]
    }

    /// One-shot probe of every current server. User-initiated only — never
    /// scheduled. Each server gets `.probing` while in flight, then its
    /// verdict; the map is complete when the call returns.
    func probeAllMcpServers() async {
        for server in mcpServers {
            mcpProbeStatuses[server.id] = .probing
            // Let the UI paint the spinning row before the probe starts.
            try? await Task.sleep(nanoseconds: 50_000_000)
            let status = await McpProber().probe(server)
            mcpProbeStatuses[server.id] = status
        }
    }

    /// One-shot probe of a single server (detail-pane button).
    func probeMcpServer(id: String) async {
        guard let server = mcpServers.first(where: { $0.id == id }) else { return }
        mcpProbeStatuses[id] = .probing
        try? await Task.sleep(nanoseconds: 50_000_000)
        let status = await McpProber().probe(server)
        mcpProbeStatuses[id] = status
    }

    /// Reveals a server's config file in Finder — the only file action on
    /// configs, mirroring the Skills' read-only reveal.
    func revealMcpConfigFile(_ server: McpServerDescriptor) {
        let url = URL(fileURLWithPath: server.configFile)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}