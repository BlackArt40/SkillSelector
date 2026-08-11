import Darwin
import Foundation

public struct SkillDocumentRequest: Hashable, Sendable {
    public let installationURL: URL
    public let resolvedTargetURL: URL?
    public let entryFilename: String
    public let authorizedRootURLs: [URL]

    public init(
        installationURL: URL,
        resolvedTargetURL: URL?,
        entryFilename: String,
        authorizedRootURLs: [URL]
    ) {
        self.installationURL = installationURL
        self.resolvedTargetURL = resolvedTargetURL
        self.entryFilename = entryFilename
        self.authorizedRootURLs = authorizedRootURLs
    }
}

public struct SkillDocument: Hashable, Sendable {
    public let source: String
    public let fileURL: URL

    public init(source: String, fileURL: URL) {
        self.source = source
        self.fileURL = fileURL
    }
}

public enum SkillDocumentReaderError: Error, Equatable, Sendable {
    case invalidEntryFilename(String)
    case unauthorizedInstallationPath
    case invalidResolvedTarget
    case entryEscapesAuthorizedRoot
    case notRegularFile
    case unreadableFile
    case invalidUTF8
    case tooLarge(limit: Int, actual: Int)

    /// Localization key for the user-facing message. The app layer renders
    /// it through L10n, so the mapping lives with the strings resources
    /// instead of a view-level switch.
    public var localizationKey: String {
        switch self {
        case .invalidEntryFilename:
            "The entry filename is invalid."
        case .unauthorizedInstallationPath, .invalidResolvedTarget, .entryEscapesAuthorizedRoot:
            "The document is outside its authorized folder."
        case .notRegularFile:
            "The Skill document is not a regular file."
        case .unreadableFile:
            "The Skill document cannot be read."
        case .invalidUTF8:
            "The Skill document is not valid UTF-8 text."
        case .tooLarge:
            "The Skill document is larger than the 1 MiB render limit."
        }
    }
}

struct SkillDocumentFileMetadata {
    let isDirectory: Bool
    let isRegularFile: Bool
    let byteCount: Int
}

struct SkillDocumentFileOperations: @unchecked Sendable {
    let openDirectory: (URL) throws -> Int32
    let openEntry: (Int32, String) throws -> Int32
    let metadata: (Int32) throws -> SkillDocumentFileMetadata
    let canonicalURL: (Int32) throws -> URL
    let readChunk: (Int32, Int) throws -> Data
    let close: (Int32) -> Void

    static let live = SkillDocumentFileOperations(
        openDirectory: { url in
            let descriptor = url.path.withCString {
                Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard descriptor >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return descriptor
        },
        openEntry: { directoryDescriptor, filename in
            let descriptor = filename.withCString {
                Darwin.openat(directoryDescriptor, $0, O_RDONLY | O_CLOEXEC)
            }
            guard descriptor >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return descriptor
        },
        metadata: { descriptor in
            var status = stat()
            guard Darwin.fstat(descriptor, &status) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return SkillDocumentFileMetadata(
                isDirectory: status.st_mode & S_IFMT == S_IFDIR,
                isRegularFile: status.st_mode & S_IFMT == S_IFREG,
                byteCount: max(0, Int(status.st_size))
            )
        },
        canonicalURL: { descriptor in
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            let result = buffer.withUnsafeMutableBufferPointer { pointer in
                Darwin.fcntl(
                    descriptor,
                    F_GETPATH,
                    UnsafeMutableRawPointer(pointer.baseAddress!)
                )
            }
            guard result != -1 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            let length = buffer.firstIndex(of: 0) ?? buffer.count
            let path = buffer.withUnsafeBufferPointer { pointer in
                FileManager.default.string(
                    withFileSystemRepresentation: pointer.baseAddress!,
                    length: length
                )
            }
            return URL(fileURLWithPath: path).standardizedFileURL
        },
        readChunk: { descriptor, maximumCount in
            var buffer = [UInt8](repeating: 0, count: maximumCount)
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(descriptor, rawBuffer.baseAddress, maximumCount)
            }
            guard count >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return Data(buffer.prefix(Int(count)))
        },
        close: { descriptor in
            _ = Darwin.close(descriptor)
        }
    )
}

public struct SkillDocumentReader {
    public static let maximumRenderBytes = 1_048_576

    private let operations: SkillDocumentFileOperations

    public init() {
        operations = .live
    }

    init(operations: SkillDocumentFileOperations) {
        self.operations = operations
    }

    public func read(_ request: SkillDocumentRequest) throws -> SkillDocument {
        let prepared = try prepareInstallation(request)
        return try withOpenedDirectory(prepared) { directoryDescriptor in
            try withOpenedEntry(
                directoryDescriptor: directoryDescriptor,
                filename: request.entryFilename,
                authorizedResolvedRoot: prepared.authorizedResolvedRoot
            ) { entryDescriptor, metadata, canonicalURL in
                guard metadata.byteCount <= Self.maximumRenderBytes else {
                    throw SkillDocumentReaderError.tooLarge(
                        limit: Self.maximumRenderBytes,
                        actual: metadata.byteCount
                    )
                }

                var data = Data()
                data.reserveCapacity(min(metadata.byteCount, Self.maximumRenderBytes))
                while data.count <= Self.maximumRenderBytes {
                    let remaining = Self.maximumRenderBytes + 1 - data.count
                    let chunk: Data
                    do {
                        chunk = try operations.readChunk(entryDescriptor, remaining)
                    } catch {
                        throw SkillDocumentReaderError.unreadableFile
                    }
                    if chunk.isEmpty { break }
                    data.append(chunk)
                }
                guard data.count <= Self.maximumRenderBytes else {
                    throw SkillDocumentReaderError.tooLarge(
                        limit: Self.maximumRenderBytes,
                        actual: data.count
                    )
                }
                guard let source = String(data: data, encoding: .utf8) else {
                    throw SkillDocumentReaderError.invalidUTF8
                }
                return SkillDocument(source: source, fileURL: canonicalURL)
            }
        }
    }

    public func validatedEntryURL(_ request: SkillDocumentRequest) throws -> URL {
        let prepared = try prepareInstallation(request)
        return try withOpenedDirectory(prepared) { directoryDescriptor in
            try withOpenedEntry(
                directoryDescriptor: directoryDescriptor,
                filename: request.entryFilename,
                authorizedResolvedRoot: prepared.authorizedResolvedRoot
            ) { _, _, canonicalURL in canonicalURL }
        }
    }

    private func prepareInstallation(
        _ request: SkillDocumentRequest
    ) throws -> PreparedInstallation {
        guard EntryFilename.isValid(request.entryFilename) else {
            throw SkillDocumentReaderError.invalidEntryFilename(request.entryFilename)
        }

        let installation = request.installationURL.standardizedFileURL
        let standardizedRoots = request.authorizedRootURLs.map(\.standardizedFileURL)
        guard standardizedRoots.contains(where: { Self.contains(installation, in: $0) }) else {
            throw SkillDocumentReaderError.unauthorizedInstallationPath
        }

        let resolvedInstallation = installation.resolvingSymlinksInPath().standardizedFileURL
        let installationIsSymbolicLink = (try? installation.resourceValues(
            forKeys: [.isSymbolicLinkKey]
        ).isSymbolicLink) == true
        if installationIsSymbolicLink != (request.resolvedTargetURL != nil) {
            throw SkillDocumentReaderError.invalidResolvedTarget
        }
        let expectedCanonicalURL = request.resolvedTargetURL?.standardizedFileURL
            ?? resolvedInstallation
        if request.resolvedTargetURL != nil,
           expectedCanonicalURL.path != resolvedInstallation.path {
            throw SkillDocumentReaderError.invalidResolvedTarget
        }

        let authorizedPairs = request.authorizedRootURLs.map { root in
            (
                standardized: root.standardizedFileURL,
                resolved: root.resolvingSymlinksInPath().standardizedFileURL
            )
        }
        guard authorizedPairs.contains(where: {
            Self.contains(installation, in: $0.standardized)
        }),
        let authorizedResolvedRoot = authorizedPairs.first(where: {
            Self.contains(expectedCanonicalURL, in: $0.resolved)
        })?.resolved else {
            throw SkillDocumentReaderError.unauthorizedInstallationPath
        }

        return PreparedInstallation(
            directoryCandidateURL: installationIsSymbolicLink
                ? resolvedInstallation
                : installation,
            expectedCanonicalURL: expectedCanonicalURL,
            authorizedResolvedRoot: authorizedResolvedRoot
        )
    }

    private func withOpenedDirectory<Result>(
        _ prepared: PreparedInstallation,
        operation: (Int32) throws -> Result
    ) throws -> Result {
        let descriptor: Int32
        do {
            descriptor = try operations.openDirectory(prepared.directoryCandidateURL)
        } catch {
            throw SkillDocumentReaderError.unreadableFile
        }
        defer { operations.close(descriptor) }

        let metadata: SkillDocumentFileMetadata
        let canonicalURL: URL
        do {
            metadata = try operations.metadata(descriptor)
            canonicalURL = try operations.canonicalURL(descriptor).standardizedFileURL
        } catch {
            throw SkillDocumentReaderError.unreadableFile
        }
        guard metadata.isDirectory,
              canonicalURL.path == prepared.expectedCanonicalURL.path,
              Self.contains(canonicalURL, in: prepared.authorizedResolvedRoot) else {
            throw SkillDocumentReaderError.invalidResolvedTarget
        }
        return try operation(descriptor)
    }

    private func withOpenedEntry<Result>(
        directoryDescriptor: Int32,
        filename: String,
        authorizedResolvedRoot: URL,
        operation: (Int32, SkillDocumentFileMetadata, URL) throws -> Result
    ) throws -> Result {
        let descriptor: Int32
        do {
            descriptor = try operations.openEntry(directoryDescriptor, filename)
        } catch {
            throw SkillDocumentReaderError.unreadableFile
        }
        defer { operations.close(descriptor) }

        let metadata: SkillDocumentFileMetadata
        let canonicalURL: URL
        do {
            metadata = try operations.metadata(descriptor)
            canonicalURL = try operations.canonicalURL(descriptor).standardizedFileURL
        } catch {
            throw SkillDocumentReaderError.unreadableFile
        }
        guard metadata.isRegularFile else {
            throw SkillDocumentReaderError.notRegularFile
        }
        guard Self.contains(canonicalURL, in: authorizedResolvedRoot) else {
            throw SkillDocumentReaderError.entryEscapesAuthorizedRoot
        }
        return try operation(descriptor, metadata, canonicalURL)
    }

    private static func contains(_ candidate: URL, in root: URL) -> Bool {
        candidate.standardizedFileURL.isContained(in: root.standardizedFileURL)
    }

    private struct PreparedInstallation {
        let directoryCandidateURL: URL
        let expectedCanonicalURL: URL
        let authorizedResolvedRoot: URL
    }
}
