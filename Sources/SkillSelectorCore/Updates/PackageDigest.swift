import CryptoKit
import Darwin
import Foundation

public enum PackageDigestError: Error, Equatable, Sendable {
    case packageMissing
    case unsupportedItem(String)
    case fileTooLarge(String)
}

public struct PackageDigest: Codable, Hashable, Sendable, CustomStringConvertible {
    public let value: String
    public var description: String { value }

    public init(value: String) {
        self.value = value
    }

    public static func compute(at packageURL: URL) throws -> PackageDigest {
        let entries = try PackageManifest.read(at: packageURL)
        var hasher = SHA256()
        for entry in entries {
            append(Data(entry.path.utf8), to: &hasher)
            append(Data(entry.kind.rawValue.utf8), to: &hasher)
            append(Data(entry.isExecutable ? "1".utf8 : "0".utf8), to: &hasher)
            append(entry.content, to: &hasher)
        }
        return PackageDigest(value: hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }

    private static func append(_ data: Data, to hasher: inout SHA256) {
        var length = UInt64(data.count).bigEndian
        withUnsafeBytes(of: &length) { hasher.update(data: Data($0)) }
        hasher.update(data: data)
    }
}

struct PackageManifestEntry: Hashable, Sendable {
    enum Kind: String, Hashable, Sendable { case file, symbolicLink }
    let path: String
    let kind: Kind
    let isExecutable: Bool
    let content: Data
}

enum PackageManifest {
    static let excludedNames: Set<String> = [
        ".DS_Store",
        ".skillselector-index",
        ".skillselector-index.json",
    ]

    static func read(at packageURL: URL) throws -> [PackageManifestEntry] {
        let root = packageURL.standardizedFileURL
        var rootStatus = stat()
        guard root.path.withCString({ Darwin.lstat($0, &rootStatus) }) == 0,
              rootStatus.st_mode & S_IFMT == S_IFDIR else {
            throw PackageDigestError.packageMissing
        }
        var result: [PackageManifestEntry] = []
        try walk(directory: root, relativePrefix: "", result: &result)
        return result.sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
    }

    private static func walk(
        directory: URL,
        relativePrefix: String,
        result: inout [PackageManifestEntry]
    ) throws {
        let children = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: []
        )
        for child in children {
            if child.lastPathComponent == ".git" || excludedNames.contains(child.lastPathComponent) {
                continue
            }
            var status = stat()
            guard child.path.withCString({ Darwin.lstat($0, &status) }) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            let relativePath = relativePrefix.isEmpty
                ? child.lastPathComponent
                : "\(relativePrefix)/\(child.lastPathComponent)"
            switch status.st_mode & S_IFMT {
            case S_IFDIR:
                try walk(directory: child, relativePrefix: relativePath, result: &result)
            case S_IFREG:
                let bytes = try Data(contentsOf: child, options: [.mappedIfSafe])
                result.append(PackageManifestEntry(
                    path: relativePath,
                    kind: .file,
                    isExecutable: status.st_mode & 0o111 != 0,
                    content: bytes
                ))
            case S_IFLNK:
                let target = try FileManager.default.destinationOfSymbolicLink(atPath: child.path)
                result.append(PackageManifestEntry(
                    path: relativePath,
                    kind: .symbolicLink,
                    isExecutable: false,
                    content: Data(target.utf8)
                ))
            default:
                throw PackageDigestError.unsupportedItem(relativePath)
            }
        }
    }
}
