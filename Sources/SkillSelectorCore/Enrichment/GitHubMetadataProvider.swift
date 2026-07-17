import Foundation

public struct GitHubMetadataProvider: MetadataProvider {
    private let executableURL: URL
    private let authorizedHomeURL: URL?
    private let toolAccess: ToolAccess?
    private let runner: any CommandRunning
    private let decoder = JSONDecoder()

    public init(executableURL: URL, runner: any CommandRunning = ExternalCommandRunner()) {
        self.executableURL = executableURL.standardizedFileURL
        self.authorizedHomeURL = nil
        self.toolAccess = nil
        self.runner = runner
    }

    public init(toolAccess: ToolAccess, runner: any CommandRunning = ExternalCommandRunner()) {
        self.executableURL = toolAccess.executableURL
        self.authorizedHomeURL = toolAccess.authorizedHomeURL
        self.toolAccess = toolAccess
        self.runner = runner
    }

    public func candidates(for query: MetadataQuery) async throws -> [MetadataCandidate] {
        let name = try MetadataProviderSupport.validatedQueryName(query.name)
        let searchData = try await execute([
            "search", "code", name,
            "--filename", "SKILL.md",
            "--json", "path,repository,url",
            "--limit", "20",
        ])
        let searchResults: [SearchResult]
        do {
            searchResults = try decoder.decode([SearchResult].self, from: searchData)
        } catch {
            throw MetadataProviderError.invalidResponse(provider: .github)
        }

        var candidates: [MetadataCandidate] = []
        var seen = Set<String>()
        for result in searchResults {
            let repository = result.repository.nameWithOwner
            guard seen.insert(repository + "\u{0}" + result.path).inserted,
                  Self.validRepository(repository),
                  Self.validSkillPath(result.path),
                  let searchURL = Self.githubURL(result.url) else {
                continue
            }
            if let candidate = try await candidate(
                searchResult: result,
                repository: repository,
                searchURL: searchURL
            ) {
                candidates.append(candidate)
            }
        }
        return candidates
    }

    private func candidate(
        searchResult: SearchResult,
        repository: String,
        searchURL: URL
    ) async throws -> MetadataCandidate? {
        let encodedPath = searchResult.path
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { Self.apiPathComponent(String($0)) }
            .joined(separator: "/")
        let skillData = try await execute([
            "api", "repos/\(repository)/contents/\(encodedPath)",
            "-H", "Accept: application/vnd.github.raw+json",
        ])
        let skillText = String(decoding: skillData, as: UTF8.self)
        if let description = MetadataProviderSupport.nonempty(
            FrontmatterParser.parse(skillText).description
        ) {
            return makeCandidate(
                result: searchResult,
                repository: repository,
                description: description,
                evidenceURL: searchURL
            )
        }

        let repositoryData = try await execute(["api", "repos/\(repository)"])
        let metadata: RepositoryMetadata
        do {
            metadata = try decoder.decode(RepositoryMetadata.self, from: repositoryData)
        } catch {
            throw MetadataProviderError.invalidResponse(provider: .github)
        }
        if let description = MetadataProviderSupport.nonempty(metadata.description),
           let evidenceURL = Self.githubURL(metadata.htmlURL) {
            return makeCandidate(
                result: searchResult,
                repository: repository,
                description: description,
                evidenceURL: evidenceURL
            )
        }

        let readmeData = try await execute([
            "api", "repos/\(repository)/readme",
            "-H", "Accept: application/vnd.github.raw+json",
        ])
        guard let description = MetadataProviderSupport.readmeParagraph(
            String(decoding: readmeData, as: UTF8.self)
        ), let repositoryURL = Self.githubURL(metadata.htmlURL),
           let evidenceURL = URL(string: repositoryURL.absoluteString + "#readme") else {
            return nil
        }
        return makeCandidate(
            result: searchResult,
            repository: repository,
            description: description,
            evidenceURL: evidenceURL
        )
    }

    private func makeCandidate(
        result: SearchResult,
        repository: String,
        description: String,
        evidenceURL: URL
    ) -> MetadataCandidate {
        let subdirectory = (result.path as NSString).deletingLastPathComponent
        let normalizedSubdirectory = subdirectory == "." || subdirectory.isEmpty
            ? nil : subdirectory
        return MetadataCandidate(
            provider: .github,
            sourceIdentifier: repository,
            skillSubdirectory: normalizedSubdirectory,
            description: description,
            evidenceURL: evidenceURL,
            sourceBinding: "github:\(repository):\(normalizedSubdirectory ?? ".")"
        )
    }

    private func execute(_ arguments: [String]) async throws -> Data {
        let result = try await runner.run(ExternalCommand(
            executableURL: executableURL,
            arguments: arguments,
            authorizedHomeURL: authorizedHomeURL,
            timeout: 30,
            maximumOutputBytes: 1_048_576
        ))
        return try MetadataProviderSupport.checkedResult(result, provider: .github)
    }

    private static func validRepository(_ value: String) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty
                && part != "."
                && part != ".."
                && !part.hasPrefix("-")
                && part.unicodeScalars.allSatisfy {
                    CharacterSet.alphanumerics.contains($0)
                        || $0 == "-" || $0 == "_" || $0 == "."
                }
        }
    }

    private static func validSkillPath(_ value: String) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.last == "SKILL.md" else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part != "." && part != ".." && !part.hasPrefix("-")
        }
    }

    private static func githubURL(_ value: String) -> URL? {
        guard let url = URL(string: value),
              url.scheme == "https",
              url.host?.lowercased() == "github.com" else {
            return nil
        }
        return url
    }

    private static func apiPathComponent(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private struct SearchResult: Decodable {
        let path: String
        let repository: Repository
        let url: String

        struct Repository: Decodable {
            let nameWithOwner: String
        }
    }

    private struct RepositoryMetadata: Decodable {
        let description: String?
        let htmlURL: String

        enum CodingKeys: String, CodingKey {
            case description
            case htmlURL = "html_url"
        }
    }
}
