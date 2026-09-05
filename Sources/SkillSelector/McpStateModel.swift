import AppKit
import Combine
import Foundation
import SkillSelectorCore

/// MCP detection state, extracted from `AppModel` (Brooks-Lint finding 2).
///
/// The server list (`servers`) is a live mapping of the authorized roots'
/// config files — recomputed on every refresh, never persisted (the files
/// on disk are the source of truth, exactly like `unhealthyRootIDs`).
/// Probe statuses (`probeStatuses`) are transient snapshots: `.unknown`
/// until the user asks, then a one-shot verdict per server. Both
/// properties are observable so SwiftUI re-renders when they change.
@MainActor
final class McpStateModel: ObservableObject {
    @Published var servers: [McpServerDescriptor] = []
    @Published var probeStatuses: [String: McpProbeStatus] = [:]

    /// The bookmark store is immutable after app launch, so the submodel
    /// keeps its own reference instead of reaching into `AppModel`.
    private let bookmarks: BookmarkStore?

    init(bookmarks: BookmarkStore?) {
        self.bookmarks = bookmarks
    }

    /// Re-parses the server list from the current authorized roots. Called
    /// by `AppModel.reloadSnapshot()` — the same point where skills refresh
    /// — so authorize/revoke/refresh all keep the list current.
    func reload(authorizedRoots: [AuthorizedRootSnapshot]) {
        let homeRoot = authorizedRoots.homeRoot
        let projectRoots = authorizedRoots.projectRoots

        // Reading the config files needs the roots' security-scoped access;
        // hold every resolvable lease for the (small) read pass.
        let accesses = resolveScopedAuthorizedAccesses(in: authorizedRoots, through: bookmarks)
        defer { accesses.forEach { $0.lease.close() } }

        let scanner = McpScanner()
        servers = scanner.scan(homeRoot: homeRoot, projectRoots: projectRoots)
        probeStatuses = [:]
    }

    /// One-shot probe of every current server. User-initiated only — never
    /// scheduled. Statuses start at `.probing` so the list paints the spin
    /// before any verdict lands.
    func probeAll() async {
        await probe(servers)
    }

    /// One-shot probe of one Agent's MCP servers (Agent detail half).
    func probe(agentID: String) async {
        let agents = servers.filter { $0.agentID == agentID }
        await probe(agents)
    }

    /// Shared probe pass: marks every server `.probing`, then runs the real
    /// handshakes concurrently and folds each verdict in as it lands. Probe
    /// processes are throwaway, so parallel probing is safe — each server's
    /// child is started, answered, and force-terminated independently.
    private func probe(_ servers: [McpServerDescriptor]) async {
        for server in servers {
            probeStatuses[server.id] = .probing
        }
        // Give the UI a frame to paint the spinning rows before verdicts
        // start landing.
        try? await Task.sleep(nanoseconds: 50_000_000)
        await withTaskGroup(of: Void.self) { group in
            for server in servers {
                group.addTask { [server] in
                    // Keep the original per-probe delay: each row shows its
                    // spinner before being swapped to the verdict.
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    let status = await McpProber().probe(server)
                    await MainActor.run {
                        self.probeStatuses[server.id] = status
                    }
                }
            }
        }
    }

    /// One-shot probe of a single server (detail-pane button).
    func probe(serverID: String) async {
        guard let server = servers.first(where: { $0.id == serverID }) else { return }
        probeStatuses[serverID] = .probing
        try? await Task.sleep(nanoseconds: 50_000_000)
        let status = await McpProber().probe(server)
        probeStatuses[serverID] = status
    }

    /// Reveals a server's config file in Finder — the only file action on
    /// configs, mirroring the Skills' read-only reveal.
    func revealConfigFile(_ server: McpServerDescriptor) {
        let url = URL(fileURLWithPath: server.configFile)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}