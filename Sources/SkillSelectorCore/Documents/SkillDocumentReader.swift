import Darwin
import Foundation

// Swift does not import the variadic pointer overload used by F_GETPATH.
@_silgen_name("fcntl")
private func fcntlWithPointer(
    _ descriptor: Int32,
    _ command: Int32,
    _ pointer: UnsafeMutableRawPointer
) -> Int32

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
}

struct SkillDocumentFileMetadata {
    let isRegularFile: Bool
    let byteCount: Int
}

struct SkillDocumentFileOperations: @unchecked Sendable {
    let openReadOnly: (URL) throws -> Int32
    let metadata: (Int32) throws -> SkillDocumentFileMetadata
    let canonicalURL: (Int32) throws -> URL
    let readChunk: (Int32, Int) throws -> Data
    let close: (Int32) -> Void

    static let live = SkillDocumentFileOperations(
        openReadOnly: { url in
            let descriptor = url.path.withCString {
                Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
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
                isRegularFile: status.st_mode & S_IFMT == S_IFREG,
                byteCount: max(0, Int(status.st_size))
            )
        },
        canonicalURL: { descriptor in
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            let result = buffer.withUnsafeMutableBufferPointer { pointer in
                fcntlWithPointer(descriptor, F_GETPATH, pointer.baseAddress!)
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
        let prepared = try prepare(request)
        return try withOpenedFile(prepared) { descriptor, metadata, canonicalURL in
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
                    chunk = try operations.readChunk(descriptor, remaining)
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

    public func validatedEntryURL(_ request: SkillDocumentRequest) throws -> URL {
        let prepared = try prepare(request)
        return try withOpenedFile(prepared) { _, _, canonicalURL in canonicalURL }
    }

    private func prepare(_ request: SkillDocumentRequest) throws -> PreparedEntry {
        guard Self.isSimpleEntryFilename(request.entryFilename) else {
            throw SkillDocumentReaderError.invalidEntryFilename(request.entryFilename)
        }

        let installation = request.installationURL.standardizedFileURL
        let resolvedInstallation = installation.resolvingSymlinksInPath().standardizedFileURL
        let installationIsSymbolicLink = (try? installation.resourceValues(
            forKeys: [.isSymbolicLinkKey]
        ).isSymbolicLink) == true
        if installationIsSymbolicLink && request.resolvedTargetURL == nil {
            throw SkillDocumentReaderError.invalidResolvedTarget
        }
        if let expectedTarget = request.resolvedTargetURL?.standardizedFileURL,
           expectedTarget.path != resolvedInstallation.path {
            throw SkillDocumentReaderError.invalidResolvedTarget
        }

        let authorizedPair = request.authorizedRootURLs.lazy
            .map { root in
                (
                    standardized: root.standardizedFileURL,
                    resolved: root.resolvingSymlinksInPath().standardizedFileURL
                )
            }
            .first { root in
                Self.contains(installation, in: root.standardized)
                    && Self.contains(resolvedInstallation, in: root.resolved)
            }
        guard let authorizedPair else {
            throw SkillDocumentReaderError.unauthorizedInstallationPath
        }

        let entryURL = installation.appending(path: request.entryFilename).standardizedFileURL
        guard Self.contains(entryURL, in: installation) else {
            throw SkillDocumentReaderError.invalidEntryFilename(request.entryFilename)
        }
        let resolvedEntryURL = entryURL.resolvingSymlinksInPath().standardizedFileURL
        guard Self.contains(resolvedEntryURL, in: authorizedPair.resolved) else {
            throw SkillDocumentReaderError.entryEscapesAuthorizedRoot
        }

        return PreparedEntry(
            candidateURL: resolvedEntryURL,
            authorizedResolvedRoot: authorizedPair.resolved
        )
    }

    private func withOpenedFile<Result>(
        _ prepared: PreparedEntry,
        operation: (Int32, SkillDocumentFileMetadata, URL) throws -> Result
    ) throws -> Result {
        let descriptor: Int32
        do {
            descriptor = try operations.openReadOnly(prepared.candidateURL)
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
        guard Self.contains(canonicalURL, in: prepared.authorizedResolvedRoot) else {
            throw SkillDocumentReaderError.entryEscapesAuthorizedRoot
        }
        return try operation(descriptor, metadata, canonicalURL)
    }

    private static func isSimpleEntryFilename(_ filename: String) -> Bool {
        !filename.isEmpty
            && filename != "."
            && filename != ".."
            && !filename.contains("/")
            && !filename.contains("\\")
    }

    private static func contains(_ candidate: URL, in root: URL) -> Bool {
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        let rootComponents = root.standardizedFileURL.pathComponents
        return candidateComponents.count >= rootComponents.count
            && Array(candidateComponents.prefix(rootComponents.count)) == rootComponents
    }

    private struct PreparedEntry {
        let candidateURL: URL
        let authorizedResolvedRoot: URL
    }
}
