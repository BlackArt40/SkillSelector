import Darwin
import Compression
import Foundation

public struct PackageValidationLimits: Hashable, Sendable {
    public let maximumFileCount: Int
    public let maximumFileBytes: Int64
    public let maximumTotalBytes: Int64

    public init(
        maximumFileCount: Int = 2_000,
        maximumFileBytes: Int64 = 100 * 1_024 * 1_024,
        maximumTotalBytes: Int64 = 100 * 1_024 * 1_024
    ) {
        self.maximumFileCount = maximumFileCount
        self.maximumFileBytes = maximumFileBytes
        self.maximumTotalBytes = maximumTotalBytes
    }
}

enum SafeZIPExtractor {
    private struct Entry {
        let path: String
        let kind: PackageArchiveEntryKind
        let bytes: Data
        let mode: UInt32
    }

    static func extract(
        _ archive: Data,
        into destination: URL,
        validator: PackageValidator
    ) throws {
        let entries = try parse(archive, limits: validator.limits)
        try validator.validateArchiveEntries(entries.map {
            PackageArchiveEntry(
                path: $0.path,
                kind: $0.kind,
                byteCount: Int64($0.bytes.count),
                symbolicLinkTarget: $0.kind == .symbolicLink
                    ? String(data: $0.bytes, encoding: .utf8)
                    : nil
            )
        })
        try validateLayout(entries)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for entry in entries.sorted(by: { pathDepth($0.path) < pathDepth($1.path) }) {
            let output = destination.appending(path: entry.path)
            switch entry.kind {
            case .directory:
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            case .regularFile:
                try FileManager.default.createDirectory(
                    at: output.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try entry.bytes.write(to: output, options: .withoutOverwriting)
                if entry.mode & 0o111 != 0 {
                    try FileManager.default.setAttributes(
                        [.posixPermissions: NSNumber(value: entry.mode & 0o777)],
                        ofItemAtPath: output.path
                    )
                }
            case .symbolicLink:
                guard let target = String(data: entry.bytes, encoding: .utf8) else {
                    throw PackageValidationError.escapingSymbolicLink(entry.path)
                }
                try FileManager.default.createDirectory(
                    at: output.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try FileManager.default.createSymbolicLink(atPath: output.path, withDestinationPath: target)
            case .device:
                throw PackageValidationError.unsupportedItem(entry.path)
            }
        }
    }

    private static func parse(
        _ archive: Data,
        limits: PackageValidationLimits
    ) throws -> [Entry] {
        guard let eocd = endOfCentralDirectory(in: archive),
              readUInt16(archive, at: eocd + 4) == 0,
              readUInt16(archive, at: eocd + 6) == 0,
              let entryCount = readUInt16(archive, at: eocd + 10),
              entryCount != UInt16.max,
              let centralSize = readUInt32(archive, at: eocd + 12),
              let centralOffset = readUInt32(archive, at: eocd + 16),
              centralSize != UInt32.max,
              centralOffset != UInt32.max else {
            throw PackageValidationError.unsupportedItem("ZIP directory")
        }
        guard Int(entryCount) <= limits.maximumFileCount else {
            throw PackageValidationError.excessiveFileCount(maximum: limits.maximumFileCount)
        }
        let centralStart = Int(centralOffset)
        let centralEnd = centralStart + Int(centralSize)
        guard centralStart >= 0, centralEnd <= archive.count, centralEnd <= eocd else {
            throw PackageValidationError.unsupportedItem("ZIP directory")
        }
        var cursor = centralStart
        var entries: [Entry] = []
        entries.reserveCapacity(Int(entryCount))
        var totalUncompressedBytes: Int64 = 0
        for _ in 0..<entryCount {
            guard readUInt32(archive, at: cursor) == 0x0201_4b50,
                  let versionMade = readUInt16(archive, at: cursor + 4),
                  let flags = readUInt16(archive, at: cursor + 8),
                  flags & 0x0001 == 0,
                  let method = readUInt16(archive, at: cursor + 10),
                  method == 0 || method == 8,
                  let expectedCRC = readUInt32(archive, at: cursor + 16),
                  let compressedSize = readUInt32(archive, at: cursor + 20),
                  let uncompressedSize = readUInt32(archive, at: cursor + 24),
                  compressedSize != UInt32.max,
                  uncompressedSize != UInt32.max,
                  let nameLength = readUInt16(archive, at: cursor + 28),
                  let extraLength = readUInt16(archive, at: cursor + 30),
                  let commentLength = readUInt16(archive, at: cursor + 32),
                  let externalAttributes = readUInt32(archive, at: cursor + 38),
                  let localOffset = readUInt32(archive, at: cursor + 42),
                  localOffset != UInt32.max else {
                throw PackageValidationError.unsupportedItem("ZIP entry")
            }
            let declaredBytes = Int64(uncompressedSize)
            guard totalUncompressedBytes <= Int64.max - declaredBytes else {
                throw PackageValidationError.excessiveByteCount(maximum: limits.maximumTotalBytes)
            }
            totalUncompressedBytes += declaredBytes
            guard totalUncompressedBytes <= limits.maximumTotalBytes else {
                throw PackageValidationError.excessiveByteCount(maximum: limits.maximumTotalBytes)
            }
            let nameStart = cursor + 46
            let nameEnd = nameStart + Int(nameLength)
            let next = nameEnd + Int(extraLength) + Int(commentLength)
            guard nameEnd <= centralEnd, next <= centralEnd,
                  let path = String(data: archive[nameStart..<nameEnd], encoding: .utf8),
                  !path.unicodeScalars.contains("\0") else {
                throw PackageValidationError.unsupportedItem("ZIP entry name")
            }
            guard declaredBytes <= limits.maximumFileBytes else {
                throw PackageValidationError.fileTooLarge(path)
            }
            let local = Int(localOffset)
            guard readUInt32(archive, at: local) == 0x0403_4b50,
                  let localNameLength = readUInt16(archive, at: local + 26),
                  let localExtraLength = readUInt16(archive, at: local + 28) else {
                throw PackageValidationError.unsupportedItem(path)
            }
            let localNameStart = local + 30
            let localNameEnd = localNameStart + Int(localNameLength)
            let dataStart = localNameEnd + Int(localExtraLength)
            let dataEnd = dataStart + Int(compressedSize)
            guard localNameEnd <= archive.count,
                  archive[localNameStart..<localNameEnd] == archive[nameStart..<nameEnd],
                  dataEnd <= archive.count else {
                throw PackageValidationError.unsupportedItem(path)
            }
            let compressed = Data(archive[dataStart..<dataEnd])
            let bytes = try decompress(
                compressed,
                method: method,
                expectedSize: Int(uncompressedSize),
                path: path
            )
            guard crc32(bytes) == expectedCRC else {
                throw PackageValidationError.unsupportedItem(path)
            }
            let unixMode = versionMade >> 8 == 3 ? externalAttributes >> 16 : 0
            let fileType = unixMode & UInt32(S_IFMT)
            let kind: PackageArchiveEntryKind
            if path.hasSuffix("/") || fileType == UInt32(S_IFDIR) {
                kind = .directory
            } else if fileType == UInt32(S_IFLNK) {
                kind = .symbolicLink
            } else if fileType == 0 || fileType == UInt32(S_IFREG) {
                kind = .regularFile
            } else {
                kind = .device
            }
            entries.append(Entry(
                path: path.hasSuffix("/") ? String(path.dropLast()) : path,
                kind: kind,
                bytes: bytes,
                mode: unixMode
            ))
            cursor = next
        }
        guard cursor == centralEnd else {
            throw PackageValidationError.unsupportedItem("ZIP directory")
        }
        return entries
    }

    private static func validateLayout(_ entries: [Entry]) throws {
        var kinds: [String: PackageArchiveEntryKind] = [:]
        for entry in entries {
            guard kinds.updateValue(entry.kind, forKey: entry.path) == nil else {
                throw PackageValidationError.unsupportedItem(entry.path)
            }
        }
        for entry in entries {
            var components = entry.path.split(separator: "/").map(String.init)
            components.removeLast()
            var parent = ""
            for component in components {
                parent = parent.isEmpty ? component : "\(parent)/\(component)"
                if let kind = kinds[parent], kind != .directory {
                    throw PackageValidationError.unsupportedItem(entry.path)
                }
            }
        }
    }

    private static func decompress(
        _ bytes: Data,
        method: UInt16,
        expectedSize: Int,
        path: String
    ) throws -> Data {
        if method == 0 {
            guard bytes.count == expectedSize else {
                throw PackageValidationError.unsupportedItem(path)
            }
            return bytes
        }
        if expectedSize == 0 { return Data() }
        var output = Data(count: expectedSize)
        let decoded = output.withUnsafeMutableBytes { destination in
            bytes.withUnsafeBytes { source in
                compression_decode_buffer(
                    destination.bindMemory(to: UInt8.self).baseAddress!,
                    expectedSize,
                    source.bindMemory(to: UInt8.self).baseAddress!,
                    bytes.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        guard decoded == expectedSize else {
            throw PackageValidationError.unsupportedItem(path)
        }
        return output
    }

    private static func endOfCentralDirectory(in archive: Data) -> Int? {
        guard archive.count >= 22 else { return nil }
        let lowerBound = max(0, archive.count - 65_557)
        for offset in stride(from: archive.count - 22, through: lowerBound, by: -1) {
            if readUInt32(archive, at: offset) == 0x0605_4b50,
               let commentLength = readUInt16(archive, at: offset + 20),
               offset + 22 + Int(commentLength) == archive.count {
                return offset
            }
        }
        return nil
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= data.count else { return nil }
        return UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        return UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xedb8_8320 : 0)
            }
        }
        return crc ^ 0xffff_ffff
    }

    private static func pathDepth(_ path: String) -> Int {
        path.split(separator: "/").count
    }
}

public enum PackageArchiveEntryKind: String, Hashable, Sendable {
    case regularFile
    case directory
    case symbolicLink
    case device
}

public struct PackageArchiveEntry: Hashable, Sendable {
    public let path: String
    public let kind: PackageArchiveEntryKind
    public let byteCount: Int64
    public let symbolicLinkTarget: String?

    public init(
        path: String,
        kind: PackageArchiveEntryKind,
        byteCount: Int64,
        symbolicLinkTarget: String? = nil
    ) {
        self.path = path
        self.kind = kind
        self.byteCount = byteCount
        self.symbolicLinkTarget = symbolicLinkTarget
    }
}

public enum PackageValidationError: Error, Equatable, Sendable {
    case missingEntryFile(String)
    case malformedEntryFile(String)
    case nameMismatch(expected: String, actual: String)
    case unsafeArchivePath(String)
    case escapingSymbolicLink(String)
    case unsupportedItem(String)
    case excessiveFileCount(maximum: Int)
    case excessiveByteCount(maximum: Int64)
    case fileTooLarge(String)
}

public struct ValidatedSkillPackage: Hashable, Sendable {
    public let packageURL: URL
    public let document: ParsedSkillDocument
    public let digest: PackageDigest
}

public struct PackageValidator: Sendable {
    public let limits: PackageValidationLimits
    public let entryFilename: String

    public init(
        limits: PackageValidationLimits = PackageValidationLimits(),
        entryFilename: String = "SKILL.md"
    ) {
        self.limits = limits
        self.entryFilename = entryFilename
    }

    public func validate(_ packageURL: URL, requiredName: String) throws -> ValidatedSkillPackage {
        let package = packageURL.standardizedFileURL
        let entries = try filesystemEntries(package)
        try validateArchiveEntries(entries)
        let entry = package.appending(path: entryFilename)
        var status = stat()
        guard entry.path.withCString({ Darwin.lstat($0, &status) }) == 0,
              status.st_mode & S_IFMT == S_IFREG else {
            throw PackageValidationError.missingEntryFile(entryFilename)
        }
        let bytes = try Data(contentsOf: entry)
        guard let text = String(data: bytes, encoding: .utf8) else {
            throw PackageValidationError.malformedEntryFile(entryFilename)
        }
        let document = FrontmatterParser.parse(text)
        guard document.issues.isEmpty,
              let actual = document.name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !actual.isEmpty,
              document.description?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw PackageValidationError.malformedEntryFile(entryFilename)
        }
        guard actual == requiredName else {
            throw PackageValidationError.nameMismatch(expected: requiredName, actual: actual)
        }
        return ValidatedSkillPackage(
            packageURL: package,
            document: document,
            digest: try PackageDigest.compute(at: package)
        )
    }

    public func validateArchiveEntries(_ entries: [PackageArchiveEntry]) throws {
        var fileCount = 0
        var byteCount: Int64 = 0
        for entry in entries {
            guard safeRelativePath(entry.path) else {
                throw PackageValidationError.unsafeArchivePath(entry.path)
            }
            switch entry.kind {
            case .regularFile, .symbolicLink:
                fileCount += 1
            case .directory:
                break
            case .device:
                throw PackageValidationError.unsupportedItem(entry.path)
            }
            guard entry.byteCount >= 0,
                  entry.byteCount <= limits.maximumFileBytes else {
                throw PackageValidationError.fileTooLarge(entry.path)
            }
            guard entry.byteCount >= 0,
                  byteCount <= Int64.max - entry.byteCount else {
                throw PackageValidationError.excessiveByteCount(maximum: limits.maximumTotalBytes)
            }
            byteCount += entry.byteCount
            if fileCount > limits.maximumFileCount {
                throw PackageValidationError.excessiveFileCount(maximum: limits.maximumFileCount)
            }
            if byteCount > limits.maximumTotalBytes {
                throw PackageValidationError.excessiveByteCount(maximum: limits.maximumTotalBytes)
            }
            if entry.kind == .symbolicLink {
                guard let target = entry.symbolicLinkTarget,
                      !target.isEmpty,
                      !target.unicodeScalars.contains("\0"),
                      !symbolicLinkEscapes(linkPath: entry.path, target: target) else {
                    throw PackageValidationError.escapingSymbolicLink(entry.path)
                }
            }
        }
    }

    private func filesystemEntries(_ package: URL) throws -> [PackageArchiveEntry] {
        var result: [PackageArchiveEntry] = []
        try walk(directory: package, relativePrefix: "", result: &result)
        return result
    }

    private func walk(
        directory: URL,
        relativePrefix: String,
        result: inout [PackageArchiveEntry]
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
            let path = relativePrefix.isEmpty
                ? child.lastPathComponent
                : "\(relativePrefix)/\(child.lastPathComponent)"
            switch status.st_mode & S_IFMT {
            case S_IFDIR:
                result.append(PackageArchiveEntry(path: path, kind: .directory, byteCount: 0))
                try walk(directory: child, relativePrefix: path, result: &result)
            case S_IFREG:
                result.append(PackageArchiveEntry(path: path, kind: .regularFile, byteCount: status.st_size))
            case S_IFLNK:
                result.append(PackageArchiveEntry(
                    path: path,
                    kind: .symbolicLink,
                    byteCount: status.st_size,
                    symbolicLinkTarget: try FileManager.default.destinationOfSymbolicLink(atPath: child.path)
                ))
            default:
                result.append(PackageArchiveEntry(path: path, kind: .device, byteCount: 0))
            }
        }
    }

    private func safeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.hasPrefix("~"),
              !path.contains("\\"),
              !path.unicodeScalars.contains("\0") else {
            return false
        }
        var depth = 0
        for component in path.split(separator: "/", omittingEmptySubsequences: false) {
            if component.isEmpty || component == "." { return false }
            if component == ".." { return false }
            depth += 1
        }
        return true
    }

    private func symbolicLinkEscapes(linkPath: String, target: String) -> Bool {
        guard !target.hasPrefix("/"), !target.hasPrefix("~"), !target.contains("\\") else {
            return true
        }
        var components = linkPath.split(separator: "/").dropLast().map(String.init)
        for component in target.split(separator: "/", omittingEmptySubsequences: false) {
            switch component {
            case "", ".": continue
            case "..":
                guard !components.isEmpty else { return true }
                components.removeLast()
            default:
                components.append(String(component))
            }
        }
        return false
    }
}
