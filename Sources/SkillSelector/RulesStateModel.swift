import AppKit
import Foundation
import SkillSelectorCore

/// Rules-file discovery state, extracted from `AppModel` (Brooks-Lint
/// finding 2). Mirrors `McpStateModel`.
///
/// The list (`files`) is a live mapping of the authorized roots' known
/// rules files — recomputed on every refresh, never persisted (the files
/// on disk are the source of truth, exactly like MCP servers).
///
/// `roots` is a snapshot of the authorized roots captured by each `reload`
/// (the Submodel owns it so the file/document APIs stay parameter-free).
/// `renameRoot` only renames a root's display `customName`, so it never
/// touches this model's logic — only the path-based `id`/`url` matter here.
@MainActor
@Observable
final class RulesStateModel {
    var files: [RulesFileDescriptor] = []

    /// The authorized roots as of the last `reload`, used to resolve the
    /// security-scoped access behind every document/file API. Not observable
    /// by design — it only feeds lookups, never the rules list rendering.
    @ObservationIgnored private(set) var roots: [AuthorizedRootSnapshot] = []

    /// The bookmark store is immutable after app launch, so the submodel
    /// keeps its own reference instead of reaching into `AppModel`.
    private let bookmarks: BookmarkStore?

    init(bookmarks: BookmarkStore?) {
        self.bookmarks = bookmarks
    }

    /// Re-scans the rules file list from the current authorized roots.
    /// Called by `AppModel.reloadSnapshot()` — the same point where skills
    /// and MCP servers refresh — so authorize/revoke/refresh all keep it
    /// current.
    func reload(authorizedRoots: [AuthorizedRootSnapshot]) {
        self.roots = authorizedRoots
        let homeRoot = authorizedRoots.homeRoot
        let projectRoots = authorizedRoots.projectRoots

        // Reading the rules files needs the roots' security-scoped access;
        // hold every resolvable lease for the (small) read pass, reusing the
        // shared scoped-lease helper every submodel reloads through.
        let accesses = resolveScopedAuthorizedAccesses(in: authorizedRoots, through: bookmarks)
        defer { accesses.forEach { $0.lease.close() } }
        files = RulesScanner().scan(homeRoot: homeRoot, projectRoots: projectRoots)
    }

    /// Resolves the security-scoped access needed to read a rules file,
    /// mirroring the Skills' document access: the file must sit inside an
    /// authorized root whose lease we can resolve.
    private func resolveAccess(for file: RulesFileDescriptor) throws -> (request: SkillDocumentRequest, leases: [AccessLease]) {
        guard let bookmarks else {
            throw DocumentAccessError.authorizationStorageUnavailable
        }
        let root: AuthorizedRootSnapshot
        if let projectRootID = file.projectRootID {
            guard let found = roots.first(where: { $0.id == projectRootID }) else {
                throw DocumentAccessError.noAuthorizedRoot
            }
            root = found
        } else {
            guard let found = roots.homeRoot else {
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

    private func withAccess<Result>(
        for file: RulesFileDescriptor,
        operation: (SkillDocumentRequest) throws -> Result
    ) throws -> Result {
        let access = try resolveAccess(for: file)
        defer { access.leases.forEach { $0.close() } }
        return try operation(access.request)
    }

    /// Reads a rules file with the same validated, size-bounded reader the
    /// Skills use.
    func loadDocument(_ file: RulesFileDescriptor) async throws -> SkillDocument {
        let access = try resolveAccess(for: file)
        defer { access.leases.forEach { $0.close() } }
        let request = access.request
        let readTask = Task.detached(priority: .userInitiated) {
            try SkillDocumentReader().read(request)
        }
        return try await withTaskCancellationHandler {
            try await readTask.value
        } onCancel: {
            readTask.cancel()
        }
    }

    /// Reveals a rules file in Finder — the only file action on rules,
    /// mirroring the read-only reveal for Skills and MCP configs.
    func revealFile(_ file: RulesFileDescriptor) throws {
        try withAccess(for: file) { request in
            let fileURL = try SkillDocumentReader().validatedEntryURL(request)
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        }
    }

    /// Opens a rules file in the default editor.
    func openFileInEditor(_ file: RulesFileDescriptor) throws {
        try withAccess(for: file) { request in
            let fileURL = try SkillDocumentReader().validatedEntryURL(request)
            guard NSWorkspace.shared.open(fileURL) else {
                throw DocumentAccessError.externalOpenFailed
            }
        }
    }

    /// Line diff between two rules files' bodies (frontmatter-stripped) —
    /// used by the same-name comparison (e.g. a project CLAUDE.md vs the
    /// global one). Returns nil when either file cannot be read.
    func bodyDiff(_ left: RulesFileDescriptor, _ right: RulesFileDescriptor) async -> LineDiff? {
        guard let leftBody = try? await bodyLines(of: left),
              let rightBody = try? await bodyLines(of: right) else {
            return nil
        }
        return LineDiff.compute(leftBody, rightBody)
    }

    private func bodyLines(of file: RulesFileDescriptor) async throws -> [String] {
        let document = try await loadDocument(file)
        return FrontmatterParser.bodyLines(from: document.source)
    }
}