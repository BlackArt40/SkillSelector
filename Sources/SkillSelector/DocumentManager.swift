import AppKit
import SkillSelectorCore
import Foundation

enum DocumentManagerError: Error {
    case authorizationStorageUnavailable
    case noAuthorizedRoot
    case externalOpenFailed
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
                throw DocumentManagerError.externalOpenFailed
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
            throw DocumentManagerError.authorizationStorageUnavailable
        }

        var requiredRootIDs = Set(skill.rootIDs)
        if let resolvedTarget = skill.resolvedTarget.map(URL.init(fileURLWithPath:)) {
            requiredRootIDs.formUnion(rootIDs(containingResolvedURL: resolvedTarget, authorizedRoots: authorizedRoots))
        }
        var accesses: [AuthorizedRootAccess] = []
        var firstResolutionError: Error?
        for rootID in requiredRootIDs.sorted() {
            do {
                accesses.append(try bookmarks.resolve(id: rootID))
            } catch {
                firstResolutionError = firstResolutionError ?? error
            }
        }
        guard !accesses.isEmpty else {
            if let firstResolutionError { throw firstResolutionError }
            throw DocumentManagerError.noAuthorizedRoot
        }
        let installationURL = URL(fileURLWithPath: skill.path)
        let logicalCovered = accesses.contains {
            installationURL.isContained(in: $0.root.url.standardizedFileURL)
        }
        let targetCovered = skill.resolvedTarget.map(URL.init(fileURLWithPath:)).map { target in
            accesses.contains {
                target.standardizedFileURL.isContained(
                    in: $0.root.url.resolvingSymlinksInPath().standardizedFileURL
                )
            }
        } ?? true
        guard logicalCovered, targetCovered else {
            accesses.forEach { $0.lease.close() }
            if let firstResolutionError { throw firstResolutionError }
            throw DocumentManagerError.noAuthorizedRoot
        }
        return (SkillDocumentRequest(
            installationURL: installationURL,
            resolvedTargetURL: skill.resolvedTarget.map(URL.init(fileURLWithPath:)),
            entryFilename: skill.entryFilename,
            authorizedRootURLs: accesses.map(\.root.url)
        ), accesses.map(\.lease))
    }

    private func rootIDs(containingLogicalURL url: URL, authorizedRoots: [AuthorizedRootSnapshot]) -> Set<String> {
        Set(authorizedRoots.filter {
            url.standardizedFileURL.isContained(in: $0.url.standardizedFileURL)
        }.map(\.id))
    }

    private func rootIDs(containingResolvedURL url: URL, authorizedRoots: [AuthorizedRootSnapshot]) -> Set<String> {
        Set(authorizedRoots.filter {
            url.standardizedFileURL.isContained(
                in: $0.url.resolvingSymlinksInPath().standardizedFileURL
            )
        }.map(\.id))
    }
}
