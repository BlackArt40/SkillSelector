import Foundation

public enum SkillUpdateError: Error, Equatable, Sendable {
    case unsupportedSource
    case unauthorizedInstallation
    case resolvedTargetMismatch
    case commandFailed(status: Int32)
    case invalidRemoteResponse
    case truncatedRepositoryTree
    case remotePackageTooLarge
    case alreadyUpToDate
    case proposalExpired
    case proposalAlreadyConsumed
    case stagedPackageChanged
}

public enum UpdateChangeKind: String, Codable, Hashable, Sendable {
    case added
    case changed
    case deleted
}

public struct UpdateFileChange: Codable, Hashable, Sendable {
    public let path: String
    public let kind: UpdateChangeKind

    public init(path: String, kind: UpdateChangeKind) {
        self.path = path
        self.kind = kind
    }
}

public struct UpdateRequest: Hashable, Sendable {
    public let installationURL: URL
    public let resolvedTargetURL: URL?
    public let entryFilename: String
    public let requiredName: String
    public let source: SkillSource
    public let indexedDigest: PackageDigest
    public let authorizedRootURLs: [URL]
    public let refreshRootIDs: [String]

    public init(
        installationURL: URL,
        resolvedTargetURL: URL? = nil,
        entryFilename: String,
        requiredName: String,
        source: SkillSource,
        indexedDigest: PackageDigest,
        authorizedRootURLs: [URL],
        refreshRootIDs: [String] = []
    ) {
        self.installationURL = installationURL.standardizedFileURL
        self.resolvedTargetURL = resolvedTargetURL?.standardizedFileURL
        self.entryFilename = entryFilename
        self.requiredName = requiredName
        self.source = source
        self.indexedDigest = indexedDigest
        self.authorizedRootURLs = authorizedRootURLs.map(\.standardizedFileURL)
        self.refreshRootIDs = Array(Set(refreshRootIDs)).sorted()
    }
}

public struct UpdateProposal: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let source: SkillSource
    public let resolvedReference: String?
    public let baselineDigest: PackageDigest
    public let localDigestAtCheck: PackageDigest
    public let remoteDigest: PackageDigest
    public let changes: [UpdateFileChange]
    public let actualTargetURL: URL
    public let affectedAliases: [IndexedSkillAlias]
    public let isPinned: Bool
    public let hasIndexedLocalChanges: Bool
    public let isConfirmed: Bool
    public let allowsLocalChanges: Bool

    let request: UpdateRequest
    let packageURL: URL
    let packageManifest: [PackageManifestEntry]

    public func confirmed(allowLocalChanges: Bool = false) -> UpdateProposal {
        UpdateProposal(
            id: id,
            source: source,
            resolvedReference: resolvedReference,
            baselineDigest: baselineDigest,
            localDigestAtCheck: localDigestAtCheck,
            remoteDigest: remoteDigest,
            changes: changes,
            actualTargetURL: actualTargetURL,
            affectedAliases: affectedAliases,
            isPinned: isPinned,
            hasIndexedLocalChanges: hasIndexedLocalChanges,
            isConfirmed: true,
            allowsLocalChanges: allowLocalChanges,
            request: request,
            packageURL: packageURL,
            packageManifest: packageManifest
        )
    }
}

public enum UpdateResult: Hashable, Sendable {
    case confirmationRequired
    case localChangesRequireConfirmation(UpdateProposal)
    case updated(digest: PackageDigest, refreshRootIDs: [String])

    public var affectedRootIDs: [String] {
        guard case .updated(_, let rootIDs) = self else { return [] }
        return rootIDs
    }
}

public enum UpdateCheckResult: Hashable, Sendable {
    case updateAvailable(UpdateProposal)
    case upToDate
}

public struct FetchedSkillPackage: Hashable, Sendable {
    public let packageURL: URL
    public let resolvedReference: String?

    public init(packageURL: URL, resolvedReference: String? = nil) {
        self.packageURL = packageURL.standardizedFileURL
        self.resolvedReference = resolvedReference
    }
}

public protocol SkillPackageFetching: Sendable {
    func fetch(_ source: SkillSource, into destination: URL) async throws -> FetchedSkillPackage
    func fetch(
        _ source: SkillSource,
        into destination: URL,
        entryFilename: String
    ) async throws -> FetchedSkillPackage
}

public extension SkillPackageFetching {
    func fetch(
        _ source: SkillSource,
        into destination: URL,
        entryFilename: String
    ) async throws -> FetchedSkillPackage {
        try await fetch(source, into: destination)
    }
}

public protocol SkillPackageReplacing: Sendable {
    func replace(
        target: URL,
        with package: URL,
        expectedTargetDigest: PackageDigest,
        entryFilename: String,
        authorizedRootURLs: [URL]
    ) async throws
}

public final class SkillUpdater: @unchecked Sendable {
    private struct IssuedProposal {
        let proposal: UpdateProposal
        let temporaryDirectory: URL
    }

    private let fetcher: any SkillPackageFetching
    private let validator: PackageValidator
    private let replacer: any SkillPackageReplacing
    private let aliasesProvider: @Sendable () -> [IndexedSkillAlias]
    private let refresh: @Sendable ([String]) async throws -> Void
    private let lock = NSLock()
    private var proposals: [UUID: IssuedProposal] = [:]

    public convenience init(
        ghExecutableURL: URL,
        runner: any CommandRunning = ExternalCommandRunner(),
        aliasesProvider: @escaping @Sendable () -> [IndexedSkillAlias] = { [] },
        refresh: @escaping @Sendable ([String]) async throws -> Void = { _ in }
    ) {
        self.init(
            fetcher: LiveSkillPackageFetcher(executableURL: ghExecutableURL, runner: runner),
            aliasesProvider: aliasesProvider,
            refresh: refresh
        )
    }

    public init(
        fetcher: any SkillPackageFetching,
        validator: PackageValidator = PackageValidator(),
        replacer: any SkillPackageReplacing = SkillFileOperatorPackageReplacer(),
        aliasesProvider: @escaping @Sendable () -> [IndexedSkillAlias] = { [] },
        refresh: @escaping @Sendable ([String]) async throws -> Void = { _ in }
    ) {
        self.fetcher = fetcher
        self.validator = validator
        self.replacer = replacer
        self.aliasesProvider = aliasesProvider
        self.refresh = refresh
    }

    deinit {
        let directories = lock.withLock { proposals.values.map(\.temporaryDirectory) }
        directories.forEach { try? FileManager.default.removeItem(at: $0) }
    }

    public func check(_ request: UpdateRequest) async throws -> UpdateProposal {
        switch try await checkResult(request) {
        case .updateAvailable(let proposal): return proposal
        case .upToDate: throw SkillUpdateError.alreadyUpToDate
        }
    }

    public func checkResult(_ request: UpdateRequest) async throws -> UpdateCheckResult {
        let actualTarget = try validatedTarget(for: request)
        let localDigest = try PackageDigest.compute(at: actualTarget)
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appending(path: "SkillSelector-Update-\(UUID().uuidString)")
        let packageDestination = temporaryDirectory.appending(path: "package")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        do {
            let fetched = try await fetcher.fetch(
                request.source,
                into: packageDestination,
                entryFilename: request.entryFilename
            )
            let validated = try PackageValidator(
                limits: validator.limits,
                entryFilename: request.entryFilename
            ).validate(fetched.packageURL, requiredName: request.requiredName)
            let remoteManifest = try PackageManifest.read(at: validated.packageURL)
            let localManifest = try PackageManifest.read(at: actualTarget)
            guard validated.digest != localDigest else {
                try? FileManager.default.removeItem(at: temporaryDirectory)
                return .upToDate
            }
            let proposal = UpdateProposal(
                id: UUID(),
                source: request.source,
                resolvedReference: fetched.resolvedReference,
                baselineDigest: request.indexedDigest,
                localDigestAtCheck: localDigest,
                remoteDigest: validated.digest,
                changes: Self.diff(local: localManifest, remote: remoteManifest),
                actualTargetURL: actualTarget,
                affectedAliases: affectedAliases(for: request, target: actualTarget),
                isPinned: request.source.reference?.isPinned ?? true,
                hasIndexedLocalChanges: localDigest != request.indexedDigest,
                isConfirmed: false,
                allowsLocalChanges: false,
                request: request,
                packageURL: validated.packageURL,
                packageManifest: remoteManifest
            )
            lock.withLock {
                proposals[proposal.id] = IssuedProposal(
                    proposal: proposal,
                    temporaryDirectory: temporaryDirectory
                )
            }
            return .updateAvailable(proposal)
        } catch {
            try? FileManager.default.removeItem(at: temporaryDirectory)
            throw error
        }
    }

    public func apply(_ proposal: UpdateProposal) async throws -> UpdateResult {
        guard proposal.isConfirmed else { return .confirmationRequired }
        guard let issued = lock.withLock({ proposals.removeValue(forKey: proposal.id) }) else {
            throw SkillUpdateError.proposalAlreadyConsumed
        }
        var retainsTemporaryDirectory = false
        defer {
            if !retainsTemporaryDirectory {
                try? FileManager.default.removeItem(at: issued.temporaryDirectory)
            }
        }
        let currentDigest = try PackageDigest.compute(at: proposal.actualTargetURL)
        if (currentDigest != proposal.baselineDigest || proposal.hasIndexedLocalChanges),
           !proposal.allowsLocalChanges {
            retainsTemporaryDirectory = true
            let warning = reissue(proposal, issued: issued, localDigest: currentDigest)
            return .localChangesRequireConfirmation(warning)
        }
        guard try PackageManifest.read(at: proposal.packageURL) == proposal.packageManifest,
              try PackageDigest.compute(at: proposal.packageURL) == proposal.remoteDigest else {
            throw SkillUpdateError.stagedPackageChanged
        }
        try await replacer.replace(
            target: proposal.actualTargetURL,
            with: proposal.packageURL,
            expectedTargetDigest: currentDigest,
            entryFilename: proposal.request.entryFilename,
            authorizedRootURLs: proposal.request.authorizedRootURLs
        )
        let refreshRootIDs = Set(proposal.request.refreshRootIDs)
            .union(proposal.affectedAliases.flatMap(\.rootIDs))
            .sorted()
        try await refresh(refreshRootIDs)
        return .updated(digest: proposal.remoteDigest, refreshRootIDs: refreshRootIDs)
    }

    private func reissue(
        _ proposal: UpdateProposal,
        issued: IssuedProposal,
        localDigest: PackageDigest
    ) -> UpdateProposal {
        let warning = UpdateProposal(
            id: UUID(),
            source: proposal.source,
            resolvedReference: proposal.resolvedReference,
            baselineDigest: proposal.baselineDigest,
            localDigestAtCheck: localDigest,
            remoteDigest: proposal.remoteDigest,
            changes: proposal.changes,
            actualTargetURL: proposal.actualTargetURL,
            affectedAliases: proposal.affectedAliases,
            isPinned: proposal.isPinned,
            hasIndexedLocalChanges: true,
            isConfirmed: false,
            allowsLocalChanges: false,
            request: proposal.request,
            packageURL: proposal.packageURL,
            packageManifest: proposal.packageManifest
        )
        lock.withLock {
            proposals[warning.id] = IssuedProposal(
                proposal: warning,
                temporaryDirectory: issued.temporaryDirectory
            )
        }
        return warning
    }

    private func validatedTarget(for request: UpdateRequest) throws -> URL {
        let logical = request.installationURL.standardizedFileURL
        let resolved = logical.resolvingSymlinksInPath().standardizedFileURL
        if let expected = request.resolvedTargetURL,
           expected.standardizedFileURL.path != resolved.path {
            throw SkillUpdateError.resolvedTargetMismatch
        }
        let target = request.resolvedTargetURL?.standardizedFileURL ?? resolved
        guard covered(logical, by: request.authorizedRootURLs),
              covered(target, by: request.authorizedRootURLs) else {
            throw SkillUpdateError.unauthorizedInstallation
        }
        return target
    }

    private func affectedAliases(for request: UpdateRequest, target: URL) -> [IndexedSkillAlias] {
        var aliases = Set(aliasesProvider().filter {
            $0.resolvedTarget.map { URL(fileURLWithPath: $0).standardizedFileURL.path } == target.path
        })
        if request.resolvedTargetURL != nil,
           !aliases.contains(where: { $0.path == request.installationURL.path }) {
            aliases.insert(IndexedSkillAlias(
                path: request.installationURL.path,
                resolvedTarget: target.path
            ))
        }
        return aliases.sorted { $0.path < $1.path }
    }

    private func covered(_ candidate: URL, by roots: [URL]) -> Bool {
        candidate.standardizedFileURL.isContained(inAny: roots.map { $0.standardizedFileURL })
    }

    private static func diff(
        local: [PackageManifestEntry],
        remote: [PackageManifestEntry]
    ) -> [UpdateFileChange] {
        let localByPath = Dictionary(uniqueKeysWithValues: local.map { ($0.path, $0) })
        let remoteByPath = Dictionary(uniqueKeysWithValues: remote.map { ($0.path, $0) })
        return Set(localByPath.keys).union(remoteByPath.keys).sorted().compactMap { path in
            switch (localByPath[path], remoteByPath[path]) {
            case (nil, .some): UpdateFileChange(path: path, kind: .added)
            case (.some, nil): UpdateFileChange(path: path, kind: .deleted)
            case (.some(let local), .some(let remote)) where local != remote:
                UpdateFileChange(path: path, kind: .changed)
            default: nil
            }
        }
    }
}

public final class SkillFileOperatorPackageReplacer: SkillPackageReplacing, @unchecked Sendable {
    private let trash: any FileOperationTrashing

    public init(trash: any FileOperationTrashing = MacOSTrash()) {
        self.trash = trash
    }

    public func replace(
        target: URL,
        with package: URL,
        expectedTargetDigest: PackageDigest,
        entryFilename: String,
        authorizedRootURLs: [URL]
    ) async throws {
        let target = target.standardizedFileURL
        let package = package.standardizedFileURL
        guard isCovered(target, roots: authorizedRootURLs) else {
            throw SkillUpdateError.unauthorizedInstallation
        }
        let targetRoot = target.deletingLastPathComponent()
        let sourceRoot = package.deletingLastPathComponent()
        let roots = [
            AuthorizedRootSnapshot(id: "update-source", url: sourceRoot, kind: .custom),
            AuthorizedRootSnapshot(id: "update-target", url: targetRoot, kind: .custom),
        ]
        let fileOperator = SkillFileOperator(
            registryProvider: { AgentRegistry(definitions: []) },
            authorizedRootsProvider: { roots },
            indexedAliasesProvider: { [] },
            trash: trash
        )
        let plan = try fileOperator.plan(FileOperationRequest(
            operation: .copy,
            sourceURL: package,
            sourceEntryFilename: entryFilename,
            destinationRootURL: targetRoot,
            proposedName: target.lastPathComponent,
            conflictPolicy: .replace
        ))
        guard try PackageDigest.compute(at: target) == expectedTargetDigest else {
            throw SkillFileOperatorError.destinationChanged
        }
        _ = try await fileOperator.execute(
            plan,
            confirmation: plan.confirmationToken,
            replacementConfirmation: plan.replacementConfirmationToken
        )
    }

    private func isCovered(_ candidate: URL, roots: [URL]) -> Bool {
        candidate.isContained(inAny: roots.map { $0.standardizedFileURL })
    }
}

public struct LiveSkillPackageFetcher: SkillPackageFetching {
    private struct TreeResponse: Decodable { let tree: [TreeItem]; let truncated: Bool }
    private struct TreeItem: Decodable {
        let path: String
        let mode: String
        let type: String
        let sha: String
        let size: Int64?
    }

    private let executableURL: URL?
    private let runner: any CommandRunning
    private let authorizedHomeURL: URL?
    private let session: URLSession

    public init(
        executableURL: URL,
        authorizedHomeURL: URL? = nil,
        runner: any CommandRunning = ExternalCommandRunner()
    ) {
        self.executableURL = executableURL.standardizedFileURL
        self.authorizedHomeURL = authorizedHomeURL?.standardizedFileURL
        self.runner = runner
        session = .shared
    }

    public init() {
        executableURL = nil
        authorizedHomeURL = nil
        runner = ExternalCommandRunner()
        session = .shared
    }

    public init(session: URLSession) {
        executableURL = nil
        authorizedHomeURL = nil
        runner = ExternalCommandRunner()
        self.session = session
    }

    public func fetch(_ source: SkillSource, into destination: URL) async throws -> FetchedSkillPackage {
        try await fetch(source, into: destination, entryFilename: "SKILL.md")
    }

    public func fetch(
        _ source: SkillSource,
        into destination: URL,
        entryFilename: String
    ) async throws -> FetchedSkillPackage {
        switch source.kind {
        case .github:
            return try await fetchGitHub(source, into: destination)
        case .directPackage:
            return try await fetchDirect(source, into: destination, entryFilename: entryFilename)
        }
    }

    private func fetchGitHub(_ source: SkillSource, into destination: URL) async throws -> FetchedSkillPackage {
        guard let repository = source.repository,
              let reference = source.reference,
              let subdirectory = source.subdirectory else {
            throw SkillUpdateError.unsupportedSource
        }
        let commitResult = try await run([
            "api", "repos/\(repository)/commits/\(reference.value)", "--jq", ".sha",
        ], limit: 4_096)
        let commit = commitResult.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isHexIdentifier(commit) else { throw SkillUpdateError.invalidRemoteResponse }
        let treeData = try await runData([
            "api", "repos/\(repository)/git/trees/\(commit)?recursive=1",
        ], limit: 8 * 1_024 * 1_024)
        guard let tree = try? JSONDecoder().decode(TreeResponse.self, from: treeData),
              !tree.truncated else {
            if (try? JSONDecoder().decode(TreeResponse.self, from: treeData).truncated) == true {
                throw SkillUpdateError.truncatedRepositoryTree
            }
            throw SkillUpdateError.invalidRemoteResponse
        }
        let prefix = subdirectory == "." ? "" : "\(subdirectory)/"
        let items = tree.tree.filter {
            prefix.isEmpty ? true : $0.path.hasPrefix(prefix)
        }.compactMap { item -> (TreeItem, String)? in
            let relative = prefix.isEmpty ? item.path : String(item.path.dropFirst(prefix.count))
            return relative.isEmpty ? nil : (item, relative)
        }
        guard !items.isEmpty else { throw SkillUpdateError.invalidRemoteResponse }
        let validator = PackageValidator()
        let archiveEntries = items.map { item, relative -> PackageArchiveEntry in
            let kind: PackageArchiveEntryKind
            if item.type == "tree" { kind = .directory }
            else if item.mode == "120000" { kind = .symbolicLink }
            else if item.type == "blob" && (item.mode == "100644" || item.mode == "100755") { kind = .regularFile }
            else { kind = .device }
            return PackageArchiveEntry(
                path: relative,
                kind: kind,
                byteCount: item.size ?? 0,
                // Tree responses do not include link bytes. Validate its actual target after every blob is downloaded.
                symbolicLinkTarget: kind == .symbolicLink ? "." : nil
            )
        }
        try validator.validateArchiveEntries(archiveEntries)
        struct DownloadedItem {
            let item: TreeItem
            let relativePath: String
            let bytes: Data
        }
        var downloaded: [DownloadedItem] = []
        for (item, relative) in items.sorted(by: { $0.1 < $1.1 }) {
            if item.type == "tree" {
                continue
            }
            guard item.type == "blob", let size = item.size, size >= 0,
                  size < Int64(Int.max) else {
                throw PackageValidationError.unsupportedItem(relative)
            }
            let bytes = try await runData([
                "api", "repos/\(repository)/git/blobs/\(item.sha)",
                "-H", "Accept: application/vnd.github.raw+json",
            ], limit: max(1, Int(size) + 1))
            downloaded.append(DownloadedItem(item: item, relativePath: relative, bytes: bytes))
        }
        let downloadedEntries = downloaded.map { downloaded -> PackageArchiveEntry in
            PackageArchiveEntry(
                path: downloaded.relativePath,
                kind: downloaded.item.mode == "120000" ? .symbolicLink : .regularFile,
                byteCount: Int64(downloaded.bytes.count),
                symbolicLinkTarget: downloaded.item.mode == "120000"
                    ? String(data: downloaded.bytes, encoding: .utf8)
                    : nil
            )
        }
        try validator.validateArchiveEntries(downloadedEntries)

        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for downloaded in downloaded {
            let output = destination.appending(path: downloaded.relativePath)
            try FileManager.default.createDirectory(
                at: output.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if downloaded.item.mode == "120000" {
                guard let target = String(data: downloaded.bytes, encoding: .utf8) else {
                    throw SkillUpdateError.invalidRemoteResponse
                }
                try FileManager.default.createSymbolicLink(atPath: output.path, withDestinationPath: target)
            } else {
                try downloaded.bytes.write(to: output, options: .atomic)
                if downloaded.item.mode == "100755" {
                    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: output.path)
                }
            }
        }
        return FetchedSkillPackage(packageURL: destination, resolvedReference: commit)
    }

    private func fetchDirect(
        _ source: SkillSource,
        into destination: URL,
        entryFilename: String
    ) async throws -> FetchedSkillPackage {
        guard let url = source.directPackageURL else {
            throw SkillUpdateError.unsupportedSource
        }
        let (bytes, response) = try await session.bytes(from: url)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              http.url?.scheme?.lowercased() == "https",
              http.url?.host?.lowercased() == url.host?.lowercased() else {
            throw SkillUpdateError.invalidRemoteResponse
        }
        let maximumBytes = 100 * 1_024 * 1_024
        var data = Data()
        data.reserveCapacity(min(http.expectedContentLength > 0
            ? Int(http.expectedContentLength) : 0, maximumBytes))
        for try await byte in bytes {
            guard data.count < maximumBytes else {
                throw SkillUpdateError.remotePackageTooLarge
            }
            data.append(byte)
        }
        if data.starts(with: [0x50, 0x4b, 0x03, 0x04]) {
            try SafeZIPExtractor.extract(data, into: destination, validator: PackageValidator(entryFilename: entryFilename))
            if FileManager.default.fileExists(
                atPath: destination.appending(path: entryFilename).path
            ) {
                return FetchedSkillPackage(packageURL: destination)
            }
            let children = try FileManager.default.contentsOfDirectory(
                at: destination,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            )
            if children.count == 1,
               children[0].hasDirectoryPath,
                FileManager.default.fileExists(
                    atPath: children[0].appending(path: entryFilename).path
               ) {
                return FetchedSkillPackage(packageURL: children[0])
            }
            throw PackageValidationError.missingEntryFile(entryFilename)
        }
        guard String(data: data, encoding: .utf8) != nil else {
            throw SkillUpdateError.invalidRemoteResponse
        }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try data.write(to: destination.appending(path: entryFilename), options: .atomic)
        return FetchedSkillPackage(packageURL: destination)
    }

    private func run(_ arguments: [String], limit: Int) async throws -> String {
        String(decoding: try await runData(arguments, limit: limit), as: UTF8.self)
    }

    private func runData(_ arguments: [String], limit: Int) async throws -> Data {
        guard let executableURL else { throw SkillUpdateError.unsupportedSource }
        let result = try await runner.run(ExternalCommand(
            executableURL: executableURL,
            arguments: arguments,
            authorizedHomeURL: authorizedHomeURL,
            timeout: 60,
            maximumOutputBytes: limit
        ))
        guard result.succeeded else {
            throw SkillUpdateError.commandFailed(status: result.terminationStatus)
        }
        return result.stdout
    }

    private func isHexIdentifier(_ value: String) -> Bool {
        (7...64).contains(value.count) && value.allSatisfy { $0.isHexDigit }
    }
}
