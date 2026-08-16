import CryptoKit
import Darwin
import Foundation

public enum SkillFileOperatorError: Error, Equatable, Sendable {
    case sourceMissing
    case sourceChanged
    case unauthorizedSource
    case unregisteredSource
    case resolvedSourceMismatch
    case destinationRequired
    case unauthorizedDestination
    case unregisteredDestination
    case invalidName(String)
    case destinationConflict
    case destinationChanged
    case authorizationChanged
    case registryChanged
    case invalidConfirmation
    case replacementConfirmationRequired
    case invalidReplacementConfirmation
    case invalidOrConsumedPlan
    case invalidStagedSkill
    case filesystemFailure(String)
    case rollbackFailed(original: String, rollback: String)
}

public protocol FileOperationTrashing: AnyObject {
    func trashItem(at url: URL) throws -> URL
}

public final class MacOSTrash: FileOperationTrashing {
    public init() {}

    public func trashItem(at url: URL) throws -> URL {
        var resultingURL: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
        guard let resultingURL else {
            throw SkillFileOperatorError.filesystemFailure("Trash did not return an item URL")
        }
        return resultingURL as URL
    }
}

struct FileOperationFileSystem: @unchecked Sendable {
    let snapshot: (URL) throws -> FileOperationItemSnapshot?
    let contents: (URL) throws -> [URL]
    let copy: (URL, URL) throws -> Void
    let move: (URL, URL) throws -> Void
    let remove: (URL) throws -> Void
    let createSymbolicLink: (URL, String) throws -> Void

    static let live = FileOperationFileSystem(
        snapshot: Self.liveSnapshot,
        contents: { url in
            try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isSymbolicLinkKey],
                options: []
            )
        },
        copy: { try FileManager.default.copyItem(at: $0, to: $1) },
        move: { try FileManager.default.moveItem(at: $0, to: $1) },
        remove: { try FileManager.default.removeItem(at: $0) },
        createSymbolicLink: { url, target in
            try FileManager.default.createSymbolicLink(
                atPath: url.path,
                withDestinationPath: target
            )
        }
    )

    private static func liveSnapshot(_ url: URL) throws -> FileOperationItemSnapshot? {
        var status = stat()
        let result = url.path.withCString { Darwin.lstat($0, &status) }
        guard result == 0 else {
            if errno == ENOENT || errno == ENOTDIR { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let itemType = status.st_mode & S_IFMT
        let isLink = itemType == S_IFLNK
        guard isLink || itemType == S_IFDIR else { return nil }
        let resolved = isLink
            ? url.resolvingSymlinksInPath().standardizedFileURL
            : url.standardizedFileURL
        return FileOperationItemSnapshot(
            kind: isLink ? .symbolicLink : .directory,
            resolvedURL: resolved,
            fingerprint: try treeFingerprint(url, isSymbolicLink: isLink)
        )
    }

    private static func treeFingerprint(_ url: URL, isSymbolicLink: Bool) throws -> String {
        var hash = SHA256()
        try appendFingerprint(url, relativePath: ".", knownSymbolicLink: isSymbolicLink, hash: &hash)
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func appendFingerprint(
        _ url: URL,
        relativePath: String,
        knownSymbolicLink: Bool? = nil,
        hash: inout SHA256
    ) throws {
        let values = try url.resourceValues(forKeys: [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .fileResourceIdentifierKey,
        ])
        let isLink = knownSymbolicLink ?? values.isSymbolicLink == true
        hash.update(data: Data(relativePath.utf8))
        if let identifier = values.fileResourceIdentifier {
            hash.update(data: Data(String(describing: identifier).utf8))
        }
        if isLink {
            hash.update(data: Data("link".utf8))
            hash.update(data: Data(try FileManager.default.destinationOfSymbolicLink(atPath: url.path).utf8))
            return
        }
        if values.isDirectory == true {
            hash.update(data: Data("directory".utf8))
            let children = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isSymbolicLinkKey],
                options: []
            ).sorted { $0.lastPathComponent < $1.lastPathComponent }
            for child in children {
                let childPath = relativePath == "."
                    ? child.lastPathComponent
                    : "\(relativePath)/\(child.lastPathComponent)"
                try appendFingerprint(child, relativePath: childPath, hash: &hash)
            }
            return
        }
        guard values.isRegularFile == true else {
            hash.update(data: Data("other".utf8))
            return
        }
        hash.update(data: Data("file".utf8))
        hash.update(data: Data(String(values.fileSize ?? -1).utf8))
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while let data = try handle.read(upToCount: 64 * 1024), !data.isEmpty {
            hash.update(data: data)
        }
    }
}

public final class SkillFileOperator: @unchecked Sendable {
    private let issuerID = UUID()
    private let registryProvider: () -> AgentRegistry
    private let authorizedRootsProvider: () -> [AuthorizedRootSnapshot]
    private let indexedAliasesProvider: () -> [IndexedSkillAlias]
    private let fileSystem: FileOperationFileSystem
    private let trash: any FileOperationTrashing
    private var issuedPlanIDs: Set<UUID> = []
    private let lock = NSLock()

    public convenience init(
        registryProvider: @escaping () -> AgentRegistry,
        authorizedRootsProvider: @escaping () -> [AuthorizedRootSnapshot],
        indexedAliasesProvider: @escaping () -> [IndexedSkillAlias]
    ) {
        self.init(
            registryProvider: registryProvider,
            authorizedRootsProvider: authorizedRootsProvider,
            indexedAliasesProvider: indexedAliasesProvider,
            fileSystem: .live,
            trash: MacOSTrash()
        )
    }

    public convenience init(
        registryProvider: @escaping () -> AgentRegistry,
        authorizedRootsProvider: @escaping () -> [AuthorizedRootSnapshot],
        indexedAliasesProvider: @escaping () -> [IndexedSkillAlias],
        trash: any FileOperationTrashing
    ) {
        self.init(
            registryProvider: registryProvider,
            authorizedRootsProvider: authorizedRootsProvider,
            indexedAliasesProvider: indexedAliasesProvider,
            fileSystem: .live,
            trash: trash
        )
    }

    init(
        registryProvider: @escaping () -> AgentRegistry,
        authorizedRootsProvider: @escaping () -> [AuthorizedRootSnapshot],
        indexedAliasesProvider: @escaping () -> [IndexedSkillAlias],
        fileSystem: FileOperationFileSystem,
        trash: any FileOperationTrashing
    ) {
        self.registryProvider = registryProvider
        self.authorizedRootsProvider = authorizedRootsProvider
        self.indexedAliasesProvider = indexedAliasesProvider
        self.fileSystem = fileSystem
        self.trash = trash
    }

    public func plan(_ request: FileOperationRequest) throws -> FileOperationPlan {
        let roots = authorizedRootsProvider()
        let registry = registryProvider()
        let source = request.sourceURL.standardizedFileURL
        let (sourceSnapshot, resolvedSource, sourceRootMatch) = try validatedSource(
            request,
            roots: roots,
            registry: registry
        )

        let destination: DestinationPlan?
        if request.operation == .delete {
            destination = nil
        } else {
            guard let destinationRoot = request.destinationRootURL else {
                throw SkillFileOperatorError.destinationRequired
            }
            destination = try planDestination(
                rootURL: destinationRoot,
                requestedName: request.proposedName ?? source.lastPathComponent,
                sourceEntryFilename: request.sourceEntryFilename,
                conflictPolicy: request.conflictPolicy,
                roots: roots,
                registry: registry,
                arbitrary: request.destinationIsArbitrary
            )
        }

        let sourceRoot = sourceRootMatch.root
        let link = linkPlan(
            operation: request.operation,
            sourceSnapshot: sourceSnapshot,
            resolvedSource: resolvedSource,
            sourceRoot: sourceRoot,
            destination: destination
        )
        let destinationSnapshot: FileOperationItemSnapshot?
        let destinationRootSnapshot: FileOperationItemSnapshot?
        if let destination {
            destinationSnapshot = try fileSystem.snapshot(destination.url)
            destinationRootSnapshot = try fileSystem.snapshot(
                destination.url.deletingLastPathComponent()
            )
        } else {
            destinationSnapshot = nil
            destinationRootSnapshot = nil
        }
        let replacement = request.conflictPolicy == .replace && destinationSnapshot != nil
        if request.operation == .move,
           destination?.url.path == source.path {
            throw SkillFileOperatorError.destinationConflict
        }
        let aliases = affectedAliases(
            operation: request.operation,
            source: source,
            resolvedSource: resolvedSource,
            destination: destination?.url,
            replacing: replacement,
            sourceIsLink: sourceSnapshot.kind == .symbolicLink
        )
        let confirmation = ConfirmationToken()
        let replacementConfirmation = replacement ? ConfirmationToken() : nil
        let plan = FileOperationPlan(
            id: UUID(),
            issuerID: issuerID,
            operation: request.operation,
            source: FileOperationPlan.Source(
                logicalURL: source,
                resolvedURL: resolvedSource,
                snapshot: sourceSnapshot
            ),
            destination: FileOperationPlan.Destination(
                rootURL: destination?.url.deletingLastPathComponent(),
                url: destination?.url,
                rootID: destination?.root?.id,
                agentIDs: destination?.agentIDs ?? [],
                rootSnapshot: destinationRootSnapshot,
                snapshot: destinationSnapshot
            ),
            entryFilename: destination?.entryFilename ?? request.sourceEntryFilename,
            authorizationSnapshotFingerprint: authorizationFingerprint(roots),
            registrySnapshotFingerprint: registryFingerprint(registry),
            conflictPolicy: request.conflictPolicy,
            hadDestinationConflict: destination?.hadConflict ?? false,
            movesExistingDestinationToTrash: replacement,
            linkForm: sourceSnapshot.kind == .symbolicLink ? .symbolicLink : .regularDirectory,
            linkTarget: link.target,
            linkTargetForm: link.form,
            affectedIndexedAliases: aliases.map(\.path).sorted(),
            affectedIndexedRootIDs: Array(Set(aliases.flatMap(\.rootIDs))).sorted(),
            confirmationToken: confirmation,
            replacementConfirmationToken: replacementConfirmation
        )
        lock.lock()
        issuedPlanIDs.insert(plan.id)
        lock.unlock()
        return plan
    }

    public func execute(
        _ plan: FileOperationPlan,
        confirmation: ConfirmationToken,
        replacementConfirmation: ConfirmationToken? = nil
    ) async throws -> FileOperationResult {
        guard plan.issuerID == issuerID, isIssued(plan.id) else {
            throw SkillFileOperatorError.invalidOrConsumedPlan
        }
        guard confirmation == plan.confirmationToken else {
            throw SkillFileOperatorError.invalidConfirmation
        }
        if let expectedReplacement = plan.replacementConfirmationToken {
            guard let replacementConfirmation else {
                throw SkillFileOperatorError.replacementConfirmationRequired
            }
            guard replacementConfirmation == expectedReplacement,
                  replacementConfirmation != confirmation else {
                throw SkillFileOperatorError.invalidReplacementConfirmation
            }
        }
        guard claim(plan.id) else {
            throw SkillFileOperatorError.invalidOrConsumedPlan
        }

        let roots = authorizedRootsProvider()
        guard authorizationFingerprint(roots) == plan.authorizationSnapshotFingerprint else {
            throw SkillFileOperatorError.authorizationChanged
        }
        let registry = registryProvider()
        guard registryFingerprint(registry) == plan.registrySnapshotFingerprint else {
            throw SkillFileOperatorError.registryChanged
        }
        guard let currentSource = try fileSystem.snapshot(plan.logicalSourceURL),
              currentSource == plan.sourceSnapshot else {
            throw SkillFileOperatorError.sourceChanged
        }
        guard isAuthorized(
            plan.logicalSourceURL,
            resolved: currentSource.resolvedURL,
            roots: roots
        ) else {
            throw SkillFileOperatorError.authorizationChanged
        }
        if let destinationRoot = plan.destinationRootURL {
            guard try fileSystem.snapshot(destinationRoot) == plan.destinationRootSnapshot else {
                throw SkillFileOperatorError.destinationChanged
            }
            // Arbitrary (user-picked) destinations have no registered root
            // identity; only registered destinations are re-validated.
            if let destinationRootID = plan.destinationRootID {
                let currentDestination = try validateRegisteredRoot(
                    destinationRoot,
                    entryFilename: plan.entryFilename,
                    roots: roots,
                    registry: registry
                )
                guard currentDestination.root.id == destinationRootID,
                      currentDestination.agentIDs == plan.destinationAgentIDs else {
                    throw SkillFileOperatorError.registryChanged
                }
            }
        }
        if let destinationURL = plan.destinationURL {
            let currentDestination = try fileSystem.snapshot(destinationURL)
            guard currentDestination == plan.destinationSnapshot else {
                throw SkillFileOperatorError.destinationChanged
            }
        }

        if plan.conflictPolicy == .cancel {
            return result(for: plan, outcome: .cancelled)
        }
        do {
            switch plan.operation {
            case .delete:
                try executeDelete(plan)
            case .copy:
                try executeCopy(plan, roots: roots)
            case .move:
                try executeMove(plan, roots: roots)
            case .createSymbolicLink:
                try executeLink(plan, roots: roots)
            }
        } catch let error as SkillFileOperatorError {
            throw error
        } catch {
            throw SkillFileOperatorError.filesystemFailure(String(describing: error))
        }
        return result(for: plan, outcome: .completed)
    }

    private func executeDelete(_ plan: FileOperationPlan) throws {
        try validateSourceSnapshot(plan.logicalSourceURL, expected: plan.sourceSnapshot)
        _ = try trash.trashItem(at: plan.logicalSourceURL)
    }

    private func executeCopy(_ plan: FileOperationPlan, roots: [AuthorizedRootSnapshot]) throws {
        try installCopy(from: plan.logicalSourceURL, plan: plan, removeSourceAfter: false, roots: roots)
    }

    private func executeMove(_ plan: FileOperationPlan, roots: [AuthorizedRootSnapshot]) throws {
        if plan.linkForm == .symbolicLink || plan.movesExistingDestinationToTrash {
            try installCopy(from: plan.logicalSourceURL, plan: plan, removeSourceAfter: true, roots: roots)
        } else {
            let destination = try requiredDestination(plan)
            try validateSourceSnapshot(plan.logicalSourceURL, expected: plan.sourceSnapshot)
            guard try fileSystem.snapshot(destination) == plan.destinationSnapshot else {
                throw SkillFileOperatorError.destinationChanged
            }
            try fileSystem.move(plan.logicalSourceURL, destination)
        }
    }

    private func executeLink(_ plan: FileOperationPlan, roots: [AuthorizedRootSnapshot]) throws {
        try installLink(plan: plan, roots: roots)
    }

    private struct DestinationPlan {
        let root: AuthorizedRootSnapshot?
        let url: URL
        let agentIDs: [String]
        let entryFilename: String
        let hadConflict: Bool
    }

    /// Validates that the requested source exists, resolves where the request
    /// expects, is authorized, and sits in a registered root. Returns the
    /// snapshot and match needed by the rest of planning.
    private func validatedSource(
        _ request: FileOperationRequest,
        roots: [AuthorizedRootSnapshot],
        registry: AgentRegistry
    ) throws -> (
        snapshot: FileOperationItemSnapshot,
        resolvedSource: URL,
        root: RegisteredRootMatch
    ) {
        let source = request.sourceURL.standardizedFileURL
        guard let sourceSnapshot = try fileSystem.snapshot(source) else {
            throw SkillFileOperatorError.sourceMissing
        }
        let resolvedSource = sourceSnapshot.resolvedURL.standardizedFileURL
        if let recorded = request.resolvedSourceURL,
           recorded.standardizedFileURL.path != resolvedSource.path {
            throw SkillFileOperatorError.resolvedSourceMismatch
        }
        guard isAuthorized(source, resolved: resolvedSource, roots: roots) else {
            throw SkillFileOperatorError.unauthorizedSource
        }
        let sourceRootMatch: RegisteredRootMatch
        do {
            sourceRootMatch = try validateRegisteredRoot(
                source.deletingLastPathComponent(),
                entryFilename: request.sourceEntryFilename,
                roots: roots,
                registry: registry
            )
        } catch SkillFileOperatorError.unregisteredDestination {
            throw SkillFileOperatorError.unregisteredSource
        } catch SkillFileOperatorError.unauthorizedDestination {
            throw SkillFileOperatorError.unregisteredSource
        }
        return (sourceSnapshot, resolvedSource, sourceRootMatch)
    }

    private func planDestination(
        rootURL: URL,
        requestedName: String,
        sourceEntryFilename: String,
        conflictPolicy: FileConflictPolicy,
        roots: [AuthorizedRootSnapshot],
        registry: AgentRegistry,
        arbitrary: Bool
    ) throws -> DestinationPlan {
        try validateName(requestedName)
        let match: RegisteredRootMatch?
        if arbitrary {
            // Any user-picked folder is a valid copy/move target; it does not
            // need to map through the Agent registry or an authorized root.
            match = nil
        } else {
            match = try validateRegisteredRoot(
                rootURL,
                entryFilename: sourceEntryFilename,
                roots: roots,
                registry: registry
            )
        }
        let targetRoot = match?.url ?? rootURL.standardizedFileURL
        let siblings = try fileSystem.contents(targetRoot)
        let normalized = Dictionary(grouping: siblings, by: { normalizedName($0.lastPathComponent) })
        var name = requestedName
        let conflict = normalized[normalizedName(name)]?.first
        if conflict != nil {
            switch conflictPolicy {
            case .fail:
                throw SkillFileOperatorError.destinationConflict
            case .cancel, .replace:
                name = conflict!.lastPathComponent
            case .keepBoth:
                var counter = 1
                repeat {
                    name = counter == 1 ? "\(requestedName) copy" : "\(requestedName) copy \(counter)"
                    counter += 1
                } while normalized[normalizedName(name)] != nil
            }
        }
        return DestinationPlan(
            root: match?.root,
            url: targetRoot.appending(path: name).standardizedFileURL,
            agentIDs: match?.agentIDs ?? [],
            entryFilename: match?.entryFilename ?? sourceEntryFilename,
            hadConflict: conflict != nil
        )
    }

    private struct RegisteredRootMatch {
        let root: AuthorizedRootSnapshot
        let url: URL
        let agentIDs: [String]
        let entryFilename: String
    }

    private func validateRegisteredRoot(
        _ candidateURL: URL,
        entryFilename: String,
        roots: [AuthorizedRootSnapshot],
        registry: AgentRegistry
    ) throws -> RegisteredRootMatch {
        let candidate = candidateURL.standardizedFileURL
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path == candidate.path else {
            throw SkillFileOperatorError.unauthorizedDestination
        }
        let authorizedRoots = matchingAuthorizedRoots(candidate, resolved: resolved, roots: roots)
        guard !authorizedRoots.isEmpty else {
            throw SkillFileOperatorError.unauthorizedDestination
        }

        for authorized in authorizedRoots {
            let declarations: [SkillRootDeclaration]
            switch authorized.kind {
            case .home:
                declarations = registry.globalDeclarations.filter {
                    matchesHomeRoot(candidate, declaration: $0.value, home: authorized.url)
                }
            case .project:
                declarations = registry.projectDeclarations.filter {
                    pathSuffix(candidate, relativeTo: authorized.url, matches: $0.value)
                }
            case .system, .custom:
                declarations = registry.globalDeclarations.filter {
                    guard $0.value.hasPrefix("/") else { return false }
                    return URL(fileURLWithPath: $0.value).standardizedFileURL.path == candidate.path
                }
                if declarations.isEmpty, candidate.path == authorized.url.standardizedFileURL.path {
                    return RegisteredRootMatch(
                        root: authorized,
                        url: candidate,
                        agentIDs: [authorized.kind == .system ? SyntheticAgentID.system : SyntheticAgentID.custom],
                        entryFilename: entryFilename
                    )
                }
            }
            guard !declarations.isEmpty else { continue }
            let sameEntry = declarations.filter { $0.entryFilename == entryFilename }
            let selected = sameEntry.isEmpty ? declarations : sameEntry
            return RegisteredRootMatch(
                root: authorized,
                url: candidate,
                agentIDs: Array(Set(selected.compactMap(\.agentID))).sorted(),
                entryFilename: selected.first?.entryFilename ?? entryFilename
            )
        }
        throw SkillFileOperatorError.unregisteredDestination
    }

    private func validateName(_ name: String) throws {
        guard EntryFilename.isValid(name),
              !name.hasPrefix(".skillselector-staging-") else {
            throw SkillFileOperatorError.invalidName(name)
        }
    }

    private func normalizedName(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.lowercased()
    }

    private func matchesHomeRoot(_ candidate: URL, declaration: String, home: URL) -> Bool {
        guard declaration.hasPrefix("~/") else { return false }
        let template = declaration.dropFirst(2).split(separator: "/").map(String.init)
        let homeComponents = home.standardizedFileURL.pathComponents
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        guard candidateComponents.count == homeComponents.count + template.count,
              Array(candidateComponents.prefix(homeComponents.count)) == homeComponents else {
            return false
        }
        return zip(candidateComponents.dropFirst(homeComponents.count), template).allSatisfy {
            TemplateMatching.segment($0.0, matches: $0.1)
        }
    }

    private func pathSuffix(_ candidate: URL, relativeTo project: URL, matches pattern: String) -> Bool {
        let projectComponents = project.standardizedFileURL.pathComponents
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        guard candidateComponents.count > projectComponents.count,
              Array(candidateComponents.prefix(projectComponents.count)) == projectComponents else {
            return false
        }
        let relative = Array(candidateComponents.dropFirst(projectComponents.count))
        let template = pattern.split(separator: "/").map(String.init)
        return TemplateMatching.suffix(relative, matches: template)
    }


    private func isAuthorized(
        _ logical: URL,
        resolved: URL,
        roots: [AuthorizedRootSnapshot]
    ) -> Bool {
        matchingLogicalAuthorizedRoot(logical, roots: roots) != nil
            && matchingResolvedAuthorizedRoot(resolved, roots: roots) != nil
    }

    private func matchingAuthorizedRoots(
        _ logical: URL,
        resolved: URL?,
        roots: [AuthorizedRootSnapshot]
    ) -> [AuthorizedRootSnapshot] {
        roots
            .filter { root in
                contains(logical.standardizedFileURL, in: root.url.standardizedFileURL)
                    && (resolved == nil || contains(
                        resolved!.standardizedFileURL,
                        in: root.url.resolvingSymlinksInPath().standardizedFileURL
                    ))
            }
            .sorted(by: mostSpecificRoot)
    }

    private func matchingLogicalAuthorizedRoot(
        _ logical: URL,
        roots: [AuthorizedRootSnapshot]
    ) -> AuthorizedRootSnapshot? {
        matchingAuthorizedRoots(logical, resolved: nil, roots: roots).first
    }

    private func matchingResolvedAuthorizedRoot(
        _ resolved: URL,
        roots: [AuthorizedRootSnapshot]
    ) -> AuthorizedRootSnapshot? {
        roots
            .filter { root in
                contains(
                    resolved.standardizedFileURL,
                    in: root.url.resolvingSymlinksInPath().standardizedFileURL
                )
            }
            .sorted(by: mostSpecificRoot)
            .first
    }

    private func mostSpecificRoot(
        _ lhs: AuthorizedRootSnapshot,
        _ rhs: AuthorizedRootSnapshot
    ) -> Bool {
        let lhsCount = lhs.url.standardizedFileURL.pathComponents.count
        let rhsCount = rhs.url.standardizedFileURL.pathComponents.count
        if lhsCount != rhsCount { return lhsCount > rhsCount }
        return lhs.id < rhs.id
    }

    private func contains(_ candidate: URL, in root: URL) -> Bool {
        candidate.isContained(in: root)
    }

    private func authorizationFingerprint(_ roots: [AuthorizedRootSnapshot]) -> String {
        roots.map {
            "\($0.id)\u{1f}\($0.kind.rawValue)\u{1f}\($0.url.standardizedFileURL.path)\u{1f}\($0.url.resolvingSymlinksInPath().standardizedFileURL.path)"
        }.sorted().joined(separator: "\u{1e}")
    }

    private func registryFingerprint(_ registry: AgentRegistry) -> String {
        let definitionRecords = registry.definitions.map { definition in
            [
                definition.id,
                definition.displayName,
                definition.globalRoots.joined(separator: "\u{1d}"),
                definition.projectPatterns.joined(separator: "\u{1d}"),
                definition.entryFilename,
                String(definition.isLegacy),
            ].joined(separator: "\u{1f}")
        }
        let declarations = registry.globalDeclarations.map {
            "global\u{1f}\($0.value)\u{1f}\($0.entryFilename)\u{1f}\($0.agentID ?? "")"
        } + registry.projectDeclarations.map {
            "project\u{1f}\($0.value)\u{1f}\($0.entryFilename)\u{1f}\($0.agentID ?? "")"
        }
        return (definitionRecords + declarations).sorted().joined(separator: "\u{1e}")
    }

    private func linkPlan(
        operation: FileOperationKind,
        sourceSnapshot: FileOperationItemSnapshot,
        resolvedSource: URL,
        sourceRoot: AuthorizedRootSnapshot?,
        destination: DestinationPlan?
    ) -> (target: String?, form: LinkTargetForm?) {
        guard operation == .createSymbolicLink || sourceSnapshot.kind == .symbolicLink,
              let destination else {
            return (nil, nil)
        }
        if sourceRoot?.kind == .project,
           destination.root?.kind == .project,
           sourceRoot?.id == destination.root?.id {
            return (relativePath(from: destination.url.deletingLastPathComponent(), to: resolvedSource), .relative)
        }
        return (resolvedSource.path, .absolute)
    }

    private func relativePath(from base: URL, to target: URL) -> String {
        let baseComponents = base.standardizedFileURL.pathComponents
        let targetComponents = target.standardizedFileURL.pathComponents
        var common = 0
        while common < min(baseComponents.count, targetComponents.count),
              baseComponents[common] == targetComponents[common] {
            common += 1
        }
        return Array(repeating: "..", count: baseComponents.count - common)
            .appending(contentsOf: targetComponents.dropFirst(common))
            .joined(separator: "/")
    }

    private func affectedAliases(
        operation: FileOperationKind,
        source: URL,
        resolvedSource: URL,
        destination: URL?,
        replacing: Bool,
        sourceIsLink: Bool
    ) -> [IndexedSkillAlias] {
        let indexed = indexedAliasesProvider()
        var aliases: Set<IndexedSkillAlias> = []
        if sourceIsLink && (operation == .delete || operation == .move) {
            aliases.formUnion(indexed.filter { $0.path == source.path })
            if !aliases.contains(where: { $0.path == source.path }) {
                aliases.insert(IndexedSkillAlias(path: source.path, resolvedTarget: resolvedSource.path))
            }
        } else if operation == .delete || operation == .move {
            for alias in indexed where alias.path == source.path || alias.resolvedTarget == resolvedSource.path {
                aliases.insert(alias)
            }
        }
        if replacing, let destination {
            for alias in indexed where alias.path == destination.path || alias.resolvedTarget == destination.path {
                aliases.insert(alias)
            }
        }
        return Array(aliases)
    }

    private func installCopy(
        from source: URL,
        plan: FileOperationPlan,
        removeSourceAfter: Bool,
        roots: [AuthorizedRootSnapshot]
    ) throws {
        let destination = try requiredDestination(plan)
        let stage = stagingURL(beside: destination)
        defer { try? fileSystem.remove(stage) }
        if plan.linkForm == .symbolicLink {
            guard let target = plan.linkTarget else {
                throw SkillFileOperatorError.invalidStagedSkill
            }
            try validateSourceSnapshot(source, expected: plan.sourceSnapshot)
            try fileSystem.createSymbolicLink(stage, target)
        } else {
            try validateSourceSnapshot(source, expected: plan.sourceSnapshot)
            try fileSystem.copy(source, stage)
        }
        // The operation contract requires the source to be unchanged from plan
        // time through installation. Stage validation reads the stage, so the
        // source is re-checked afterwards to close the window where a
        // concurrent source modification could slip in before the stage is
        // installed; the removeSourceAfter path re-validates again before
        // deleting.
        try validateSourceSnapshot(source, expected: plan.sourceSnapshot)
        try validateStagedSkill(stage, plan: plan, roots: roots)
        try validateSourceSnapshot(source, expected: plan.sourceSnapshot)
        let trashedDestination = try replaceDestinationIfNeeded(plan: plan, stage: stage)
        if removeSourceAfter {
            do {
                try validateSourceSnapshot(source, expected: plan.sourceSnapshot)
                try fileSystem.remove(source)
            } catch let originalError {
                do {
                    try fileSystem.remove(destination)
                    if let trashedDestination {
                        try fileSystem.move(trashedDestination, destination)
                    }
                } catch let rollbackError {
                    throw SkillFileOperatorError.rollbackFailed(
                        original: String(describing: originalError),
                        rollback: String(describing: rollbackError)
                    )
                }
                throw originalError
            }
        }
    }

    private func installLink(plan: FileOperationPlan, roots: [AuthorizedRootSnapshot]) throws {
        let destination = try requiredDestination(plan)
        let stage = stagingURL(beside: destination)
        defer { try? fileSystem.remove(stage) }
        guard let target = plan.linkTarget else {
            throw SkillFileOperatorError.invalidStagedSkill
        }
        try validateSourceSnapshot(plan.logicalSourceURL, expected: plan.sourceSnapshot)
        try fileSystem.createSymbolicLink(stage, target)
        // The stage link is validated by reading through it; the source is
        // re-checked before and after that read so the installation can only
        // proceed while the source matches the planned state.
        try validateSourceSnapshot(plan.logicalSourceURL, expected: plan.sourceSnapshot)
        try validateStagedSkill(stage, plan: plan, roots: roots)
        try validateSourceSnapshot(plan.logicalSourceURL, expected: plan.sourceSnapshot)
        _ = try replaceDestinationIfNeeded(plan: plan, stage: stage)
    }

    private func validateSourceSnapshot(
        _ source: URL,
        expected: FileOperationItemSnapshot
    ) throws {
        guard try fileSystem.snapshot(source) == expected else {
            throw SkillFileOperatorError.sourceChanged
        }
    }

    private func validateStagedSkill(
        _ stage: URL,
        plan: FileOperationPlan,
        roots: [AuthorizedRootSnapshot]
    ) throws {
        let snapshot = try fileSystem.snapshot(stage)
        guard let snapshot else { throw SkillFileOperatorError.invalidStagedSkill }
        // Arbitrary destinations are user-picked folders: the staged copy is
        // validated against that folder instead of the authorized roots.
        var authorizedRootURLs = roots.map(\.url)
        if plan.destinationRootID == nil, let destinationRoot = plan.destinationRootURL {
            authorizedRootURLs.append(destinationRoot)
        }
        let request = SkillDocumentRequest(
            installationURL: stage,
            resolvedTargetURL: snapshot.kind == .symbolicLink ? snapshot.resolvedURL : nil,
            entryFilename: plan.entryFilename,
            authorizedRootURLs: authorizedRootURLs
        )
        do {
            _ = try SkillDocumentReader().validatedEntryURL(request)
        } catch {
            throw SkillFileOperatorError.invalidStagedSkill
        }
    }

    @discardableResult
    private func replaceDestinationIfNeeded(plan: FileOperationPlan, stage: URL) throws -> URL? {
        let destination = try requiredDestination(plan)
        guard try fileSystem.snapshot(destination) == plan.destinationSnapshot else {
            throw SkillFileOperatorError.destinationChanged
        }
        var trashedDestination: URL?
        if plan.movesExistingDestinationToTrash {
            trashedDestination = try trash.trashItem(at: destination)
        }
        do {
            try fileSystem.move(stage, destination)
        } catch {
            if let trashedDestination {
                do {
                    try fileSystem.move(trashedDestination, destination)
                } catch let rollbackError {
                    throw SkillFileOperatorError.rollbackFailed(
                        original: String(describing: error),
                        rollback: String(describing: rollbackError)
                    )
                }
            }
            throw error
        }
        return trashedDestination
    }

    private func stagingURL(beside destination: URL) -> URL {
        destination.deletingLastPathComponent()
            .appending(path: ".skillselector-staging-\(UUID().uuidString)")
    }

    private func requiredDestination(_ plan: FileOperationPlan) throws -> URL {
        guard let destination = plan.destinationURL else {
            throw SkillFileOperatorError.destinationRequired
        }
        return destination
    }

    private func isIssued(_ id: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return issuedPlanIDs.contains(id)
    }

    private func claim(_ id: UUID) -> Bool {
        lock.lock()
        let wasIssued = issuedPlanIDs.remove(id) != nil
        lock.unlock()
        return wasIssued
    }

    private func result(for plan: FileOperationPlan, outcome: FileOperationOutcome) -> FileOperationResult {
        let rootIDs = Set([
            plan.destinationRootID,
            matchingLogicalAuthorizedRoot(
                plan.logicalSourceURL,
                roots: authorizedRootsProvider()
            )?.id,
            matchingResolvedAuthorizedRoot(
                plan.resolvedSourceURL,
                roots: authorizedRootsProvider()
            )?.id,
        ].compactMap { $0 }).union(plan.affectedIndexedRootIDs)
        return FileOperationResult(
            outcome: outcome,
            sourceURL: plan.logicalSourceURL,
            destinationURL: plan.destinationURL,
            refreshRootIDs: rootIDs.sorted()
        )
    }
}

private extension Array {
    func appending<S: Sequence>(contentsOf elements: S) -> [Element] where S.Element == Element {
        self + elements
    }
}
