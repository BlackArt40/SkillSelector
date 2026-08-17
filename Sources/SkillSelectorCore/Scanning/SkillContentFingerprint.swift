import CryptoKit
import Foundation

/// Content-only SHA-256 fingerprint of a Skill directory, stable across
/// copies: it hashes relative paths, node kinds, symlink destinations, and
/// file bytes — never file identifiers or timestamps, which differ between
/// two identical copies and would defeat duplicate grouping.
public enum SkillContentFingerprint {
    public static func compute(rootDirectory: URL) throws -> String {
        var hash = SHA256()
        try append(rootDirectory, relativePath: ".", hash: &hash)
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func append(
        _ url: URL,
        relativePath: String,
        hash: inout SHA256
    ) throws {
        let values = try url.resourceValues(forKeys: [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ])
        hash.update(data: Data(relativePath.utf8))
        if values.isSymbolicLink == true {
            hash.update(data: Data("link".utf8))
            hash.update(data: Data(
                try FileManager.default.destinationOfSymbolicLink(atPath: url.path).utf8
            ))
            return
        }
        if values.isDirectory == true {
            hash.update(data: Data("directory".utf8))
            let children = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isSymbolicLinkKey],
                options: []
            ).sorted { $0.lastPathComponent < $1.lastPathComponent }
            for child in children {
                let childPath = relativePath == "."
                    ? child.lastPathComponent
                    : "\(relativePath)/\(child.lastPathComponent)"
                try append(child, relativePath: childPath, hash: &hash)
            }
            return
        }
        guard values.isRegularFile == true else {
            hash.update(data: Data("other".utf8))
            return
        }
        hash.update(data: Data("file".utf8))
        hash.update(data: Data(try Data(contentsOf: url, options: .mappedIfSafe)))
    }
}
