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
            let issues: [ScanIssue]
            switch root.kind {
            case .skillDirectory(let agentIDs, let entryFilename):
                if Self.isValidEntryFilename(entryFilename) {
                    installations = try scanSkillDirectory(
                        root,
                        agentIDs: agentIDs,
                        entryFilename: entryFilename,
                        authorizedURLs: authorizedURLs
                    )
                    issues = []
                } else {
                    installations = []
                    issues = [invalidEntryFilenameIssue(entryFilename)]
                }
            case .project(let registry):
                let validation = validatedDefinitions(registry.definitions)
                installations = try scanProject(
                    root,
                    definitions: validation.definitions,
                    authorizedURLs: authorizedURLs
                )
                issues = validation.issues
            }
            return (
                ScannedRoot(
                    id: root.id,
                    url: root.url,
                    availability: .available,
                    issues: issues
                ),
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
        definitions: [AgentDefinition],
        authorizedURLs: [URL]
    ) throws -> [ScannedSkill] {
        var installations: [ScannedSkill] = []
        try walkProjectDirectory(
            root.url,
            relativeComponents: [],
            root: root,
            definitions: definitions,
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
        if !relativeComponents.isEmpty,
           let candidate = makeProjectCandidate(
               installationURL: directory,
               entries: matchingEntries(
                   in: relativeComponents,
                   definitions: definitions
               ),
               rootID: root.id,
               authorizedURLs: authorizedURLs
           ) {
            installations.append(candidate)
            return
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
        guard Self.isValidEntryFilename(entryFilename) else { return nil }

        let installationURL = installationURL.standardizedFileURL
        let symbolicLink = isSymbolicLink(installationURL)
        let contentDirectory: URL
        let resolvedTarget: URL?

        if symbolicLink {
            let target = installationURL.resolvingSymlinksInPath().standardizedFileURL
            guard target != installationURL,
                  isWithinAuthorizedRoots(
                      standardizedURL: installationURL,
                      resolvedURL: target,
                      authorizedURLs: authorizedURLs
                  ),
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

        let resolvedEntryURL: URL
        switch inspectEntry(
            in: contentDirectory,
            entryFilename: entryFilename,
            authorizedURLs: authorizedURLs
        ) {
        case .absent:
            return nil
        case .unsafe(let message):
            return diagnosticCandidate(
                installationURL: installationURL,
                resolvedTarget: resolvedTarget,
                agentIDs: agentIDs,
                entryFilename: entryFilename,
                rootID: rootID,
                message: message
            )
        case .readable(let url):
            resolvedEntryURL = url
        }

        let document: ParsedSkillDocument
        do {
            document = FrontmatterParser.parse(
                try String(contentsOf: resolvedEntryURL, encoding: .utf8)
            )
        } catch {
            document = ParsedSkillDocument(
                title: installationURL.lastPathComponent,
                issues: [ParseIssue(message: "Unable to read \(entryFilename): \(error.localizedDescription)")]
            )
        }

        let modificationDate = try? resolvedEntryURL.resourceValues(
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

    private func inspectEntry(
        in packageDirectory: URL,
        entryFilename: String,
        authorizedURLs: [URL]
    ) -> EntryInspection {
        let entryURL = packageDirectory.appendingPathComponent(entryFilename)
            .standardizedFileURL
        let resolvedEntryURL = entryURL.resolvingSymlinksInPath().standardizedFileURL
        let isSafelyContained = isContained(
            standardizedURL: entryURL,
            resolvedURL: resolvedEntryURL,
            in: packageDirectory
        ) && isWithinAuthorizedRoots(
            standardizedURL: entryURL,
            resolvedURL: resolvedEntryURL,
            authorizedURLs: authorizedURLs
        )

        guard isSymbolicLink(entryURL) || isRegularFile(entryURL) else {
            return .absent
        }
        guard isSafelyContained, isRegularFile(resolvedEntryURL) else {
            return .unsafe(
                message: "Entry file must remain readable within its authorized package and root"
            )
        }
        return .readable(resolvedEntryURL)
    }

    private func diagnosticCandidate(
        installationURL: URL,
        resolvedTarget: URL?,
        agentIDs: Set<String>,
        entryFilename: String,
        rootID: String,
        message: String
    ) -> ScannedSkill {
        ScannedSkill(
            installation: SkillInstallation(
                path: installationURL,
                resolvedTarget: resolvedTarget,
                agentIDs: agentIDs
            ),
            document: ParsedSkillDocument(
                title: installationURL.lastPathComponent,
                issues: [ParseIssue(message: message)]
            ),
            rootIDs: [rootID],
            entryFilename: entryFilename
        )
    }

    private func isAccessibleRoot(_ url: URL, authorizedURLs: [URL]) -> Bool {
        guard isSymbolicLink(url) else { return isDirectory(url) }
        let target = url.resolvingSymlinksInPath().standardizedFileURL
        return isWithinAuthorizedRoots(
            standardizedURL: url.standardizedFileURL,
            resolvedURL: target,
            authorizedURLs: authorizedURLs
        ) && isDirectory(target)
    }

    private static func isValidEntryFilename(_ entryFilename: String) -> Bool {
        !entryFilename.isEmpty
            && entryFilename != "."
            && entryFilename != ".."
            && !entryFilename.contains("/")
            && !entryFilename.contains("\\")
    }

    private func validatedDefinitions(
        _ definitions: [AgentDefinition]
    ) -> (definitions: [AgentDefinition], issues: [ScanIssue]) {
        var valid: [AgentDefinition] = []
        var issues: [ScanIssue] = []
        for definition in definitions {
            if Self.isValidEntryFilename(definition.entryFilename) {
                valid.append(definition)
            } else {
                issues.append(invalidEntryFilenameIssue(
                    definition.entryFilename,
                    agentID: definition.id
                ))
            }
        }
        return (valid, issues)
    }

    private func invalidEntryFilenameIssue(
        _ entryFilename: String,
        agentID: String? = nil
    ) -> ScanIssue {
        let owner = agentID.map { " for Agent \($0)" } ?? ""
        return ScanIssue(
            message: "Invalid entryFilename\(owner): \(String(reflecting: entryFilename))"
        )
    }

    private func isContained(
        standardizedURL: URL,
        resolvedURL: URL,
        in root: URL
    ) -> Bool {
        containsByPathComponents(standardizedURL, in: root.standardizedFileURL)
            && containsByPathComponents(resolvedURL, in: root.resolvingSymlinksInPath())
    }

    private func isWithinAuthorizedRoots(
        standardizedURL: URL,
        resolvedURL: URL,
        authorizedURLs: [URL]
    ) -> Bool {
        authorizedURLs.contains { root in
            isContained(
                standardizedURL: standardizedURL,
                resolvedURL: resolvedURL,
                in: root
            )
        }
    }

    private func containsByPathComponents(_ candidate: URL, in root: URL) -> Bool {
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        let rootComponents = root.standardizedFileURL.pathComponents
        return candidateComponents.count >= rootComponents.count
            && Array(candidateComponents.prefix(rootComponents.count)) == rootComponents
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

private enum EntryInspection {
    case absent
    case readable(URL)
    case unsafe(message: String)
}
