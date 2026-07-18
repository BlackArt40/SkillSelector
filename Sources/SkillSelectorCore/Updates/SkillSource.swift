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

public enum SkillSourceCandidate: Hashable, Sendable {
    case github(repository: String, subdirectory: String, reference: UpdateReference)
    case directPackage(URL)
    case nameOnly(String)
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
            return "github:\(repository!):\(subdirectory ?? ".")"
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
        guard parts.count == 2 else { throw SkillSourceError.invalidBinding }
        return try github(
            repository: parts[0],
            subdirectory: parts[1],
            reference: reference,
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
              !reference.value.contains("..") else {
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
