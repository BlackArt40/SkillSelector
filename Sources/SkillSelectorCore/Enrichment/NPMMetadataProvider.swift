import Foundation

public struct NPMMetadataProvider: MetadataProvider {
    private let executableURL: URL
    private let runner: any CommandRunning
    private let decoder = JSONDecoder()

    public init(executableURL: URL, runner: any CommandRunning = ExternalCommandRunner()) {
        self.executableURL = executableURL.standardizedFileURL
        self.runner = runner
    }

    public func candidates(for query: MetadataQuery) async throws -> [MetadataCandidate] {
        let name = try MetadataProviderSupport.validatedQueryName(query.name)
        let searchData = try await execute(["search", name, "--json"])
        let searchResults: [SearchResult]
        do {
            searchResults = try decoder.decode([SearchResult].self, from: searchData)
        } catch {
            throw MetadataProviderError.invalidResponse(provider: .npm)
        }

        var candidates: [MetadataCandidate] = []
        var seen = Set<String>()
        for result in searchResults where seen.insert(result.name).inserted {
            guard Self.validPackageName(result.name) else { continue }
            let viewData = try await execute(["view", "--json", "--", result.name])
            let package: PackageMetadata
            do {
                package = try decoder.decode(PackageMetadata.self, from: viewData)
            } catch {
                throw MetadataProviderError.invalidResponse(provider: .npm)
            }
            guard package.name == result.name,
                  let description = MetadataProviderSupport.nonempty(package.description)
                    ?? MetadataProviderSupport.readmeParagraph(package.readme),
                  let evidenceURL = Self.packageURL(result.name) else {
                continue
            }
            candidates.append(MetadataCandidate(
                provider: .npm,
                sourceIdentifier: result.name,
                skillSubdirectory: nil,
                description: description,
                evidenceURL: evidenceURL,
                sourceBinding: "npm:\(result.name)"
            ))
        }
        return candidates
    }

    private func execute(_ arguments: [String]) async throws -> Data {
        let result = try await runner.run(ExternalCommand(
            executableURL: executableURL,
            arguments: arguments,
            timeout: 30,
            maximumOutputBytes: 1_048_576
        ))
        return try MetadataProviderSupport.checkedResult(result, provider: .npm)
    }

    private static func validPackageName(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.utf8.count <= 214,
              !value.hasPrefix("-"),
              !value.contains("\\"),
              value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            return false
        }
        if value.hasPrefix("@") {
            let parts = value.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
            return parts.count == 2 && parts.allSatisfy { !$0.isEmpty && !$0.hasPrefix("-") }
        }
        return !value.contains("/")
    }

    private static func packageURL(_ name: String) -> URL? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        guard let encoded = name.addingPercentEncoding(withAllowedCharacters: allowed) else {
            return nil
        }
        return URL(string: "https://www.npmjs.com/package/\(encoded)")
    }

    private struct SearchResult: Decodable {
        let name: String
    }

    private struct PackageMetadata: Decodable {
        let name: String
        let description: String?
        let readme: String?
    }
}
