import Foundation

/// Fetches the read-only catalog from GitHub's public API. On-demand only:
/// nothing here runs on a timer, nothing is persisted, and responses never
/// reach disk — the UI holds them in memory (product spec: 市场目录只读).
public struct CatalogFetcher: CatalogFetching, Sendable {
    /// Upper bound for a remote SKILL.md body. Mirrors the rules-file and
    /// MCP-config caps: an oversized document is rejected, not shown.
    public static let maximumDocumentBytes = 1_048_576

    private let session: URLSession

    /// - Parameter session: injected so tests can stub responses without
    ///   touching the network.
    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetchSkills(source: CatalogSource) async throws -> CatalogPage {
        var request = URLRequest(url: Self.treesURL(source: source))
        request.timeoutInterval = 30
        let (data, _) = try await Self.validatedData(for: request, session: session)
        return try Self.parseTree(data, source: source)
    }

    public func fetchDocument(_ skill: CatalogSkill) async throws -> String {
        var request = URLRequest(url: skill.rawURL)
        request.timeoutInterval = 30
        let (data, _) = try await Self.validatedData(for: request, session: session)
        guard data.count <= Self.maximumDocumentBytes else {
            throw CatalogError.oversized
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw CatalogError.invalidResponse
        }
        return text
    }

    // MARK: Plumbing

    private static func validatedData(
        for request: URLRequest,
        session: URLSession
    ) async throws -> (Data, URLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CatalogError.invalidResponse
        }
        switch http.statusCode {
        case 200:
            return (data, response)
        case 403, 429:
            throw CatalogError.rateLimited
        case let status:
            throw CatalogError.http(status: status)
        }
    }

    static func treesURL(source: CatalogSource) -> URL {
        URL(string: "https://api.github.com/repos/\(source.owner)/\(source.repo)/git/trees/\(source.branch)?recursive=1")!
    }

    // MARK: Tree parsing

    private struct TreeResponse: Decodable {
        struct Entry: Decodable {
            let path: String
            let type: String
        }

        let truncated: Bool
        let tree: [Entry]
    }

    /// Percent-encodes a remote-controlled path segment for URL
    /// interpolation. GitHub tree paths can legitimately contain spaces
    /// and other characters macOS's strict URL parser rejects; building
    /// the URL with a raw `URL(string:)!` would let any marketplace
    /// source crash the app the moment it publishes such a path.
    static func percentEncodedPath(_ path: String) -> String {
        path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
    }

    /// Pure parsing, exposed through the fetcher for tests: filters the
    /// tree to blob entries named SKILL.md, skipping anything inside a
    /// dot-directory (`.github/`, `.claude-plugin/` fixtures, …).
    static func parseTree(_ data: Data, source: CatalogSource) throws -> CatalogPage {
        let response: TreeResponse
        do {
            response = try JSONDecoder().decode(TreeResponse.self, from: data)
        } catch {
            throw CatalogError.invalidResponse
        }
        let skills = response.tree
            .filter { $0.type == "blob" }
            .filter { entry in
                entry.path == "SKILL.md" || entry.path.hasSuffix("/SKILL.md")
            }
            .filter { entry in
                // Drop hidden trees: ".github/SKILL.md" is repo plumbing,
                // not a published skill.
                let directory = (entry.path as NSString).deletingLastPathComponent
                return directory.split(separator: "/").allSatisfy { !$0.hasPrefix(".") }
            }
            .compactMap { entry -> CatalogSkill? in
                let directory = (entry.path as NSString).deletingLastPathComponent
                let name = directory.split(separator: "/").map(String.init).last
                    ?? source.repo
                let githubBase = "https://github.com/\(source.owner)/\(source.repo)"
                let githubURL = directory.isEmpty
                    ? URL(string: githubBase)
                    : URL(string: "\(githubBase)/tree/\(source.branch)/\(Self.percentEncodedPath(directory))")
                let rawURL = URL(string: "https://raw.githubusercontent.com/\(source.owner)/\(source.repo)/\(source.branch)/\(Self.percentEncodedPath(entry.path))")
                // Unconstructable URLs mean the remote path is malformed
                // beyond repair: skip the entry (with a plain `%` it is
                // still encodable, so this is a belt-and-braces guard)
                // rather than letting it crash the fetch.
                guard let githubURL, let rawURL else { return nil }
                return CatalogSkill(
                    id: "\(source.id):\(entry.path)",
                    sourceID: source.id,
                    name: name,
                    skillPath: entry.path,
                    githubURL: githubURL,
                    rawURL: rawURL
                )
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return CatalogPage(skills: skills, truncated: response.truncated)
    }
}
