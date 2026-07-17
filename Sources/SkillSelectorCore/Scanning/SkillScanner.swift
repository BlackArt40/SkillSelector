import Foundation

public struct SkillScanner: Sendable {
    private static let skippedDirectoryNames: Set<String> = [
        ".git",
        "node_modules",
        ".build",
        "build",
        "dist",
        "DerivedData",
        ".swiftpm",
        "Pods",
        "vendor",
        "Vendor",
        ".cache",
        "cache",
        "Caches",
        "Carthage",
    ]

    public init() {}

    public func scan(_ roots: [ScanRoot]) async -> ScanReport {
        let authorizedURLs = roots.map(\.url)
        var installations: [String: ScannedSkill] = [:]
        var rootReports: [ScannedRoot] = []

        for root in roots {
            let result = scan(root, authorizedURLs: authorizedURLs)
            rootReports.append(result.root)
            for candidate in result.installations {
                if var existing = installations[candidate.installation.id] {
                    existing.installation.agentIDs.formUnion(candidate.agentIDs)
                    existing.rootIDs.formUnion(candidate.rootIDs)
                    if existing.installation.resolvedTarget == nil {
                        existing.installation.resolvedTarget = candidate.resolvedTarget
                    }
                    installations[candidate.installation.id] = existing
                } else {
                    installations[candidate.installation.id] = candidate
                }
            }
        }

        return ScanReport(
            installations: installations.values.sorted { $0.path.path < $1.path.path },
            roots: rootReports
        )
    }

    private func scan(
        _ root: ScanRoot,
        authorizedURLs: [URL]
    ) -> (root: ScannedRoot, installations: [ScannedSkill]) {
        guard isAccessibleRoot(root.url, authorizedURLs: authorizedURLs) else {
            return (
                ScannedRoot(
                    id: root.id,
                    url: root.url,
                    availability: .unavailable(reason: "Root is missing or is not a readable directory")
                ),
                []
            )
        }

        do {
            let installations: [ScannedSkill]
            switch root.kind {
            case .skillDirectory(let agentIDs, let entryFilename):
                installations = try scanSkillDirectory(
                    root,
                    agentIDs: agentIDs,
                    entryFilename: entryFilename,
                    authorizedURLs: authorizedURLs
                )
            case .project(let registry):
                installations = try scanProject(
                    root,
                    registry: registry,
                    authorizedURLs: authorizedURLs
                )
            }
            return (
                ScannedRoot(id: root.id, url: root.url, availability: .available),
                installations
            )
        } catch {
            return (
                ScannedRoot(
                    id: root.id,
                    url: root.url,
                    availability: .unavailable(reason: String(describing: error))
                ),
                []
            )
        }
    }

    private func scanSkillDirectory(
        _ root: ScanRoot,
        agentIDs: Set<String>,
        entryFilename: String,
        authorizedURLs: [URL]
    ) throws -> [ScannedSkill] {
        if let rootSkill = makeCandidate(
            installationURL: root.url,
            agentIDs: agentIDs,
            entryFilename: entryFilename,
            rootID: root.id,
            authorizedURLs: authorizedURLs
        ) {
            return [rootSkill]
        }

        return try directoryContents(root.url).compactMap { child in
            guard !Self.skippedDirectoryNames.contains(child.lastPathComponent),
                  isDirectoryOrSymbolicLink(child) else {
                return nil
            }
            return makeCandidate(
                installationURL: child,
                agentIDs: agentIDs,
                entryFilename: entryFilename,
                rootID: root.id,
                authorizedURLs: authorizedURLs
            )
        }
    }

    private func scanProject(
        _ root: ScanRoot,
        registry: AgentRegistry,
        authorizedURLs: [URL]
    ) throws -> [ScannedSkill] {
        var installations: [ScannedSkill] = []
        try walkProjectDirectory(
            root.url,
            relativeComponents: [],
            root: root,
            definitions: registry.definitions,
            authorizedURLs: authorizedURLs,
            installations: &installations
        )
        return installations
    }

    private func walkProjectDirectory(
        _ directory: URL,
        relativeComponents: [String],
        root: ScanRoot,
        definitions: [AgentDefinition],
        authorizedURLs: [URL],
        installations: inout [ScannedSkill]
    ) throws {
        if !relativeComponents.isEmpty {
            let entries = matchingEntries(
                in: relativeComponents,
                definitions: definitions
            )
            if containsRecognizedEntry(in: directory, entries: entries) {
                if let candidate = makeProjectCandidate(
                    installationURL: directory,
                    entries: entries,
                    rootID: root.id,
                    authorizedURLs: authorizedURLs
                ) {
                    installations.append(candidate)
                }
                return
            }
        }

        for child in try directoryContents(directory) {
            let name = child.lastPathComponent
            guard !Self.skippedDirectoryNames.contains(name),
                  isDirectoryOrSymbolicLink(child) else {
                continue
            }

            let childComponents = relativeComponents + [name]
            if isSymbolicLink(child) {
                guard let candidate = makeProjectCandidate(
                    installationURL: child,
                    entries: matchingEntries(
                        in: childComponents,
                        definitions: definitions
                    ),
                    rootID: root.id,
                    authorizedURLs: authorizedURLs
                ) else {
                    continue
                }
                installations.append(candidate)
            } else {
                try walkProjectDirectory(
                    child,
                    relativeComponents: childComponents,
                    root: root,
                    definitions: definitions,
                    authorizedURLs: authorizedURLs,
                    installations: &installations
                )
            }
        }
    }

    private func matchingEntries(
        in skillDirectoryComponents: [String],
        definitions: [AgentDefinition]
    ) -> [(agentIDs: Set<String>, entryFilename: String)] {
        let parentComponents = Array(skillDirectoryComponents.dropLast())
        let matches = definitions.flatMap { definition in
            definition.projectPatterns.compactMap { pattern -> (String, String)? in
                let components = pattern.split(separator: "/").map(String.init)
                guard pathSuffix(parentComponents, matches: components) else { return nil }
                return (definition.id, definition.entryFilename)
            }
        }

        let entries = Dictionary(grouping: matches, by: { $0.1 })
        return entries.keys.sorted(by: { lhs, rhs in
            if lhs == "SKILL.md" { return true }
            if rhs == "SKILL.md" { return false }
            return lhs < rhs
        }).map { entryFilename in
            (Set(entries[entryFilename, default: []].map(\.0)), entryFilename)
        }
    }

    private func makeProjectCandidate(
        installationURL: URL,
        entries: [(agentIDs: Set<String>, entryFilename: String)],
        rootID: String,
        authorizedURLs: [URL]
    ) -> ScannedSkill? {
        var result: ScannedSkill?
        for match in entries {
            guard let candidate = makeCandidate(
                installationURL: installationURL,
                agentIDs: match.agentIDs,
                entryFilename: match.entryFilename,
                rootID: rootID,
                authorizedURLs: authorizedURLs
            ) else {
                continue
            }
            if result == nil {
                result = candidate
            } else {
                result?.installation.agentIDs.formUnion(candidate.agentIDs)
            }
        }
        return result
    }

    private func containsRecognizedEntry(
        in directory: URL,
        entries: [(agentIDs: Set<String>, entryFilename: String)]
    ) -> Bool {
        entries.contains { entry in
            let entryURL = directory.appending(path: entry.entryFilename)
            return isSymbolicLink(entryURL) || isRegularFile(entryURL)
        }
    }

    private func pathSuffix(_ path: [String], matches pattern: [String]) -> Bool {
        guard path.count >= pattern.count else { return false }
        return zip(path.suffix(pattern.count), pattern).allSatisfy { value, template in
            segment(value, matches: template)
        }
    }

    private func segment(_ value: String, matches template: String) -> Bool {
        guard let opening = template.firstIndex(of: "{"),
              let closing = template[opening...].firstIndex(of: "}") else {
            return value == template
        }
        let prefix = String(template[..<opening])
        let suffix = String(template[template.index(after: closing)...])
        return value.hasPrefix(prefix)
            && value.hasSuffix(suffix)
            && value.count > prefix.count + suffix.count
    }

    private func makeCandidate(
        installationURL: URL,
        agentIDs: Set<String>,
        entryFilename: String,
        rootID: String,
        authorizedURLs: [URL]
    ) -> ScannedSkill? {
        let installationURL = installationURL.standardizedFileURL
        let symbolicLink = isSymbolicLink(installationURL)
        let contentDirectory: URL
        let resolvedTarget: URL?

        if symbolicLink {
            let target = installationURL.resolvingSymlinksInPath().standardizedFileURL
            guard target != installationURL,
                  authorizedURLs.contains(where: { contains(target, in: $0) }),
                  isDirectory(target) else {
                return nil
            }
            contentDirectory = target
            resolvedTarget = target
        } else {
            guard isDirectory(installationURL) else { return nil }
            contentDirectory = installationURL
            resolvedTarget = nil
        }

        let entryURL = contentDirectory.appending(path: entryFilename)
        guard accessibleFile(entryURL, authorizedURLs: authorizedURLs),
              isRegularFile(entryURL) else {
            return nil
        }

        let document: ParsedSkillDocument
        do {
            document = FrontmatterParser.parse(try String(contentsOf: entryURL, encoding: .utf8))
        } catch {
            document = ParsedSkillDocument(
                title: installationURL.lastPathComponent,
                issues: [ParseIssue(message: "Unable to read \(entryFilename): \(error.localizedDescription)")]
            )
        }

        let modificationDate = try? entryURL.resourceValues(
            forKeys: [.contentModificationDateKey]
        ).contentModificationDate
        return ScannedSkill(
            installation: SkillInstallation(
                path: installationURL,
                resolvedTarget: resolvedTarget,
                agentIDs: agentIDs
            ),
            document: document,
            rootIDs: [rootID],
            entryFilename: entryFilename,
            entryModificationDate: modificationDate
        )
    }

    private func accessibleFile(_ url: URL, authorizedURLs: [URL]) -> Bool {
        guard isSymbolicLink(url) else { return true }
        let target = url.resolvingSymlinksInPath().standardizedFileURL
        return authorizedURLs.contains(where: { contains(target, in: $0) })
    }

    private func isAccessibleRoot(_ url: URL, authorizedURLs: [URL]) -> Bool {
        guard isSymbolicLink(url) else { return isDirectory(url) }
        let target = url.resolvingSymlinksInPath().standardizedFileURL
        return authorizedURLs.contains(where: { contains(target, in: $0) }) && isDirectory(target)
    }

    private func contains(_ candidate: URL, in root: URL) -> Bool {
        let candidatePath = candidate.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }

    private func directoryContents(_ url: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: []
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    private func isDirectoryOrSymbolicLink(_ url: URL) -> Bool {
        isSymbolicLink(url) || isDirectory(url)
    }
}
