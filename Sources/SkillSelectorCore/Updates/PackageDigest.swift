import CryptoKit
import Darwin
import Foundation

public enum PackageDigestError: Error, Equatable, Sendable {
    case packageMissing
    case unsupportedItem(String)
    case fileTooLarge(String)
    case totalBytesExceeded
    case tooManyFiles
}

public struct PackageDigestLimits: Hashable, Sendable {
    public let maximumFileBytes: Int64
    public let maximumTotalBytes: Int64
    public let maximumFileCount: Int

    public init(
        maximumFileBytes: Int64 = 100 * 1_024 * 1_024,
        maximumTotalBytes: Int64 = 100 * 1_024 * 1_024,
        maximumFileCount: Int = 2_000
    ) {
        self.maximumFileBytes = maximumFileBytes
        self.maximumTotalBytes = maximumTotalBytes
        self.maximumFileCount = maximumFileCount
    }
}

public struct PackageDigest: Codable, Hashable, Sendable, CustomStringConvertible {
    public let value: String
    public var description: String { value }

    public init(value: String) {
        self.value = value
    }

    public static func compute(
        at packageURL: URL,
        limits: PackageDigestLimits = PackageDigestLimits()
    ) throws -> PackageDigest {
        let entries = try digestEntries(at: packageURL)
        var hasher = SHA256()
        var totalBytes: Int64 = 0
        var fileCount = 0
        for entry in entries {
            append(Data(entry.path.utf8), to: &hasher)
            append(Data(entry.kind.rawValue.utf8), to: &hasher)
            append(Data(entry.isExecutable ? "1".utf8 : "0".utf8), to: &hasher)
            fileCount += 1
            guard fileCount <= limits.maximumFileCount else {
                throw PackageDigestError.tooManyFiles
            }
            guard entry.byteCount <= limits.maximumFileBytes else {
                throw PackageDigestError.fileTooLarge(entry.path)
            }
            guard totalBytes <= Int64.max - entry.byteCount,
                  totalBytes + entry.byteCount <= limits.maximumTotalBytes else {
                throw PackageDigestError.totalBytesExceeded
            }
            totalBytes += entry.byteCount
            append(UInt64(entry.byteCount), to: &hasher)
            if entry.kind == .symbolicLink {
                hasher.update(data: entry.content)
            } else {
                let handle = try FileHandle(forReadingFrom: entry.url)
                defer { try? handle.close() }
                while true {
                    let chunk = try handle.read(upToCount: 1 * 1_024 * 1_024) ?? Data()
                    if chunk.isEmpty { break }
                    hasher.update(data: chunk)
                }
            }
        }
        return PackageDigest(value: hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }

    private struct DigestEntry {
        let path: String
        let kind: PackageManifestEntry.Kind
        let isExecutable: Bool
        let content: Data
        let url: URL
        let byteCount: Int64
    }

    private static func digestEntries(at packageURL: URL) throws -> [DigestEntry] {
        let root = packageURL.standardizedFileURL
        var status = stat()
        guard root.path.withCString({ Darwin.lstat($0, &status) }) == 0,
              status.st_mode & S_IFMT == S_IFDIR else {
            throw PackageDigestError.packageMissing
        }
        var result: [DigestEntry] = []
        try walkDigest(directory: root, relativePrefix: "", result: &result)
        return result.sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
    }

    private static func walkDigest(
        directory: URL,
        relativePrefix: String,
        result: inout [DigestEntry]
    ) throws {
        for child in try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: []
        ) {
            if child.lastPathComponent == ".git" || PackageManifest.excludedNames.contains(child.lastPathComponent) {
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
                try walkDigest(directory: child, relativePrefix: relativePath, result: &result)
            case S_IFREG:
                result.append(DigestEntry(
                    path: relativePath,
                    kind: .file,
                    isExecutable: status.st_mode & 0o111 != 0,
                    content: Data(),
                    url: child,
                    byteCount: Int64(status.st_size)
                ))
            case S_IFLNK:
                let target = try FileManager.default.destinationOfSymbolicLink(atPath: child.path)
                let bytes = Data(target.utf8)
                result.append(DigestEntry(
                    path: relativePath,
                    kind: .symbolicLink,
                    isExecutable: false,
                    content: bytes,
                    url: child,
                    byteCount: Int64(bytes.count)
                ))
            default:
                throw PackageDigestError.unsupportedItem(relativePath)
            }
        }
    }

    private static func append(_ value: UInt64, to hasher: inout SHA256) {
        var value = value.bigEndian
        withUnsafeBytes(of: &value) { hasher.update(data: Data($0)) }
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
