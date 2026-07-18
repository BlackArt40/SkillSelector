import Foundation

public enum SkillSourceError: Error, Equatable, Sendable {
    case unsupportedCandidate
    case invalidRepository
    case invalidSubdirectory
    case invalidReference
    case invalidBinding
    case invalidDirectPackageURL
}

public enum SkillSourceProvenance: String, Codable, Hashable, Sendable {
    case embeddedMetadata
    case containingGitRemote
    case rememberedBinding
    case userConfirmedCandidate
}

public enum UpdateReference: Codable, Hashable, Sendable {
    case branch(String)
    case tag(String)
    case commit(String)

    public var value: String {
        switch self {
        case .branch(let value), .tag(let value), .commit(let value): value
        }
    }

    public var isPinned: Bool {
        switch self {
        case .branch: false
        case .tag, .commit: true
        }
    }
}

public enum SkillSourceCandidate: Codable, Hashable, Sendable {
    case github(repository: String, subdirectory: String, reference: UpdateReference)
    case directPackage(URL)
    case nameOnly(String)
}

public struct SkillSourceDiscovery: Hashable, Sendable {
    public init() {}

    public func candidates(
        for installationURL: URL,
        document: ParsedSkillDocument
    ) -> [SkillSource] {
        var result: [SkillSource] = []
        if let source = try? SkillSource.embeddedMetadata(document: document) {
            result.append(source)
        }
        if let source = try? SkillSource.containingGitRepository(for: installationURL) {
            result.append(source)
        }
        var seen = Set<String>()
        return result.filter { seen.insert($0.binding).inserted }
    }
}

public enum SkillSourceKind: String, Codable, Hashable, Sendable {
    case github
    case directPackage
}

public struct SkillSource: Codable, Hashable, Sendable {
    public let kind: SkillSourceKind
    public let repository: String?
    public let subdirectory: String?
    public let directPackageURL: URL?
    public let reference: UpdateReference?
    public let provenance: SkillSourceProvenance

    public var binding: String {
        switch kind {
        case .github:
            let reference = self.reference ?? .branch("HEAD")
            return "github:\(repository!):\(subdirectory ?? "."):\(reference.bindingKind):\(reference.value)"
        case .directPackage:
            return "url:\(directPackageURL!.absoluteString)"
        }
    }

    public static func github(
        repository: String,
        subdirectory: String,
        reference: UpdateReference,
        provenance: SkillSourceProvenance
    ) throws -> SkillSource {
        try validate(repository: repository, subdirectory: subdirectory, reference: reference)
        return SkillSource(
            kind: .github,
            repository: repository,
            subdirectory: normalizedSubdirectory(subdirectory),
            directPackageURL: nil,
            reference: reference,
            provenance: provenance
        )
    }

    public static func directPackage(
        _ url: URL,
        provenance: SkillSourceProvenance
    ) throws -> SkillSource {
        guard url.scheme?.lowercased() == "https",
              url.host != nil,
              url.user == nil,
              url.password == nil else {
            throw SkillSourceError.invalidDirectPackageURL
        }
        return SkillSource(
            kind: .directPackage,
            repository: nil,
            subdirectory: nil,
            directPackageURL: url,
            reference: nil,
            provenance: provenance
        )
    }

    public static func containingGitRemote(
        remoteURL: URL,
        relativePath: String,
        reference: UpdateReference
    ) throws -> SkillSource {
        guard remoteURL.host?.lowercased() == "github.com" else {
            throw SkillSourceError.invalidRepository
        }
        var components = remoteURL.path.split(separator: "/").map(String.init)
        guard components.count == 2 else { throw SkillSourceError.invalidRepository }
        if components[1].hasSuffix(".git") {
            components[1].removeLast(4)
        }
        return try github(
            repository: components.joined(separator: "/"),
            subdirectory: relativePath,
            reference: reference,
            provenance: .containingGitRemote
        )
    }

    public static func containingGitRemote(
        remote: String,
        relativePath: String,
        reference: UpdateReference
    ) throws -> SkillSource {
        let prefix = "git@github.com:"
        if remote.hasPrefix(prefix) {
            var repository = String(remote.dropFirst(prefix.count))
            if repository.hasSuffix(".git") { repository.removeLast(4) }
            return try github(
                repository: repository,
                subdirectory: relativePath,
                reference: reference,
                provenance: .containingGitRemote
            )
        }
        guard let url = URL(string: remote) else {
            throw SkillSourceError.invalidRepository
        }
        return try containingGitRemote(
            remoteURL: url,
            relativePath: relativePath,
            reference: reference
        )
    }

    public static func remembered(
        binding: String,
        reference: UpdateReference = .branch("HEAD")
    ) throws -> SkillSource {
        if binding.hasPrefix("url:"),
           let url = URL(string: String(binding.dropFirst("url:".count))) {
            return try directPackage(url, provenance: .rememberedBinding)
        }
        guard binding.hasPrefix("github:") else { throw SkillSourceError.invalidBinding }
        let remainder = String(binding.dropFirst("github:".count))
        let parts = remainder.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 || parts.count == 4 else { throw SkillSourceError.invalidBinding }
        let parsedReference: UpdateReference
        if parts.count == 2 {
            parsedReference = reference
        } else {
            guard let kind = UpdateReference.BindingKind(rawValue: parts[2]) else {
                throw SkillSourceError.invalidBinding
            }
            parsedReference = try UpdateReference(bindingKind: kind, value: parts[3])
        }
        return try github(
            repository: parts[0],
            subdirectory: parts[1],
            reference: parsedReference,
            provenance: .rememberedBinding
        )
    }

    public static func userConfirmed(candidate: SkillSourceCandidate) throws -> SkillSource {
        switch candidate {
        case .github(let repository, let subdirectory, let reference):
            return try github(
                repository: repository,
                subdirectory: subdirectory,
                reference: reference,
                provenance: .userConfirmedCandidate
            )
        case .directPackage(let url):
            return try directPackage(url, provenance: .userConfirmedCandidate)
        case .nameOnly:
            throw SkillSourceError.unsupportedCandidate
        }
    }

    public static func nameOnlyCandidate(_ name: String) -> SkillSource? { nil }

    public static func embeddedMetadata(document: ParsedSkillDocument) throws -> SkillSource? {
        let fields = document.fields
        guard let raw = fields["source"] ?? fields["source_url"] ?? fields["repository"],
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let reference: UpdateReference
        if let commit = fields["commit"] {
            reference = .commit(commit)
        } else if let tag = fields["tag"] {
            reference = .tag(tag)
        } else {
            reference = .branch(fields["branch"] ?? fields["ref"] ?? "main")
        }
        if raw.hasPrefix("github:") {
            return try remembered(binding: raw, reference: reference)
        }
        guard let url = URL(string: raw) else { throw SkillSourceError.invalidBinding }
        if url.host?.lowercased() == "github.com" {
            var components = url.path.split(separator: "/").map(String.init)
            guard components.count >= 2 else { throw SkillSourceError.invalidRepository }
            if components[1].hasSuffix(".git") { components[1].removeLast(4) }
            let subdirectory = fields["subdirectory"]
                ?? (components.count > 2 ? components.dropFirst(2).joined(separator: "/") : ".")
            return try github(
                repository: components.prefix(2).joined(separator: "/"),
                subdirectory: subdirectory,
                reference: reference,
                provenance: .embeddedMetadata
            )
        }
        return try directPackage(url, provenance: .embeddedMetadata)
    }

    public static func containingGitRepository(for installationURL: URL) throws -> SkillSource? {
        var directory = installationURL.standardizedFileURL
        if (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true {
            directory.deleteLastPathComponent()
        }
        while directory.pathComponents.count > 1 {
            let gitDirectory = directory.appending(path: ".git")
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: gitDirectory.path, isDirectory: &isDirectory) else {
                directory.deleteLastPathComponent()
                continue
            }
            let config = gitDirectory.appending(path: "config")
            guard let text = try? String(contentsOf: config, encoding: .utf8),
                  let remote = gitRemoteURL(in: text) else { return nil }
            let relative = installationURL.standardizedFileURL.path
                .dropFirst(directory.path.count)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let branch = gitBranch(in: gitDirectory) ?? "main"
            return try containingGitRemote(
                remote: remote,
                relativePath: relative.isEmpty ? "." : String(relative),
                reference: .branch(branch)
            )
        }
        return nil
    }

    private static func validate(
        repository: String,
        subdirectory: String,
        reference: UpdateReference
    ) throws {
        let repositoryParts = repository.split(separator: "/", omittingEmptySubsequences: false)
        guard repositoryParts.count == 2,
              repositoryParts.allSatisfy({ validArgumentComponent(String($0)) }) else {
            throw SkillSourceError.invalidRepository
        }
        guard validRelativePath(subdirectory) else { throw SkillSourceError.invalidSubdirectory }
        guard validArgumentComponent(reference.value),
              !reference.value.contains(".."),
              !reference.value.contains(":") else {
            throw SkillSourceError.invalidReference
        }
    }

    private static func normalizedSubdirectory(_ value: String) -> String {
        value == "." ? "." : value.split(separator: "/").joined(separator: "/")
    }

    private static func validRelativePath(_ value: String) -> Bool {
        guard !value.isEmpty, !value.hasPrefix("/"), !value.contains("\\") else { return false }
        if value == "." { return true }
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        return !components.isEmpty && components.allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".." && validArgumentComponent(String($0))
        }
    }

    private static func validArgumentComponent(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 512
            && !value.hasPrefix("-")
            && value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }
}

private func gitRemoteURL(in config: String) -> String? {
    var inOrigin = false
    for line in config.split(whereSeparator: \.isNewline) {
        let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("[remote \"origin\"]") {
            inOrigin = true
            continue
        }
        if value.hasPrefix("[") { inOrigin = false }
        if inOrigin, value.hasPrefix("url =") {
            return value.dropFirst("url =".count).trimmingCharacters(in: .whitespaces)
        }
    }
    return nil
}

private func gitBranch(in gitDirectory: URL) -> String? {
    guard let head = try? String(contentsOf: gitDirectory.appending(path: "HEAD"), encoding: .utf8),
          head.hasPrefix("ref: refs/heads/") else { return nil }
    return String(head.dropFirst("ref: refs/heads/".count)).trimmingCharacters(in: .whitespacesAndNewlines)
}

extension SkillSourceCandidate {
    private enum CodingKeys: String, CodingKey { case kind, repository, subdirectory, reference, url, name }
    private enum Kind: String, Codable { case github, directPackage, nameOnly }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .github(let repository, let subdirectory, let reference):
            try container.encode(Kind.github, forKey: .kind)
            try container.encode(repository, forKey: .repository)
            try container.encode(subdirectory, forKey: .subdirectory)
            try container.encode(reference, forKey: .reference)
        case .directPackage(let url):
            try container.encode(Kind.directPackage, forKey: .kind)
            try container.encode(url, forKey: .url)
        case .nameOnly(let name):
            try container.encode(Kind.nameOnly, forKey: .kind)
            try container.encode(name, forKey: .name)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .github:
            self = .github(
                repository: try container.decode(String.self, forKey: .repository),
                subdirectory: try container.decode(String.self, forKey: .subdirectory),
                reference: try container.decode(UpdateReference.self, forKey: .reference)
            )
        case .directPackage:
            self = .directPackage(try container.decode(URL.self, forKey: .url))
        case .nameOnly:
            self = .nameOnly(try container.decode(String.self, forKey: .name))
        }
    }
}

private extension UpdateReference {
    enum BindingKind: String {
        case branch
        case tag
        case commit
    }

    var bindingKind: BindingKind {
        switch self {
        case .branch: .branch
        case .tag: .tag
        case .commit: .commit
        }
    }

    init(bindingKind: BindingKind, value: String) throws {
        switch bindingKind {
        case .branch: self = .branch(value)
        case .tag: self = .tag(value)
        case .commit: self = .commit(value)
        }
    }
}
