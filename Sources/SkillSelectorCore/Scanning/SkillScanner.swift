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
                    for (rootID, agentIDs) in candidate.agentIDsByRoot {
                        existing.agentIDsByRoot[rootID, default: []].formUnion(agentIDs)
                    }
                    existing.installation.agentIDs = existing.agentIDs
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
                    availability: .unavailable(reason: "Root is missing or is not a readable directory"),
                    unavailableDiagnostic: StructuredDiagnostic(code: .rootUnreadable)
                ),
                []
            )
        }

        do {
            let installations: [ScannedSkill]
            let issues: [ScanIssue]
            switch root.kind {
            case .skillDirectory(let agentIDs, let entryFilename):
                if EntryFilename.isValid(entryFilename) {
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
                let validation = validatedDeclarations(registry.projectDeclarations)
                installations = try scanProject(
                    root,
                    declarations: validation.declarations,
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
            let detail = String(describing: error)
            return (
                ScannedRoot(
                    id: root.id,
                    url: root.url,
                    availability: .unavailable(reason: detail),
                    unavailableDiagnostic: StructuredDiagnostic(
                        code: .scanFailed,
                        arguments: [detail]
                    )
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
            authorizedURLs: authorizedURLs,
            sourceDiscoveryRootURL: root.url
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
                authorizedURLs: authorizedURLs,
                sourceDiscoveryRootURL: root.url
            )
        }
    }

    private func scanProject(
        _ root: ScanRoot,
        declarations: [SkillRootDeclaration],
        authorizedURLs: [URL]
    ) throws -> [ScannedSkill] {
        var installations: [ScannedSkill] = []
        try walkProjectDirectory(
            root.url,
            relativeComponents: [],
            root: root,
            declarations: declarations,
            authorizedURLs: authorizedURLs,
            installations: &installations
        )
        return installations
    }

    private func walkProjectDirectory(
        _ directory: URL,
        relativeComponents: [String],
        root: ScanRoot,
        declarations: [SkillRootDeclaration],
        authorizedURLs: [URL],
        installations: inout [ScannedSkill]
    ) throws {
        if !relativeComponents.isEmpty,
           let candidate = makeProjectCandidate(
               installationURL: directory,
               entries: matchingEntries(
                   in: relativeComponents,
                   declarations: declarations
               ),
               rootID: root.id,
               authorizedURLs: authorizedURLs,
               sourceDiscoveryRootURL: root.url
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
                        declarations: declarations
                    ),
                    rootID: root.id,
                    authorizedURLs: authorizedURLs,
                    sourceDiscoveryRootURL: root.url
                ) else {
                    continue
                }
                installations.append(candidate)
            } else {
                try walkProjectDirectory(
                    child,
                    relativeComponents: childComponents,
                    root: root,
                    declarations: declarations,
                    authorizedURLs: authorizedURLs,
                    installations: &installations
                )
            }
        }
    }

    private func matchingEntries(
        in skillDirectoryComponents: [String],
        declarations: [SkillRootDeclaration]
    ) -> [(agentIDs: Set<String>, entryFilename: String)] {
        let parentComponents = Array(skillDirectoryComponents.dropLast())
        let matches = declarations.compactMap { declaration -> (Set<String>, String)? in
            let components = declaration.value.split(separator: "/").map(String.init)
            guard TemplateMatching.suffix(parentComponents, matches: components) else { return nil }
            return (declaration.agentID.map { Set([$0]) } ?? [], declaration.entryFilename)
        }

        return Dictionary(grouping: matches, by: { $0.1 }).map { entryFilename, values in
            (values.reduce(into: Set<String>()) { $0.formUnion($1.0) }, entryFilename)
        }.sorted { lhs, rhs in
            if lhs.entryFilename == "SKILL.md" { return true }
            if rhs.entryFilename == "SKILL.md" { return false }
            return lhs.entryFilename < rhs.entryFilename
        }
    }

    private func makeProjectCandidate(
        installationURL: URL,
        entries: [(agentIDs: Set<String>, entryFilename: String)],
        rootID: String,
        authorizedURLs: [URL],
        sourceDiscoveryRootURL: URL
    ) -> ScannedSkill? {
        var result: ScannedSkill?
        for match in entries {
            guard let candidate = makeCandidate(
                installationURL: installationURL,
                agentIDs: match.agentIDs,
                entryFilename: match.entryFilename,
                rootID: rootID,
                authorizedURLs: authorizedURLs,
                sourceDiscoveryRootURL: sourceDiscoveryRootURL
            ) else {
                continue
            }
            if var existing = result {
                for (candidateRootID, agentIDs) in candidate.agentIDsByRoot {
                    existing.agentIDsByRoot[candidateRootID, default: []].formUnion(agentIDs)
                }
                existing.installation.agentIDs = existing.agentIDs
                result = existing
            } else {
                result = candidate
            }
        }
        return result
    }

    private func makeCandidate(
        installationURL: URL,
        agentIDs: Set<String>,
        entryFilename: String,
        rootID: String,
        authorizedURLs: [URL],
        sourceDiscoveryRootURL: URL
    ) -> ScannedSkill? {
        guard EntryFilename.isValid(entryFilename) else { return nil }

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
        case .unsafe:
            return diagnosticCandidate(
                installationURL: installationURL,
                resolvedTarget: resolvedTarget,
                agentIDs: agentIDs,
                entryFilename: entryFilename,
                rootID: rootID,
                diagnostic: StructuredDiagnostic(code: .unsafeEntryFile)
            )
        case .readable(let url):
            resolvedEntryURL = url
        }

        var document: ParsedSkillDocument
        do {
            document = FrontmatterParser.parse(
                try String(contentsOf: resolvedEntryURL, encoding: .utf8)
            )
        } catch {
            let detail = error.localizedDescription
            document = ParsedSkillDocument(
                title: installationURL.lastPathComponent,
                issues: [
                    ParseIssue(
                        code: .unableToReadEntry,
                        arguments: [entryFilename, detail]
                    ),
                ]
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
            agentIDsByRoot: [rootID: agentIDs],
            entryFilename: entryFilename,
            entryModificationDate: modificationDate,
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
            return .unsafe
        }
        return .readable(resolvedEntryURL)
    }

    private func diagnosticCandidate(
        installationURL: URL,
        resolvedTarget: URL?,
        agentIDs: Set<String>,
        entryFilename: String,
        rootID: String,
        diagnostic: StructuredDiagnostic
    ) -> ScannedSkill {
        ScannedSkill(
            installation: SkillInstallation(
                path: installationURL,
                resolvedTarget: resolvedTarget,
                agentIDs: agentIDs
            ),
            document: ParsedSkillDocument(
                title: installationURL.lastPathComponent,
                issues: [
                    ParseIssue(
                        message: diagnostic.fallbackMessage,
                        diagnostic: diagnostic
                    ),
                ]
            ),
            agentIDsByRoot: [rootID: agentIDs],
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

    private func validatedDeclarations(
        _ declarations: [SkillRootDeclaration]
    ) -> (declarations: [SkillRootDeclaration], issues: [ScanIssue]) {
        var valid: [SkillRootDeclaration] = []
        var issues: [ScanIssue] = []
        for declaration in declarations {
            if EntryFilename.isValid(declaration.entryFilename) {
                valid.append(declaration)
            } else {
                issues.append(invalidEntryFilenameIssue(
                    declaration.entryFilename,
                    agentID: declaration.agentID
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
            containsByPathComponents(standardizedURL, in: root.standardizedFileURL)
        } && authorizedURLs.contains { root in
            containsByPathComponents(
                resolvedURL,
                in: root.resolvingSymlinksInPath().standardizedFileURL
            )
        }
    }

    private func containsByPathComponents(_ candidate: URL, in root: URL) -> Bool {
        candidate.standardizedFileURL.isContained(in: root.standardizedFileURL)
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
    case unsafe
}
