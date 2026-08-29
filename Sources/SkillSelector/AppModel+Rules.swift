import AppKit
import Foundation
import SkillSelectorCore

/// Rules-file discovery support in the app model — mirrors
/// `AppModel+Mcp.swift`.
///
/// The list (`rulesFiles`) is a live mapping of the authorized roots'
/// known rules files — recomputed on every refresh, never persisted (the
/// files on disk are the source of truth, exactly like MCP servers).
extension AppModel {
    /// The authorized `.home` (or system) root whose user-level rules live
    /// under it; project roots carry the project-level rules.
    private var rulesHomeRoot: AuthorizedRootSnapshot? {
        authorizedRoots.first { $0.kind == .home || $0.kind == .system }
    }

    private var rulesProjectRoots: [AuthorizedRootSnapshot] {
        authorizedRoots.filter { $0.kind == .project }
    }

    /// Re-scans the rules file list from the current authorized roots.
    /// Called by `reloadSnapshot()` — the same point where skills and MCP
    /// servers refresh — so authorize/revoke/refresh all keep it current.
    func reloadRulesFiles() {
        var accesses: [AuthorizedRootAccess] = []
        if let bookmarks {
            let roots = [rulesHomeRoot].compactMap(\.self) + rulesProjectRoots
            for root in roots {
                if let access = try? bookmarks.resolve(id: root.id) {
                    accesses.append(access)
                }
            }
        }
        defer { accesses.forEach { $0.lease.close() } }
        rulesFiles = RulesScanner().scan(homeRoot: rulesHomeRoot, projectRoots: rulesProjectRoots)
    }

    /// Resolves the security-scoped access needed to read a rules file,
    /// mirroring the Skills' document access: the file must sit inside an
    /// authorized root whose lease we can resolve.
    private func resolveRulesAccess(
        for file: RulesFileDescriptor
    ) throws -> (request: SkillDocumentRequest, leases: [AccessLease]) {
        guard let bookmarks else {
            throw DocumentAccessError.authorizationStorageUnavailable
        }
        let root: AuthorizedRootSnapshot
        if let projectRootID = file.projectRootID {
            guard let found = authorizedRoots.first(where: { $0.id == projectRootID }) else {
                throw DocumentAccessError.noAuthorizedRoot
            }
            root = found
        } else {
            guard let found = rulesHomeRoot else {
                throw DocumentAccessError.noAuthorizedRoot
            }
            root = found
        }
        let access: AuthorizedRootAccess
        do {
            access = try bookmarks.resolve(id: root.id)
        } catch {
            throw DocumentAccessError.noAuthorizedRoot
        }
        let url = URL(fileURLWithPath: file.path)
        return (
            SkillDocumentRequest(
                installationURL: url.deletingLastPathComponent(),
                resolvedTargetURL: nil,
                entryFilename: url.lastPathComponent,
                authorizedRootURLs: [root.url]
            ),
            [access.lease]
        )
    }

    /// Reads a rules file with the same validated, size-bounded reader the
    /// Skills use.
    func loadRulesDocument(_ file: RulesFileDescriptor) async throws -> SkillDocument {
        let access = try resolveRulesAccess(for: file)
        defer { access.leases.forEach { $0.close() } }
        let request = access.request
        let readTask = Task.detached(priority: .userInitiated) {
            try SkillDocumentReader().read(request)
        }
        return try await readTask.value
    }

    /// Reveals a rules file in Finder — the only file action on rules,
    /// mirroring the read-only reveal for Skills and MCP configs.
    func revealRulesFile(_ file: RulesFileDescriptor) throws {
        try withRulesAccess(for: file) { request in
            let fileURL = try SkillDocumentReader().validatedEntryURL(request)
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        }
    }

    /// Opens a rules file in the default editor.
    func openRulesFileInEditor(_ file: RulesFileDescriptor) throws {
        try withRulesAccess(for: file) { request in
            let fileURL = try SkillDocumentReader().validatedEntryURL(request)
            guard NSWorkspace.shared.open(fileURL) else {
                throw DocumentAccessError.externalOpenFailed
            }
        }
    }

    private func withRulesAccess<Result>(
        for file: RulesFileDescriptor,
        operation: (SkillDocumentRequest) throws -> Result
    ) throws -> Result {
        let access = try resolveRulesAccess(for: file)
        defer { access.leases.forEach { $0.close() } }
        return try operation(access.request)
    }
}
