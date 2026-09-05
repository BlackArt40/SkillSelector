import Foundation

protocol IndexRefresherFileSystem: Sendable {
    func probeDirectory(_ url: URL) throws -> DirectoryProbe
    func contentsOfDirectory(at url: URL) throws -> [URL]
    func resolvingSymlinks(in url: URL) -> URL
}

enum DirectoryProbe: Equatable, Sendable {
    case directory
    case missing
}

private struct LocalIndexRefresherFileSystem: IndexRefresherFileSystem {
    func probeDirectory(_ url: URL) throws -> DirectoryProbe {
        do {
            return try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
                ? .directory
                : .missing
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain,
               [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(nsError.code) {
                return .missing
            }
            throw error
        }
    }

    func contentsOfDirectory(at url: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        )
    }

    func resolvingSymlinks(in url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }
}

public struct RefreshSummary: Hashable, Sendable {
    public let added: Int
    public let changed: Int
    public let removed: Int
    /// Paths behind the counts, so the refresh history can answer "what
    /// exactly changed" without re-deriving anything.
    public let addedPaths: [String]
    public let changedPaths: [String]
    public let removedPaths: [String]

    public init(
        added: Int,
        changed: Int,
        removed: Int,
        addedPaths: [String] = [],
        changedPaths: [String] = [],
        removedPaths: [String] = []
    ) {
        self.added = added
        self.changed = changed
        self.removed = removed
        self.addedPaths = addedPaths
        self.changedPaths = changedPaths
        self.removedPaths = removedPaths
    }

    public var isEmpty: Bool {
        added == 0 && changed == 0 && removed == 0
    }
}

/// A scan plan for one authorized root: which directories to scan and how
/// each root should be disposed of.
private struct ScanPlan {
    var scanRoots: [ScanRoot]
    var dispositions: [ScannedRoot]
}

/// Builds scan plans. Extracted from `IndexRefresher` so the directory
/// probing and template expansion (pure file I/O) can run off the main
/// thread — `refresh()` previously did all of it synchronously before its
/// first `await`, blocking the UI for large home roots (audit R7).
private struct ScanPlanBuilder: Sendable {
    private let registry: AgentRegistry
    private let fileSystem: any IndexRefresherFileSystem

    init(registry: AgentRegistry, fileSystem: any IndexRefresherFileSystem) {
        self.registry = registry
        self.fileSystem = fileSystem
    }

    func scanPlan(for root: AuthorizedRootSnapshot) -> ScanPlan {
        switch root.kind {
        case .home:
            return homeRoots(root)
        case .project:
            return projectRoots(root)
        case .system, .custom:
            return exactRoots(root)
        }
    }

    private func homeRoots(_ root: AuthorizedRootSnapshot) -> ScanPlan {
        do {
            guard try probeDirectory(root.url) == .directory else {
                return unavailablePlan(
                    for: root,
                    diagnostic: StructuredDiagnostic(code: .authorizedHomeMissing)
                )
            }
        } catch {
            return unavailablePlan(for: root, error: error)
        }

        var candidates: [String: (url: URL, agents: Set<String>, entry: String)] = [:]
        var availableDispositions = [root.url.path: root.url]
        var unavailableDispositions: [ScannedRoot] = []
        for declaration in registry.globalDeclarations {
            do {
                for url in try expandedHomeURLs(declaration.value, relativeTo: root.url) {
                    switch try probeDirectory(url) {
                    case .directory:
                        let key = "\(url.path)\u{1f}\(declaration.entryFilename)"
                        var candidate = candidates[key, default: (url, [], declaration.entryFilename)]
                        if let agentID = declaration.agentID {
                            candidate.agents.insert(agentID)
                        }
                        candidates[key] = candidate
                    case .missing:
                        availableDispositions[url.path] = url
                    }
                }
            } catch {
                let detail = String(describing: error)
                let diagnostic = StructuredDiagnostic(
                    code: .unableToInspectAuthorizedDirectory,
                    arguments: [detail]
                )
                unavailableDispositions.append(
                    ScannedRoot(
                        id: root.id,
                        url: root.url,
                        availability: .unavailable(reason: diagnostic.fallbackMessage),
                        unavailableDiagnostic: diagnostic
                    )
                )
            }
        }
        let scanRoots = candidates
            .sorted { $0.value.url.path < $1.value.url.path }
            .map { key, candidate in
                ScanRoot.skillDirectory(
                    id: root.id,
                    url: candidate.url,
                    agentIDs: candidate.agents,
                    entryFilename: candidate.entry
                )
            }
        return ScanPlan(
            scanRoots: scanRoots,
            dispositions: availableDispositions.values.map {
                ScannedRoot(id: root.id, url: $0, availability: .available)
            } + unavailableDispositions
        )
    }

    private func exactRoots(_ root: AuthorizedRootSnapshot) -> ScanPlan {
        do {
            guard try probeDirectory(root.url) == .directory else {
                return unavailablePlan(
                    for: root,
                    diagnostic: StructuredDiagnostic(code: .authorizedDirectoryMissing)
                )
            }
        } catch {
            return unavailablePlan(for: root, error: error)
        }
        let matching = registry.globalDeclarations.filter { declaration in
            declaration.value == root.url.path
        }
        let grouped = Dictionary(grouping: matching, by: \.entryFilename)
        if grouped.isEmpty {
            return ScanPlan(
                scanRoots: [
                    .skillDirectory(
                        id: root.id,
                        url: root.url,
                        agentIDs: [root.kind == .system ? SyntheticAgentID.system : SyntheticAgentID.custom]
                    ),
                ],
                dispositions: []
            )
        }
        return ScanPlan(
            scanRoots: grouped.sorted { $0.key < $1.key }.map { entryFilename, declarations in
                ScanRoot.skillDirectory(
                    id: root.id,
                    url: root.url,
                    agentIDs: Set(declarations.compactMap(\.agentID)),
                    entryFilename: entryFilename
                )
            },
            dispositions: []
        )
    }

    private func projectRoots(_ root: AuthorizedRootSnapshot) -> ScanPlan {
        do {
            guard try probeDirectory(root.url) == .directory else {
                return unavailablePlan(
                    for: root,
                    diagnostic: StructuredDiagnostic(code: .authorizedProjectMissing)
                )
            }
        } catch {
            return unavailablePlan(for: root, error: error)
        }
        return ScanPlan(
            scanRoots: [.project(id: root.id, url: root.url, registry: registry)],
            dispositions: []
        )
    }

    private func unavailablePlan(
        for root: AuthorizedRootSnapshot,
        error: Error
    ) -> ScanPlan {
        let detail = String(describing: error)
        return unavailablePlan(
            for: root,
            diagnostic: StructuredDiagnostic(
                code: .unableToInspectAuthorizedDirectory,
                arguments: [detail]
            )
        )
    }

    private func unavailablePlan(
        for root: AuthorizedRootSnapshot,
        diagnostic: StructuredDiagnostic
    ) -> ScanPlan {
        ScanPlan(
            scanRoots: [],
            dispositions: [
                ScannedRoot(
                    id: root.id,
                    url: root.url,
                    availability: .unavailable(reason: diagnostic.fallbackMessage),
                    unavailableDiagnostic: diagnostic
                ),
            ]
        )
    }

    private func probeDirectory(_ url: URL) throws -> DirectoryProbe {
        try fileSystem.probeDirectory(url)
    }

    private func expandedHomeURLs(_ path: String, relativeTo home: URL) throws -> [URL] {
        guard path.hasPrefix("~/") else { return [] }
        let components = path.dropFirst(2).split(separator: "/").map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            return []
        }

        var candidates = [home.standardizedFileURL]
        for component in components {
            if component.contains("{") || component.contains("}") {
                guard isValidTemplate(component) else { return [] }
                var expanded: [URL] = []
                for parent in candidates {
                    guard isContained(parent, in: home) else {
                        continue
                    }
                    guard try probeDirectory(parent) == .directory else { continue }
                    for child in try directoryContents(parent) {
                        guard TemplateMatching.segment(child.lastPathComponent, matches: component),
                              isContained(child, in: home) else {
                            continue
                        }
                        if try probeDirectory(child) == .directory {
                            expanded.append(child)
                        }
                    }
                }
                candidates = expanded
            } else {
                candidates = candidates.map { $0.appendingPathComponent(component).standardizedFileURL }
            }
        }
        return candidates.filter { isContained($0, in: home) }
    }

    private func isValidTemplate(_ template: String) -> Bool {
        guard let opening = template.firstIndex(of: "{"),
              let closing = template[opening...].firstIndex(of: "}"),
              opening < closing else {
            return false
        }
        let remainder = template[template.index(after: closing)...]
        return !template[template.index(after: opening)..<closing].isEmpty
            && !remainder.contains("{")
            && !remainder.contains("}")
    }

    private func directoryContents(_ url: URL) throws -> [URL] {
        try fileSystem.contentsOfDirectory(at: url)
    }

    private func isContained(_ candidate: URL, in root: URL) -> Bool {
        contains(candidate.standardizedFileURL, in: root.standardizedFileURL)
            && contains(
                fileSystem.resolvingSymlinks(in: candidate),
                in: fileSystem.resolvingSymlinks(in: root)
            )
    }

    private func contains(_ candidate: URL, in root: URL) -> Bool {
        candidate.standardizedFileURL.isContained(in: root.standardizedFileURL)
    }
}

public final class IndexRefresher {
    private var registry: AgentRegistry
    private let bookmarks: BookmarkStore
    private let scanner: SkillScanner
    private let index: SkillIndex
    private let fileSystem: any IndexRefresherFileSystem

    public init(
        registry: AgentRegistry,
        bookmarks: BookmarkStore,
        scanner: SkillScanner = SkillScanner(),
        index: SkillIndex
    ) {
        self.registry = registry
        self.bookmarks = bookmarks
        self.scanner = scanner
        self.index = index
        fileSystem = LocalIndexRefresherFileSystem()
    }

    init(
        registry: AgentRegistry,
        bookmarks: BookmarkStore,
        scanner: SkillScanner = SkillScanner(),
        index: SkillIndex,
        fileSystem: any IndexRefresherFileSystem
    ) {
        self.registry = registry
        self.bookmarks = bookmarks
        self.scanner = scanner
        self.index = index
        self.fileSystem = fileSystem
    }

    @MainActor
    public func updateRegistry(_ registry: AgentRegistry) {
        self.registry = registry
    }

    @MainActor
    public func refresh() async throws -> RefreshSummary {
        try await refresh(selectedRootIDs: nil)
    }

    @MainActor
    public func refresh(
        rootIDs: Set<String>
    ) async throws -> RefreshSummary {
        try await refresh(selectedRootIDs: rootIDs)
    }

    @MainActor
    private func refresh(
        selectedRootIDs: Set<String>?
    ) async throws -> RefreshSummary {
        let before = try index.skills()
        let snapshots = try bookmarks.roots().filter { root in
            selectedRootIDs?.contains(root.id) ?? true
        }
        var accesses: [AuthorizedRootAccess] = []
        var roots: [ScanRoot] = []
        var dispositions: [ScannedRoot] = []
        var unresolvedRoots: [ScannedRoot] = []

        defer {
            accesses.forEach { $0.lease.close() }
        }

        // Build the scan plan off the main thread: probing directories and
        // expanding templates is file I/O that used to block the UI before
        // the first await (audit R7). Bookmarks still resolve here — the
        // Security framework scoped access must be created on this actor.
        let builder = ScanPlanBuilder(registry: registry, fileSystem: fileSystem)
        for snapshot in snapshots {
            do {
                let access = try bookmarks.resolve(id: snapshot.id)
                accesses.append(access)
                let plan = await Task.detached(priority: .userInitiated) {
                    builder.scanPlan(for: access.root)
                }.value
                roots.append(contentsOf: plan.scanRoots)
                dispositions.append(contentsOf: plan.dispositions)
            } catch {
                let detail = String(describing: error)
                let diagnostic = StructuredDiagnostic(
                    code: .unableToResolveAuthorizedDirectory,
                    arguments: [detail]
                )
                unresolvedRoots.append(
                    ScannedRoot(
                        id: snapshot.id,
                        url: snapshot.url,
                        availability: .unavailable(reason: diagnostic.fallbackMessage),
                        unavailableDiagnostic: diagnostic
                    )
                )
            }
        }

        var report = await scanner.scan(
            roots,
            cache: SkillScanCache(entriesByPath: (try? index.cachedScanEntries()) ?? [:])
        )
        report.roots = coalescedRoots(
            report.roots + dispositions + unresolvedRoots
        )
        try index.apply(report: report)
        let after = try index.skills()
        return summary(before: before, after: after)
    }

    private func coalescedRoots(_ roots: [ScannedRoot]) -> [ScannedRoot] {
        Dictionary(grouping: roots, by: \.id)
            .sorted { $0.key < $1.key }
            .map { id, roots in
                if let unavailable = roots.first(where: {
                    if case .unavailable = $0.availability { return true }
                    return false
                }), case .unavailable(let reason) = unavailable.availability {
                    return ScannedRoot(
                        id: id,
                        url: unavailable.url,
                        availability: .unavailable(reason: reason),
                        unavailableDiagnostic: unavailable.unavailableDiagnostic
                    )
                }
                let available = roots[0]
                return ScannedRoot(id: id, url: available.url, availability: .available)
            }
    }

    private func summary(before: [SkillSnapshot], after: [SkillSnapshot]) -> RefreshSummary {
        // Favor the first snapshot on duplicate paths (defensive: paths are
        // unique in practice, but a corrupted store must not crash here).
        let oldByPath = Dictionary(before.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let newByPath = Dictionary(after.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let addedPaths = newByPath.keys.filter { oldByPath[$0] == nil }.sorted()
        let removedPaths = oldByPath.keys.filter { newByPath[$0] == nil }.sorted()
        let changedPaths = newByPath.keys.filter { path in
            guard let old = oldByPath[path], let snapshot = newByPath[path] else {
                return false
            }
            return old != snapshot
        }.sorted()
        return RefreshSummary(
            added: addedPaths.count,
            changed: changedPaths.count,
            removed: removedPaths.count,
            addedPaths: addedPaths,
            changedPaths: changedPaths,
            removedPaths: removedPaths
        )
    }
}
