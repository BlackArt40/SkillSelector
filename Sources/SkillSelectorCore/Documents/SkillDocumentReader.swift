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
}

public struct SkillDocumentReader {
    public static let maximumRenderBytes = 1_048_576

    private let readPrefix: (URL, Int) throws -> Data

    public init() {
        readPrefix = { url, byteCount in
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            return try handle.read(upToCount: byteCount) ?? Data()
        }
    }

    init(readPrefix: @escaping (URL, Int) throws -> Data) {
        self.readPrefix = readPrefix
    }

    public func read(_ request: SkillDocumentRequest) throws -> SkillDocument {
        let entryURL = try validatedEntryURL(request)
        let resolvedEntryURL = entryURL.resolvingSymlinksInPath().standardizedFileURL
        let values: URLResourceValues
        do {
            values = try resolvedEntryURL.resourceValues(forKeys: [
                .fileSizeKey,
                .isReadableKey,
                .isRegularFileKey,
            ])
        } catch {
            throw SkillDocumentReaderError.unreadableFile
        }
        guard values.isRegularFile == true else {
            throw SkillDocumentReaderError.notRegularFile
        }
        guard values.isReadable == true else {
            throw SkillDocumentReaderError.unreadableFile
        }
        let byteCount = values.fileSize ?? 0
        guard byteCount <= Self.maximumRenderBytes else {
            throw SkillDocumentReaderError.tooLarge(
                limit: Self.maximumRenderBytes,
                actual: byteCount
            )
        }

        let data: Data
        do {
            data = try readPrefix(resolvedEntryURL, Self.maximumRenderBytes + 1)
        } catch {
            throw SkillDocumentReaderError.unreadableFile
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
        return SkillDocument(source: source, fileURL: entryURL)
    }

    public func validatedEntryURL(_ request: SkillDocumentRequest) throws -> URL {
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

        let values: URLResourceValues
        do {
            values = try resolvedEntryURL.resourceValues(forKeys: [.isRegularFileKey])
        } catch {
            throw SkillDocumentReaderError.notRegularFile
        }
        guard values.isRegularFile == true else {
            throw SkillDocumentReaderError.notRegularFile
        }
        return entryURL
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
}
