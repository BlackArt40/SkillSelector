import AppKit
import SkillSelectorCore
import Foundation

enum DocumentAccessError: LocalizedError {
    case authorizationStorageUnavailable
    case noAuthorizedRoot
    case externalOpenFailed

    var errorDescription: String? {
        switch self {
        case .authorizationStorageUnavailable:
            L10n.string("Authorization storage is unavailable")
        case .noAuthorizedRoot:
            L10n.string("No authorized folder is associated with this Skill.")
        case .externalOpenFailed:
            L10n.string("The default editor could not open the Skill document.")
        }
    }
}

@MainActor
final class DocumentManager {
    private let bookmarks: BookmarkStore?

    init(bookmarks: BookmarkStore?) {
        self.bookmarks = bookmarks
    }

    func loadDocument(for skill: SkillSnapshot, authorizedRoots: [AuthorizedRootSnapshot]) async throws -> SkillDocument {
        let access = try resolveDocumentAccess(for: skill, authorizedRoots: authorizedRoots)
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

    func revealDocumentInFinder(for skill: SkillSnapshot, authorizedRoots: [AuthorizedRootSnapshot]) throws {
        try withDocumentAccess(for: skill, authorizedRoots: authorizedRoots) { request in
            let fileURL = try SkillDocumentReader().validatedEntryURL(request)
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        }
    }

    func openDocumentInDefaultEditor(for skill: SkillSnapshot, authorizedRoots: [AuthorizedRootSnapshot]) throws {
        try withDocumentAccess(for: skill, authorizedRoots: authorizedRoots) { request in
            let fileURL = try SkillDocumentReader().validatedEntryURL(request)
            guard NSWorkspace.shared.open(fileURL) else {
                throw DocumentAccessError.externalOpenFailed
            }
        }
    }

    private func withDocumentAccess<Result>(
        for skill: SkillSnapshot,
        authorizedRoots: [AuthorizedRootSnapshot],
        operation: (SkillDocumentRequest) throws -> Result
    ) throws -> Result {
        let access = try resolveDocumentAccess(for: skill, authorizedRoots: authorizedRoots)
        defer { access.leases.forEach { $0.close() } }
        return try operation(access.request)
    }

    func resolveDocumentAccess(
        for skill: SkillSnapshot,
        authorizedRoots: [AuthorizedRootSnapshot]
    ) throws -> (request: SkillDocumentRequest, leases: [AccessLease]) {
        guard let bookmarks else {
            throw DocumentAccessError.authorizationStorageUnavailable
        }
        let accesses: [AuthorizedRootAccess]
        do {
            accesses = try AuthorizedAccessResolver(bookmarks: bookmarks)
                .resolveAccess(for: skill, authorizedRoots: authorizedRoots)
        } catch AuthorizedAccessError.noAuthorizedRoot {
            throw DocumentAccessError.noAuthorizedRoot
        }
        return (SkillDocumentRequest(
            installationURL: URL(fileURLWithPath: skill.path),
            resolvedTargetURL: skill.resolvedTarget.map(URL.init(fileURLWithPath:)),
            entryFilename: skill.entryFilename,
            authorizedRootURLs: accesses.map(\.root.url)
        ), accesses.map(\.lease))
    }


}
