import CryptoKit
import Foundation

/// SHA-256 of a Skill's entry-file **body only** — everything outside the
/// YAML frontmatter. The fingerprint is stable across copies: frontmatter
/// (`name`, `description`, …), sibling files (`docs/`, `templates/`, …),
/// file names, paths, and timestamps never participate, so two copies of
/// the same Skill that differ only in metadata or sub-files still group as
/// duplicates.
public enum SkillContentFingerprint {
    /// Version marker of the body-only fingerprint algorithm. Older stores
    /// carry a directory-tree SHA-256 without any prefix; `isCurrentVersion`
    /// lets the incremental cache skip those entries so the next scan
    /// recomputes the body-only fingerprint (a one-time migration cost).
    public static let currentVersionPrefix = "v2:"

    /// True when the fingerprint was produced by the current algorithm.
    public static func isCurrentVersion(_ fingerprint: String) -> Bool {
        fingerprint.hasPrefix(currentVersionPrefix)
    }

    public enum Error: Swift.Error, LocalizedError {
        case oversizedEntry(limit: Int)

        public var errorDescription: String? {
            switch self {
            case .oversizedEntry(let limit):
                return "Entry file exceeds the \(limit) byte read limit"
            }
        }
    }

    /// Bound the read exactly like the scan/render path does (audit
    /// R3/F-01): a multi-GB SKILL.md inside an authorized root must not be
    /// slurped into memory while hashing (local DoS).
    public static func compute(entryFileURL: URL) throws -> String {
        let fileSize = try entryFileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard let fileSize, fileSize <= SkillDocumentReader.maximumRenderBytes else {
            throw Error.oversizedEntry(limit: SkillDocumentReader.maximumRenderBytes)
        }
        let text = try String(contentsOf: entryFileURL, encoding: .utf8)
        // bodyLines() tolerates whitespace around the delimiters and falls
        // back to the whole text when no frontmatter boundary exists — the
        // same single implementation the renderer uses.
        let body = FrontmatterParser.bodyLines(from: text).joined(separator: "\n")
        let digest = SHA256.hash(data: Data(body.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return currentVersionPrefix + digest
    }
}
