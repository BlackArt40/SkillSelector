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
        var hash = FNV1a64()
        try appendFingerprint(url, relativePath: ".", knownSymbolicLink: isSymbolicLink, hash: &hash)
        return String(format: "%016llx", hash.value)
    }

    private static func appendFingerprint(
        _ url: URL,
        relativePath: String,
        knownSymbolicLink: Bool? = nil,
        hash: inout FNV1a64
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
        hash.append(relativePath)
        if let identifier = values.fileResourceIdentifier {
            hash.append(String(describing: identifier))
        }
        if isLink {
            hash.append("link")
            hash.append(try FileManager.default.destinationOfSymbolicLink(atPath: url.path))
            return
        }
        if values.isDirectory == true {
            hash.append("directory")
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
            hash.append("other")
            return
        }
        hash.append("file")
        hash.append(String(values.fileSize ?? -1))
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while let data = try handle.read(upToCount: 64 * 1024), !data.isEmpty {
            hash.append(data)
        }
    }
}

private struct FNV1a64 {
    private(set) var value: UInt64 = 14_695_981_039_346_656_037

    mutating func append(_ string: String) {
        append(Data(string.utf8))
    }

    mutating func append(_ data: Data) {
        for byte in data {
            value ^= UInt64(byte)
            value &*= 1_099_511_628_211
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
        do {
            _ = try validateRegisteredRoot(
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
                registry: registry
            )
        }

        let sourceRoot = matchingResolvedAuthorizedRoot(resolvedSource, roots: roots)
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
        let aliases = affectedAliases(
            operation: request.operation,
            source: source,
            resolvedSource: resolvedSource,
            destination: destination?.url,
            replacing: replacement,
            sourceIsLink: sourceSnapshot.kind == .symbolicLink
        )
        let metadataTransfer: FileOperationMetadataTransfer = switch request.operation {
        case .copy: .copy(request.metadata)
        case .move: .move(request.metadata)
        case .delete, .createSymbolicLink: .none
        }
        let confirmation = ConfirmationToken()
        let replacementConfirmation = replacement ? ConfirmationToken() : nil
        let usesStaging = request.operation == .copy
            || request.operation == .createSymbolicLink
            || replacement
            || (request.operation == .move && sourceSnapshot.kind == .symbolicLink)
        let plan = FileOperationPlan(
            id: UUID(),
            issuerID: issuerID,
            operation: request.operation,
            logicalSourceURL: source,
            resolvedSourceURL: resolvedSource,
            destinationRootURL: destination?.url.deletingLastPathComponent(),
            destinationURL: destination?.url,
            destinationRootID: destination?.root.id,
            destinationAgentIDs: destination?.agentIDs ?? [],
            entryFilename: destination?.entryFilename ?? request.sourceEntryFilename,
            authorizationSnapshotFingerprint: authorizationFingerprint(roots),
            registrySnapshotFingerprint: registryFingerprint(registry),
            conflictPolicy: request.conflictPolicy,
            hadDestinationConflict: destination?.hadConflict ?? false,
            stagingBehavior: usesStaging ? .validateBesideDestination : .none,
            movesExistingDestinationToTrash: replacement,
            linkForm: sourceSnapshot.kind == .symbolicLink ? .symbolicLink : .regularDirectory,
            linkTarget: link.target,
            linkTargetForm: link.form,
            affectedIndexedAliases: aliases.map(\.path).sorted(),
            affectedIndexedRootIDs: Array(Set(aliases.flatMap(\.rootIDs))).sorted(),
            metadataTransfer: metadataTransfer,
            confirmationToken: confirmation,
            replacementConfirmationToken: replacementConfirmation,
            sourceSnapshot: sourceSnapshot,
            destinationRootSnapshot: destinationRootSnapshot,
            destinationSnapshot: destinationSnapshot
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
            let currentDestination = try validateRegisteredRoot(
                destinationRoot,
                entryFilename: plan.entryFilename,
                roots: roots,
                registry: registry
            )
            guard currentDestination.root.id == plan.destinationRootID,
                  currentDestination.agentIDs == plan.destinationAgentIDs else {
                throw SkillFileOperatorError.registryChanged
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
                _ = try trash.trashItem(at: plan.logicalSourceURL)
            case .copy:
                try installCopy(from: plan.logicalSourceURL, plan: plan, removeSourceAfter: false, roots: roots)
            case .move:
                if plan.linkForm == .symbolicLink || plan.movesExistingDestinationToTrash {
                    try installCopy(from: plan.logicalSourceURL, plan: plan, removeSourceAfter: true, roots: roots)
                } else {
                    try fileSystem.move(
                        plan.logicalSourceURL,
                        try requiredDestination(plan)
                    )
                }
            case .createSymbolicLink:
                try installLink(plan: plan, roots: roots)
            }
        } catch let error as SkillFileOperatorError {
            throw error
        } catch {
            throw SkillFileOperatorError.filesystemFailure(String(describing: error))
        }
        return result(for: plan, outcome: .completed)
    }

    private struct DestinationPlan {
        let root: AuthorizedRootSnapshot
        let url: URL
        let agentIDs: [String]
        let entryFilename: String
        let hadConflict: Bool
    }

    private func planDestination(
        rootURL: URL,
        requestedName: String,
        sourceEntryFilename: String,
        conflictPolicy: FileConflictPolicy,
        roots: [AuthorizedRootSnapshot],
        registry: AgentRegistry
    ) throws -> DestinationPlan {
        try validateName(requestedName)
        let match = try validateRegisteredRoot(
            rootURL,
            entryFilename: sourceEntryFilename,
            roots: roots,
            registry: registry
        )
        let siblings = try fileSystem.contents(match.url)
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
            root: match.root,
            url: match.url.appending(path: name).standardizedFileURL,
            agentIDs: match.agentIDs,
            entryFilename: match.entryFilename,
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
        guard let authorized = matchingAuthorizedRoot(candidate, resolved: resolved, roots: roots) else {
            throw SkillFileOperatorError.unauthorizedDestination
        }
        guard resolved.path == candidate.path else {
            throw SkillFileOperatorError.unauthorizedDestination
        }

        let definitions: [AgentDefinition]
        switch authorized.kind {
        case .home:
            definitions = registry.definitions.filter { definition in
                definition.globalRoots.contains { globalRoot in
                    matchesHomeRoot(candidate, declaration: globalRoot, home: authorized.url)
                }
            }
        case .project:
            definitions = registry.definitions.filter { definition in
                definition.projectPatterns.contains { pattern in
                    pathSuffix(candidate, relativeTo: authorized.url, matches: pattern)
                }
            }
        case .system, .custom:
            definitions = registry.definitions.filter { definition in
                definition.globalRoots.contains { declaration in
                    guard declaration.hasPrefix("/") else { return false }
                    return URL(fileURLWithPath: declaration).standardizedFileURL.path == candidate.path
                }
            }
            if definitions.isEmpty, candidate.path == authorized.url.standardizedFileURL.path {
                return RegisteredRootMatch(
                    root: authorized,
                    url: candidate,
                    agentIDs: [authorized.kind == .system ? "system" : "custom"],
                    entryFilename: entryFilename
                )
            }
        }
        guard !definitions.isEmpty else {
            throw SkillFileOperatorError.unregisteredDestination
        }
        let sameEntry = definitions.filter { $0.entryFilename == entryFilename }
        let selected = sameEntry.isEmpty ? definitions : sameEntry
        return RegisteredRootMatch(
            root: authorized,
            url: candidate,
            agentIDs: selected.map(\.id).sorted(),
            entryFilename: selected.first?.entryFilename ?? entryFilename
        )
    }

    private func validateName(_ name: String) throws {
        guard !name.isEmpty,
              name != ".",
              name != "..",
              !name.contains("/"),
              !name.contains("\\"),
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
            segment($0.0, matches: $0.1)
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
        guard relative.count >= template.count else { return false }
        return zip(relative.suffix(template.count), template).allSatisfy {
            segment($0.0, matches: $0.1)
        }
    }

    private func segment(_ value: String, matches template: String) -> Bool {
        guard let opening = template.firstIndex(of: "{"),
              let closing = template[opening...].firstIndex(of: "}") else {
            return value == template
        }
        let prefix = template[..<opening]
        let suffix = template[template.index(after: closing)...]
        return value.hasPrefix(prefix)
            && value.hasSuffix(suffix)
            && value.count > prefix.count + suffix.count
    }

    private func isAuthorized(
        _ logical: URL,
        resolved: URL,
        roots: [AuthorizedRootSnapshot]
    ) -> Bool {
        matchingLogicalAuthorizedRoot(logical, roots: roots) != nil
            && matchingResolvedAuthorizedRoot(resolved, roots: roots) != nil
    }

    private func matchingLogicalAuthorizedRoot(
        _ logical: URL,
        roots: [AuthorizedRootSnapshot]
    ) -> AuthorizedRootSnapshot? {
        roots.first { root in
            contains(logical.standardizedFileURL, in: root.url.standardizedFileURL)
        }
    }

    private func matchingResolvedAuthorizedRoot(
        _ resolved: URL,
        roots: [AuthorizedRootSnapshot]
    ) -> AuthorizedRootSnapshot? {
        roots.first { root in
            contains(
                resolved.standardizedFileURL,
                in: root.url.resolvingSymlinksInPath().standardizedFileURL
            )
        }
    }

    private func matchingAuthorizedRoot(
        _ logical: URL,
        resolved: URL,
        roots: [AuthorizedRootSnapshot]
    ) -> AuthorizedRootSnapshot? {
        roots.first { root in
            contains(logical.standardizedFileURL, in: root.url.standardizedFileURL)
                && contains(
                    resolved.standardizedFileURL,
                    in: root.url.resolvingSymlinksInPath().standardizedFileURL
                )
        }
    }

    private func contains(_ candidate: URL, in root: URL) -> Bool {
        let candidateComponents = candidate.pathComponents
        let rootComponents = root.pathComponents
        return candidateComponents.count >= rootComponents.count
            && Array(candidateComponents.prefix(rootComponents.count)) == rootComponents
    }

    private func authorizationFingerprint(_ roots: [AuthorizedRootSnapshot]) -> String {
        roots.map {
            "\($0.id)\u{1f}\($0.kind.rawValue)\u{1f}\($0.url.standardizedFileURL.path)\u{1f}\($0.url.resolvingSymlinksInPath().standardizedFileURL.path)"
        }.sorted().joined(separator: "\u{1e}")
    }

    private func registryFingerprint(_ registry: AgentRegistry) -> String {
        registry.definitions.map { definition in
            [
                definition.id,
                definition.displayName,
                definition.globalRoots.joined(separator: "\u{1d}"),
                definition.projectPatterns.joined(separator: "\u{1d}"),
                definition.entryFilename,
                String(definition.isLegacy),
            ].joined(separator: "\u{1f}")
        }.sorted().joined(separator: "\u{1e}")
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
           destination.root.kind == .project,
           sourceRoot?.id == destination.root.id {
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
            try fileSystem.createSymbolicLink(stage, target)
        } else {
            try fileSystem.copy(source, stage)
        }
        try validateStagedSkill(stage, plan: plan, roots: roots)
        let trashedDestination = try replaceDestinationIfNeeded(plan: plan, stage: stage)
        if removeSourceAfter {
            do {
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
        try fileSystem.createSymbolicLink(stage, target)
        try validateStagedSkill(stage, plan: plan, roots: roots)
        _ = try replaceDestinationIfNeeded(plan: plan, stage: stage)
    }

    private func validateStagedSkill(
        _ stage: URL,
        plan: FileOperationPlan,
        roots: [AuthorizedRootSnapshot]
    ) throws {
        let snapshot = try fileSystem.snapshot(stage)
        guard let snapshot else { throw SkillFileOperatorError.invalidStagedSkill }
        let request = SkillDocumentRequest(
            installationURL: stage,
            resolvedTargetURL: snapshot.kind == .symbolicLink ? snapshot.resolvedURL : nil,
            entryFilename: plan.entryFilename,
            authorizedRootURLs: roots.map(\.url)
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
            refreshRootIDs: rootIDs.sorted(),
            metadataTransfer: plan.metadataTransfer
        )
    }
}

private extension Array {
    func appending<S: Sequence>(contentsOf elements: S) -> [Element] where S.Element == Element {
        self + elements
    }
}
