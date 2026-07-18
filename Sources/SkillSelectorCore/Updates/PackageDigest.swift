import CryptoKit
import Darwin
import Foundation

public enum PackageDigestError: Error, Equatable, Sendable {
    case packageMissing
    case unsupportedItem(String)
    case sourceChanged(String)
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

/// Test-only observation points for filesystem race regression coverage.
struct PackageDigestHooks {
    var entryDiscovered: (() -> Void)?
    var directoryChildDiscovered: (() -> Void)?
    var beforeFileOpen: ((String) throws -> Void)?
    var afterFileOpen: ((String) throws -> Void)?

    init(
        entryDiscovered: (() -> Void)? = nil,
        directoryChildDiscovered: (() -> Void)? = nil,
        beforeFileOpen: ((String) throws -> Void)? = nil,
        afterFileOpen: ((String) throws -> Void)? = nil
    ) {
        self.entryDiscovered = entryDiscovered
        self.directoryChildDiscovered = directoryChildDiscovered
        self.beforeFileOpen = beforeFileOpen
        self.afterFileOpen = afterFileOpen
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
        try compute(at: packageURL, limits: limits, hooks: PackageDigestHooks())
    }

    static func compute(
        at packageURL: URL,
        limits: PackageDigestLimits = PackageDigestLimits(),
        hooks: PackageDigestHooks
    ) throws -> PackageDigest {
        let root = packageURL.standardizedFileURL
        let rootFD = try openDirectory(at: root)
        defer { Darwin.close(rootFD) }
        var fileCount = 0
        let entries = try digestEntries(
            rootFD: rootFD,
            relativePrefix: "",
            limits: limits,
            fileCount: &fileCount,
            hooks: hooks
        ).sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
        var hasher = SHA256()
        var totalBytes: Int64 = 0
        for entry in entries {
            append(Data(entry.path.utf8), to: &hasher)
            append(Data(entry.kind.rawValue.utf8), to: &hasher)
            append(Data(entry.isExecutable ? "1".utf8 : "0".utf8), to: &hasher)
            switch entry.kind {
            case .directory:
                break
            case .symbolicLink:
                let content = try readLink(
                    entry.path,
                    rootFD: rootFD,
                    expected: entry.status
                )
                try validate(byteCount: Int64(content.count), path: entry.path, limits: limits, totalBytes: &totalBytes)
                append(UInt64(content.count), to: &hasher)
                hasher.update(data: content)
            case .file:
                try hooks.beforeFileOpen?(entry.path)
                let descriptor = try openRegular(entry.path, rootFD: rootFD, expected: entry.status)
                defer { Darwin.close(descriptor) }
                try hooks.afterFileOpen?(entry.path)
                let beforeReadStatus = try descriptorStatus(descriptor, path: entry.path)
                guard sameObject(beforeReadStatus, entry.status),
                      beforeReadStatus.st_mode & S_IFMT == S_IFREG else {
                    throw PackageDigestError.sourceChanged(entry.path)
                }
                guard beforeReadStatus.st_size <= limits.maximumFileBytes else {
                    throw PackageDigestError.fileTooLarge(entry.path)
                }
                guard sameSourceState(beforeReadStatus, entry.status) else {
                    throw PackageDigestError.sourceChanged(entry.path)
                }
                append(UInt64(beforeReadStatus.st_size), to: &hasher)
                let readCount = try hash(
                    descriptor,
                    path: entry.path,
                    hasher: &hasher,
                    limits: limits,
                    totalBytes: &totalBytes
                )
                let afterReadStatus = try descriptorStatus(descriptor, path: entry.path)
                guard sameSourceState(afterReadStatus, beforeReadStatus),
                      afterReadStatus.st_size == readCount,
                      try currentPathMatches(entry.path, rootFD: rootFD, expected: beforeReadStatus) else {
                    throw PackageDigestError.sourceChanged(entry.path)
                }
            }
        }
        return PackageDigest(value: hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }

    private struct DigestEntry {
        let path: String
        let kind: PackageManifestEntry.Kind
        let isExecutable: Bool
        let status: stat
    }

    private static func digestEntries(
        rootFD: Int32,
        relativePrefix: String,
        limits: PackageDigestLimits,
        fileCount: inout Int,
        hooks: PackageDigestHooks
    ) throws -> [DigestEntry] {
        var result: [DigestEntry] = []
        let names = try directoryNames(
            rootFD,
            maximumCount: limits.maximumFileCount - fileCount,
            hooks: hooks
        )
        fileCount += names.count
        for name in names {
            if name == ".git" || PackageManifest.excludedNames.contains(name) {
                continue
            }
            var status = stat()
            guard name.withCString({ Darwin.fstatat(rootFD, $0, &status, AT_SYMLINK_NOFOLLOW) }) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            let relativePath = relativePrefix.isEmpty
                ? name
                : "\(relativePrefix)/\(name)"
            switch status.st_mode & S_IFMT {
            case S_IFDIR:
                result.append(DigestEntry(
                    path: relativePath,
                    kind: .directory,
                    isExecutable: false,
                    status: status
                ))
                let childFD = try openDirectory(name, relativeTo: rootFD, expected: status)
                defer { Darwin.close(childFD) }
                result += try digestEntries(
                    rootFD: childFD,
                    relativePrefix: relativePath,
                    limits: limits,
                    fileCount: &fileCount,
                    hooks: hooks
                )
            case S_IFREG:
                try validateEntry(path: relativePath, status: status, kind: .file, limits: limits)
                result.append(DigestEntry(
                    path: relativePath,
                    kind: .file,
                    isExecutable: status.st_mode & 0o111 != 0,
                    status: status
                ))
            case S_IFLNK:
                try validateEntry(path: relativePath, status: status, kind: .symbolicLink, limits: limits)
                result.append(DigestEntry(
                    path: relativePath,
                    kind: .symbolicLink,
                    isExecutable: false,
                    status: status
                ))
            default:
                throw PackageDigestError.unsupportedItem(relativePath)
            }
        }
        return result
    }

    private static func validateEntry(
        path: String,
        status: stat,
        kind: PackageManifestEntry.Kind,
        limits: PackageDigestLimits
    ) throws {
        guard status.st_size <= limits.maximumFileBytes else { throw PackageDigestError.fileTooLarge(path) }
    }

    private static func openDirectory(at url: URL) throws -> Int32 {
        let descriptor = url.path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard descriptor >= 0 else { throw PackageDigestError.packageMissing }
        return descriptor
    }

    private static func openDirectory(_ name: String, relativeTo parentFD: Int32, expected: stat) throws -> Int32 {
        let descriptor = name.withCString { Darwin.openat(parentFD, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard descriptor >= 0 else { throw PackageDigestError.unsupportedItem(name) }
        var opened = stat()
        guard Darwin.fstat(descriptor, &opened) == 0, sameObject(opened, expected) else {
            Darwin.close(descriptor)
            throw PackageDigestError.unsupportedItem(name)
        }
        return descriptor
    }

    private static func directoryNames(
        _ descriptor: Int32,
        maximumCount: Int,
        hooks: PackageDigestHooks
    ) throws -> [String] {
        let duplicate = Darwin.dup(descriptor)
        guard duplicate >= 0, let directory = Darwin.fdopendir(duplicate) else {
            if duplicate >= 0 { Darwin.close(duplicate) }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.closedir(directory) }
        let boundedCount = max(0, maximumCount)
        var names: [String] = []
        errno = 0
        while let entry = Darwin.readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
            }
            guard name != ".", name != ".." else {
                continue
            }
            names.append(name)
            hooks.directoryChildDiscovered?()
            guard names.count <= boundedCount else { throw PackageDigestError.tooManyFiles }
            hooks.entryDiscovered?()
        }
        guard errno == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return names.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    }

    private static func openRegular(_ path: String, rootFD: Int32, expected: stat) throws -> Int32 {
        let components = path.split(separator: "/").map(String.init)
        var parentFD = Darwin.dup(rootFD)
        guard parentFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(parentFD) }
        for component in components.dropLast() {
            let childFD = component.withCString { Darwin.openat(parentFD, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
            guard childFD >= 0 else { throw PackageDigestError.unsupportedItem(path) }
            Darwin.close(parentFD)
            parentFD = childFD
        }
        let name = components.last ?? ""
        let descriptor = name.withCString { Darwin.openat(parentFD, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
        guard descriptor >= 0 else { throw PackageDigestError.sourceChanged(path) }
        var opened = stat()
        guard Darwin.fstat(descriptor, &opened) == 0,
              sameSourceState(opened, expected),
              opened.st_mode & S_IFMT == S_IFREG else {
            Darwin.close(descriptor)
            throw PackageDigestError.sourceChanged(path)
        }
        return descriptor
    }

    private static func readLink(_ path: String, rootFD: Int32, expected: stat) throws -> Data {
        let components = path.split(separator: "/").map(String.init)
        var parentFD = Darwin.dup(rootFD)
        guard parentFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(parentFD) }
        for component in components.dropLast() {
            let childFD = component.withCString { Darwin.openat(parentFD, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
            guard childFD >= 0 else { throw PackageDigestError.unsupportedItem(path) }
            Darwin.close(parentFD)
            parentFD = childFD
        }
        let name = components.last ?? ""
        var buffer = [UInt8](repeating: 0, count: max(1, Int(expected.st_size) + 1))
        let count = try name.withCString { pointer -> Int in
            let result = Darwin.readlinkat(parentFD, pointer, &buffer, buffer.count)
            guard result >= 0 else { throw PackageDigestError.unsupportedItem(path) }
            return result
        }
        var current = stat()
        guard name.withCString({ Darwin.fstatat(parentFD, $0, &current, AT_SYMLINK_NOFOLLOW) }) == 0,
              sameSourceState(current, expected),
              current.st_mode & S_IFMT == S_IFLNK,
              count == Int(current.st_size) else {
            throw PackageDigestError.sourceChanged(path)
        }
        return Data(buffer.prefix(count))
    }

    private static func hash(
        _ descriptor: Int32,
        path: String,
        hasher: inout SHA256,
        limits: PackageDigestLimits,
        totalBytes: inout Int64
    ) throws -> Int64 {
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        var bytesRead: Int64 = 0
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count == 0 { break }
            guard count > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            guard bytesRead <= Int64.max - Int64(count) else { throw PackageDigestError.fileTooLarge(path) }
            bytesRead += Int64(count)
            guard bytesRead <= limits.maximumFileBytes else {
                throw PackageDigestError.fileTooLarge(path)
            }
            guard totalBytes <= Int64.max - Int64(count),
                  totalBytes + Int64(count) <= limits.maximumTotalBytes else {
                throw PackageDigestError.totalBytesExceeded
            }
            totalBytes += Int64(count)
            hasher.update(data: Data(buffer.prefix(count)))
        }
        return bytesRead
    }

    private static func validate(
        byteCount: Int64,
        path: String,
        limits: PackageDigestLimits,
        totalBytes: inout Int64
    ) throws {
        guard byteCount <= limits.maximumFileBytes else { throw PackageDigestError.fileTooLarge(path) }
        guard totalBytes <= Int64.max - byteCount,
              totalBytes + byteCount <= limits.maximumTotalBytes else {
            throw PackageDigestError.totalBytesExceeded
        }
        totalBytes += byteCount
    }

    private static func descriptorStatus(_ descriptor: Int32, path: String) throws -> stat {
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else {
            throw PackageDigestError.sourceChanged(path)
        }
        return status
    }

    private static func currentPathMatches(_ path: String, rootFD: Int32, expected: stat) throws -> Bool {
        var status = stat()
        let result = path.withCString { Darwin.fstatat(rootFD, $0, &status, AT_SYMLINK_NOFOLLOW) }
        guard result == 0 else { return false }
        return sameSourceState(status, expected)
    }

    private static func sameObject(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
    }

    private static func sameSourceState(_ lhs: stat, _ rhs: stat) -> Bool {
        sameObject(lhs, rhs)
            && lhs.st_mode & S_IFMT == rhs.st_mode & S_IFMT
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
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
    enum Kind: String, Hashable, Sendable { case directory, file, symbolicLink }
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
                result.append(PackageManifestEntry(
                    path: relativePath,
                    kind: .directory,
                    isExecutable: false,
                    content: Data()
                ))
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
