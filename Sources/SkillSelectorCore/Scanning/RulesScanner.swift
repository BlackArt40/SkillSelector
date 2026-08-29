import Foundation

/// Scans authorized roots for Agent rules files (`CLAUDE.md`, `AGENTS.md`,
/// `.cursorrules`, …). Read-only, mirrors `McpScanner`: only paths inside
/// already-authorized roots are touched, and files are size-bounded.
public struct RulesScanner: Sendable {
    public init() {}

    /// Upper bound for a rules file we report. Mirrors the entry-file and
    /// MCP-config caps: an oversized rules file is skipped, not read.
    public static let maximumRulesFileBytes = 1_048_576

    /// Scans the given authorized roots for rules files.
    ///
    /// - Parameter homeRoot: the authorized `.home` root (or a system root
    ///   holding user-level configs). Global rules paths resolve against it.
    /// - Parameter projectRoots: authorized `.project` roots. Project rules
    ///   files resolve inside each.
    public func scan(
        homeRoot: AuthorizedRootSnapshot?,
        projectRoots: [AuthorizedRootSnapshot]
    ) -> [RulesFileDescriptor] {
        var seen = Set<String>()
        var files: [RulesFileDescriptor] = []

        func append(
            _ url: URL,
            agentID: String,
            projectRootID: String?,
            authorizedRoot: URL
        ) {
            let url = url.standardizedFileURL
            // Guard containment (defense-in-depth: registry paths are fixed
            // but a stray component must never escape the root) and report
            // regular files only, bounded by the read-size cap.
            guard url.isContained(in: authorizedRoot.standardizedFileURL),
                  seen.insert(url.path).inserted,
                  let values = try? url.resourceValues(forKeys: [
                      .isRegularFileKey,
                      .fileSizeKey,
                      .contentModificationDateKey,
                  ]),
                  values.isRegularFile == true,
                  let fileSize = values.fileSize,
                  fileSize <= Self.maximumRulesFileBytes else { return }
            files.append(RulesFileDescriptor(
                path: url.path,
                filename: url.lastPathComponent,
                agentID: agentID,
                projectRootID: projectRootID,
                fileSize: fileSize,
                modificationDate: values.contentModificationDate
            ))
        }

        // Lists a declared rules directory's immediate children and reports
        // the regular files whose extension matches — one level, no
        // recursion (same explicit-bounded-walk discipline as the Skill
        // scanner). Each child still goes through the full `append`
        // guards: containment, dedup, regular-file check, read-size cap.
        func appendDirectoryContents(
            _ directoryURL: URL,
            extensions: Set<String>,
            agentID: String,
            projectRootID: String?,
            authorizedRoot: URL
        ) {
            guard !extensions.isEmpty else { return }
            let children = (try? FileManager.default.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: nil,
                options: []
            )) ?? []
            for child in children where Self.matches(child, extensions: extensions) {
                append(
                    child,
                    agentID: agentID,
                    projectRootID: projectRootID,
                    authorizedRoot: authorizedRoot
                )
            }
        }

        // Matches the wildcard name against the parent directory's
        // immediate subdirectories, then lists each matched directory via
        // the fixed-directory path. Only the last segment may carry a
        // wildcard — anything else is ignored.
        func appendPatternDirectoryContents(
            _ parentURL: URL,
            pattern: String,
            extensions: Set<String>,
            agentID: String,
            projectRootID: String?,
            authorizedRoot: URL
        ) {
            guard !parentURL.path.contains("*") else { return }
            let entries = (try? FileManager.default.contentsOfDirectory(
                at: parentURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            )) ?? []
            let directories = entries.filter { entry in
                (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                    && Self.matchesGlob(entry.lastPathComponent, pattern: pattern)
            }
            for directory in directories.sorted(by: { $0.path < $1.path }) {
                appendDirectoryContents(
                    directory,
                    extensions: extensions,
                    agentID: agentID,
                    projectRootID: projectRootID,
                    authorizedRoot: authorizedRoot
                )
            }
        }

        // Dispatches a declared rules directory: a fixed path lists its
        // immediate children; a wildcard in the last segment ("rules-*")
        // matches sibling directories by name and lists each one level
        // deep — same bounded, non-recursive discipline throughout.
        func appendDeclaredDirectory(
            _ directoryURL: URL,
            extensions: Set<String>,
            agentID: String,
            projectRootID: String?,
            authorizedRoot: URL
        ) {
            guard !extensions.isEmpty else { return }
            let lastComponent = directoryURL.lastPathComponent
            if lastComponent.contains("*") {
                appendPatternDirectoryContents(
                    directoryURL.deletingLastPathComponent(),
                    pattern: lastComponent,
                    extensions: extensions,
                    agentID: agentID,
                    projectRootID: projectRootID,
                    authorizedRoot: authorizedRoot
                )
            } else {
                appendDirectoryContents(
                    directoryURL,
                    extensions: extensions,
                    agentID: agentID,
                    projectRootID: projectRootID,
                    authorizedRoot: authorizedRoot
                )
            }
        }

        for declaration in RulesRegistry.globalDeclarations {
            guard let homeRoot else { continue }
            if let globalPath = declaration.globalPath,
               let url = McpScanner.resolve(
                   globalPath: globalPath,
                   relativeTo: homeRoot.url
               ) {
                append(
                    url,
                    agentID: declaration.agentID,
                    projectRootID: nil,
                    authorizedRoot: homeRoot.url
                )
            }
            if let globalDirectory = declaration.globalDirectory,
               let url = McpScanner.resolve(
                   globalPath: globalDirectory,
                   relativeTo: homeRoot.url
               ) {
                appendDeclaredDirectory(
                    url,
                    extensions: declaration.directoryExtensions,
                    agentID: declaration.agentID,
                    projectRootID: nil,
                    authorizedRoot: homeRoot.url
                )
            }
        }

        for root in projectRoots {
            for declaration in RulesRegistry.projectDeclarations {
                if let projectPath = declaration.projectPath {
                    let url = root.url.appendingPathComponent(projectPath).standardizedFileURL
                    append(
                        url,
                        agentID: declaration.agentID,
                        projectRootID: root.id,
                        authorizedRoot: root.url
                    )
                }
                if let projectDirectory = declaration.projectDirectory {
                    let url = root.url.appendingPathComponent(projectDirectory)
                        .standardizedFileURL
                    appendDeclaredDirectory(
                        url,
                        extensions: declaration.directoryExtensions,
                        agentID: declaration.agentID,
                        projectRootID: root.id,
                        authorizedRoot: root.url
                    )
                }
            }
        }

        return files.sorted { $0.path < $1.path }
    }

    /// A child matches a declared entry when the entry names its extension
    /// ("md", "mdc") or is a filename suffix with a dot boundary
    /// ("instructions.md" matches "python.instructions.md" but not
    /// "myinstructions.md"). Case-insensitive on both sides.
    static func matches(_ child: URL, extensions: Set<String>) -> Bool {
        let name = child.lastPathComponent.lowercased()
        return extensions.contains { entry in
            name == entry || name.hasSuffix(".\(entry)")
        }
    }

    /// Single-wildcard glob for directory names ("rules-*"): '*' matches
    /// any run of characters, everything else is literal. Case-insensitive.
    static func matchesGlob(_ name: String, pattern: String) -> Bool {
        guard pattern.contains("*") else { return name == pattern }
        let source = pattern
            .split(separator: "*", omittingEmptySubsequences: false)
            .map { NSRegularExpression.escapedPattern(for: String($0)) }
            .joined(separator: ".*")
        let regex = try? NSRegularExpression(
            pattern: "^\(source)$",
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        )
        return regex?.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
    }
}
