import Foundation

/// A stat-only snapshot of one Skill installation's file tree: relative
/// path, node kind, size, modification date, and symlink destinations. No
/// content is read, so building one costs one traversal of `stat` calls —
/// orders of magnitude cheaper than reading, YAML-parsing, and hashing.
///
/// Two snapshots comparing equal means the derived data (parsed document,
/// content fingerprint) cannot have changed, except for an edit that
/// preserves both size and sub-second mtime — the same residual risk every
/// mtime-based incremental tool (rsync class) accepts.
public struct SkillScanState: Codable, Hashable, Sendable {
    public enum EntryKind: String, Codable, Hashable, Sendable {
        case file
        case directory
        case symbolicLink
        case other
    }

    public struct Entry: Codable, Hashable, Sendable {
        public let relativePath: String
        public let kind: EntryKind
        public let size: Int64?
        public let modificationDate: Date?
        public let symlinkDestination: String?

        init(
            relativePath: String,
            kind: EntryKind,
            size: Int64? = nil,
            modificationDate: Date? = nil,
            symlinkDestination: String? = nil
        ) {
            self.relativePath = relativePath
            self.kind = kind
            self.size = size
            self.modificationDate = modificationDate
            self.symlinkDestination = symlinkDestination
        }
    }

    /// Which entry file the state was captured for; a different entry
    /// filename must re-parse even when the tree is otherwise unchanged.
    public let entryFilename: String
    /// The installation root's resolved symlink target, nil for regular
    /// directories; retargeting a link invalidates the state.
    public let resolvedTarget: String?
    /// Recursive, sorted by relative path.
    public let entries: [Entry]
}

/// Everything derived from file contents that a cache hit may reuse.
public struct ScannedSkillCacheEntry: Codable, Hashable, Sendable {
    public let state: SkillScanState
    public let document: ParsedSkillDocument
    public let contentFingerprint: String?
    public let entryModificationDate: Date?

    public init(
        state: SkillScanState,
        document: ParsedSkillDocument,
        contentFingerprint: String?,
        entryModificationDate: Date?
    ) {
        self.state = state
        self.document = document
        self.contentFingerprint = contentFingerprint
        self.entryModificationDate = entryModificationDate
    }
}

/// Cache handed to the scanner: last-known scan results by standardized
/// installation path. Loaded from the index before a refresh, written back
/// through the report afterwards.
public struct SkillScanCache: Sendable {
    public let entriesByPath: [String: ScannedSkillCacheEntry]

    public init(entriesByPath: [String: ScannedSkillCacheEntry] = [:]) {
        self.entriesByPath = entriesByPath
    }

    public static let empty = SkillScanCache()
}

enum ScanStateBuilder {
    /// Walks the content directory collecting stat metadata only.
    static func build(
        contentDirectory: URL,
        entryFilename: String,
        resolvedTarget: URL?
    ) -> SkillScanState {
        var entries: [SkillScanState.Entry] = []
        appendEntries(
            for: contentDirectory,
            relativePath: ".",
            into: &entries
        )
        return SkillScanState(
            entryFilename: entryFilename,
            resolvedTarget: resolvedTarget?.standardizedFileURL.path,
            entries: entries
        )
    }

    private static func appendEntries(
        for url: URL,
        relativePath: String,
        into entries: inout [SkillScanState.Entry]
    ) {
        let values = try? url.resourceValues(forKeys: [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .contentModificationDateKey,
        ])
        let isLink = values?.isSymbolicLink == true
        let kind: SkillScanState.EntryKind
        if isLink {
            kind = .symbolicLink
        } else if values?.isDirectory == true {
            kind = .directory
        } else if values?.isRegularFile == true {
            kind = .file
        } else {
            kind = .other
        }
        entries.append(SkillScanState.Entry(
            relativePath: relativePath,
            kind: kind,
            size: values?.isRegularFile == true ? Int64(values?.fileSize ?? 0) : nil,
            modificationDate: values?.contentModificationDate,
            symlinkDestination: isLink
                ? (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path))
                : nil
        ))
        guard kind == .directory else { return }
        let children = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: []
        )) ?? []
        for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let childPath = relativePath == "."
                ? child.lastPathComponent
                : "\(relativePath)/\(child.lastPathComponent)"
            appendEntries(for: child, relativePath: childPath, into: &entries)
        }
    }
}
