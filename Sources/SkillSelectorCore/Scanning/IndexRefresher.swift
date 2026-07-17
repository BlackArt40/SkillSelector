import Foundation

protocol IndexRefresherFileSystem {
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

public enum RefreshTrigger: Sendable {
    case startup
    case manual
}

public struct RefreshSummary: Hashable, Sendable {
    public let added: Int
    public let changed: Int
    public let unavailable: Int
    public let removed: Int

    public init(added: Int, changed: Int, unavailable: Int, removed: Int) {
        self.added = added
        self.changed = changed
        self.unavailable = unavailable
        self.removed = removed
    }
}

public final class IndexRefresher {
    private let registry: AgentRegistry
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
    public func refresh(_ trigger: RefreshTrigger) async throws -> RefreshSummary {
        try await refresh(trigger, selectedRootIDs: nil)
    }

    @MainActor
    public func refresh(
        _ trigger: RefreshTrigger,
        rootIDs: Set<String>
    ) async throws -> RefreshSummary {
        try await refresh(trigger, selectedRootIDs: rootIDs)
    }

    @MainActor
    private func refresh(
        _ trigger: RefreshTrigger,
        selectedRootIDs: Set<String>?
    ) async throws -> RefreshSummary {
        _ = trigger
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

        for snapshot in snapshots {
            do {
                let access = try bookmarks.resolve(id: snapshot.id)
                accesses.append(access)
                let plan = scanPlan(for: access.root)
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

        var report = await scanner.scan(roots)
        report.roots = coalescedRoots(
            report.roots + dispositions + unresolvedRoots
        )
        try index.apply(report: report)
        let after = try index.skills()
        return summary(before: before, after: after)
    }

    private struct ScanPlan {
        var scanRoots: [ScanRoot]
        var dispositions: [ScannedRoot]
    }

    private func scanPlan(for root: AuthorizedRootSnapshot) -> ScanPlan {
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
        for definition in registry.definitions {
            for declaredPath in definition.globalRoots {
                do {
                    for url in try expandedHomeURLs(declaredPath, relativeTo: root.url) {
                        switch try probeDirectory(url) {
                        case .directory:
                            let key = "\(url.path)\u{1f}\(definition.entryFilename)"
                            candidates[key, default: (url, [], definition.entryFilename)]
                                .agents.insert(definition.id)
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
        let matching = registry.definitions.filter { definition in
            definition.globalRoots.contains(root.url.path)
        }
        let grouped = Dictionary(grouping: matching, by: \.entryFilename)
        if grouped.isEmpty {
            return ScanPlan(
                scanRoots: [
                    .skillDirectory(
                        id: root.id,
                        url: root.url,
                        agentIDs: [root.kind == .system ? "system" : "custom"]
                    ),
                ],
                dispositions: []
            )
        }
        return ScanPlan(
            scanRoots: grouped.sorted { $0.key < $1.key }.map { entryFilename, definitions in
                ScanRoot.skillDirectory(
                    id: root.id,
                    url: root.url,
                    agentIDs: Set(definitions.map(\.id)),
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
        let oldByPath = Dictionary(uniqueKeysWithValues: before.map { ($0.path, $0) })
        let newByPath = Dictionary(uniqueKeysWithValues: after.map { ($0.path, $0) })
        let added = newByPath.keys.filter { oldByPath[$0] == nil }.count
        let removed = oldByPath.keys.filter { newByPath[$0] == nil }.count
        let changed = newByPath.keys.filter { path in
            guard let old = oldByPath[path], let snapshot = newByPath[path] else {
                return false
            }
            return snapshot.availability == .available && old != snapshot
        }.count
        let unavailable = after.filter { $0.availability == .unavailable }.count
        return RefreshSummary(
            added: added,
            changed: changed,
            unavailable: unavailable,
            removed: removed
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
                        guard segment(child.lastPathComponent, matches: component),
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
                candidates = candidates.map { $0.appending(path: component).standardizedFileURL }
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
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        let rootComponents = root.standardizedFileURL.pathComponents
        return candidateComponents.count >= rootComponents.count
            && Array(candidateComponents.prefix(rootComponents.count)) == rootComponents
    }
}
