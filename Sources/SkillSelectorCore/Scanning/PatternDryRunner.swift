import Foundation

/// One directory under an authorized project root whose path matched at
/// least one draft pattern, together with the Skill installations a scan
/// would discover inside it.
public struct PatternDryRunMatch: Hashable, Sendable, Identifiable {
    /// The matched container directory, absolute.
    public let url: URL
    /// The draft patterns that matched this directory's path.
    public let patterns: [String]
    /// Values bound by `{name}` template segments, e.g. `["modeSlug": "lint"]`.
    public let bindings: [String: String]
    /// Names of the immediate children that contain the entry file — the
    /// installations a scan would discover from this match.
    public let skillNames: [String]

    public var id: String { url.path }
}

public struct PatternDryRunReport: Hashable, Sendable {
    public let matches: [PatternDryRunMatch]
    /// Project roots that could not be read (missing or unresolvable).
    public let skippedRootPaths: [String]

    public init(matches: [PatternDryRunMatch], skippedRootPaths: [String]) {
        self.matches = matches
        self.skippedRootPaths = skippedRootPaths
    }

    public var isEmpty: Bool {
        matches.isEmpty
    }
}

/// Previews which directories a set of project patterns would match,
/// without touching the index: a stat-only walk of the authorized project
/// roots using the same suffix-matching engine, skip list, and
/// stop-at-recognized-installation rule as the scanner, so a draft custom
/// Agent can be validated before it is saved.
public struct PatternDryRunner: Sendable {
    public init() {}

    public func run(
        patterns: [String],
        roots: [AuthorizedRootSnapshot],
        entryFilename: String
    ) -> PatternDryRunReport {
        let uniquePatterns = Self.uniquePatterns(patterns)
        guard !uniquePatterns.isEmpty else {
            return PatternDryRunReport(matches: [], skippedRootPaths: [])
        }

        var matches: [PatternDryRunMatch] = []
        var skippedRootPaths: [String] = []
        for root in roots {
            do {
                try walk(
                    root.url.standardizedFileURL,
                    relativeComponents: [],
                    patterns: uniquePatterns,
                    entryFilename: entryFilename,
                    matches: &matches
                )
            } catch {
                skippedRootPaths.append(root.url.path)
            }
        }
        return PatternDryRunReport(
            matches: matches.sorted { $0.url.path < $1.url.path },
            skippedRootPaths: skippedRootPaths
        )
    }

    // MARK: - Walk

    private struct DirectoryMatch {
        let patterns: [String]
        let bindings: [String: String]
    }

    private func walk(
        _ directory: URL,
        relativeComponents: [String],
        patterns: [String],
        entryFilename: String,
        matches: inout [PatternDryRunMatch]
    ) throws {
        let children = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        )

        // A directory whose own path suffix-matches a pattern is a skill
        // container: its children are the installation candidates.
        let containerMatch = relativeComponents.isEmpty
            ? nil
            : match(relativeComponents, patterns: patterns)
        if let containerMatch {
            matches.append(
                PatternDryRunMatch(
                    url: directory,
                    patterns: containerMatch.patterns,
                    bindings: containerMatch.bindings,
                    skillNames: Self.skillNames(
                        in: children,
                        entryFilename: entryFilename
                    )
                )
            )
        }

        for child in children
        where !SkillScanner.skippedDirectoryNames.contains(child.lastPathComponent) {
            // Mirrors the scanner: symlinks are installation candidates but
            // are never walked into.
            if isSymbolicLink(child) { continue }
            guard isDirectory(child) else { continue }
            // Mirrors the scanner's stop rule: a child holding the entry file
            // is a recognized installation, and the walk does not descend
            // into it.
            if containerMatch != nil,
               Self.hasEntry(child, entryFilename: entryFilename) {
                continue
            }
            try walk(
                child,
                relativeComponents: relativeComponents + [child.lastPathComponent],
                patterns: patterns,
                entryFilename: entryFilename,
                matches: &matches
            )
        }
    }

    private func match(
        _ components: [String],
        patterns: [String]
    ) -> DirectoryMatch? {
        var matchedPatterns: [String] = []
        var bindings: [String: String] = [:]
        for pattern in patterns {
            let patternComponents = pattern.split(separator: "/").map(String.init)
            guard let bound = TemplateMatching.suffixBindings(components, matches: patternComponents) else {
                continue
            }
            matchedPatterns.append(pattern)
            for (name, value) in bound {
                bindings[name] = value
            }
        }
        return matchedPatterns.isEmpty ? nil : DirectoryMatch(
            patterns: matchedPatterns,
            bindings: bindings
        )
    }

    // MARK: - File system

    private static func skillNames(in children: [URL], entryFilename: String) -> [String] {
        children
            .filter { !SkillScanner.skippedDirectoryNames.contains($0.lastPathComponent) }
            .filter { isDirectoryOrSymbolicLink($0) }
            .filter { hasEntry($0, entryFilename: entryFilename) }
            .map(\.lastPathComponent)
            .sorted()
    }

    private static func isDirectoryOrSymbolicLink(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ]) else {
            return false
        }
        return values.isDirectory == true || values.isSymbolicLink == true
    }

    private static func hasEntry(_ directory: URL, entryFilename: String) -> Bool {
        FileManager.default.fileExists(
            atPath: directory.appending(path: entryFilename).path
        )
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    private static func uniquePatterns(_ patterns: [String]) -> [String] {
        var seen = Set<String>()
        return patterns
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
