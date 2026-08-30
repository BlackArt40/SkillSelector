import Foundation
import XCTest
@testable import SkillSelectorCore

/// Exercises the catalog fetcher against stubbed URL responses — no live
/// network in tests.
final class CatalogFetcherTests: XCTestCase {
    private let source = CatalogSource(
        id: "anthropics/skills",
        displayName: "Anthropic Skills",
        owner: "anthropics",
        repo: "skills",
        branch: "main"
    )

    // MARK: URLProtocol stub

    private final class StubProtocol: URLProtocol {
        nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let handler = Self.handler, let url = request.url else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            let (status, data) = handler(request)
            let response = HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private func makeFetcher() -> CatalogFetcher {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return CatalogFetcher(session: URLSession(configuration: configuration))
    }

    private func treeJSON(_ entries: [[String]]) -> Data {
        // Each entry: [path, type]
        let objects: [[String: Any]] = entries.map { entry in
            var object: [String: Any] = ["path": entry[0], "type": entry[1]]
            if entry[1] == "blob" { object["size"] = 10 }
            return object
        }
        let payload: [String: Any] = ["sha": "abc", "truncated": false, "tree": objects]
        return try! JSONSerialization.data(withJSONObject: payload)
    }

    override func tearDown() {
        StubProtocol.handler = nil
        super.tearDown()
    }

    // MARK: Tree parsing

    func testParsesTreeAndFiltersSkillEntries() async throws {
        StubProtocol.handler = { [self] request in
            XCTAssertEqual(
                request.url?.absoluteString,
                "https://api.github.com/repos/anthropics/skills/git/trees/main?recursive=1"
            )
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"), "the catalog is anonymous")
            return (
                200,
                treeJSON([
                    ["skills/pdf/SKILL.md", "blob"],
                    ["skills/pdf/scripts/run.py", "blob"],
                    ["skills/pptx/SKILL.md", "blob"],
                    ["README.md", "blob"],
                    [".github/workflows/SKILL.md", "blob"],
                    ["skills/canvas-design", "tree"],
                ])
            )
        }

        let page = try await makeFetcher().fetchSkills(source: source)

        XCTAssertEqual(page.truncated, false)
        XCTAssertEqual(page.skills.map(\.name), ["pdf", "pptx"])
        XCTAssertEqual(page.skills.map(\.skillPath), ["skills/pdf/SKILL.md", "skills/pptx/SKILL.md"])
        let pdf = try XCTUnwrap(page.skills.first { $0.name == "pdf" })
        XCTAssertEqual(pdf.id, "anthropics/skills:skills/pdf/SKILL.md")
        XCTAssertEqual(
            pdf.githubURL.absoluteString,
            "https://github.com/anthropics/skills/tree/main/skills/pdf"
        )
        XCTAssertEqual(
            pdf.rawURL.absoluteString,
            "https://raw.githubusercontent.com/anthropics/skills/main/skills/pdf/SKILL.md"
        )
    }

    func testRootLevelSkillUsesRepoAsName() async throws {
        StubProtocol.handler = { [self] _ in
            (200, treeJSON([["SKILL.md", "blob"]]))
        }
        let page = try await makeFetcher().fetchSkills(source: source)
        XCTAssertEqual(page.skills.count, 1)
        XCTAssertEqual(page.skills.first?.name, "skills")
        XCTAssertEqual(
            page.skills.first?.githubURL.absoluteString,
            "https://github.com/anthropics/skills"
        )
    }

    /// Remote-controlled repo paths may contain spaces, `?`, `#`, or `%` —
    /// macOS's strict URL parser returns nil for those when interpolated
    /// raw, and a `URL(string:)!` would crash the app on any marketplace
    /// source publishing such a path. They must be percent-encoded instead.
    func testRemotePathsWithSpecialCharactersAreEncodedNotCrashed() async throws {
        StubProtocol.handler = { [self] _ in
            (200, treeJSON([
                ["my skill/SKILL.md", "blob"],
                ["we?ird#name/SKILL.md", "blob"],
                ["100%pct/SKILL.md", "blob"],
            ]))
        }

        let page = try await makeFetcher().fetchSkills(source: source)

        XCTAssertEqual(page.skills.count, 3, "no entry may crash the parse or be dropped")
        let spaced = try XCTUnwrap(page.skills.first { $0.name == "my skill" })
        XCTAssertEqual(
            spaced.rawURL.absoluteString,
            "https://raw.githubusercontent.com/anthropics/skills/main/my%20skill/SKILL.md"
        )
        XCTAssertEqual(
            spaced.githubURL.absoluteString,
            "https://github.com/anthropics/skills/tree/main/my%20skill"
        )
        let question = try XCTUnwrap(page.skills.first { $0.name == "we?ird#name" })
        XCTAssertEqual(
            question.rawURL.absoluteString,
            "https://raw.githubusercontent.com/anthropics/skills/main/we%3Fird%23name/SKILL.md"
        )
        let percent = try XCTUnwrap(page.skills.first { $0.name == "100%pct" })
        XCTAssertEqual(
            percent.rawURL.absoluteString,
            "https://raw.githubusercontent.com/anthropics/skills/main/100%25pct/SKILL.md"
        )
    }

    func testTruncatedFlagPropagates() async throws {
        let payload: [String: Any] = [
            "sha": "abc", "truncated": true,
            "tree": [["path": "skills/pdf/SKILL.md", "type": "blob"]],
        ]
        StubProtocol.handler = { _ in (200, try! JSONSerialization.data(withJSONObject: payload)) }
        let page = try await makeFetcher().fetchSkills(source: source)
        XCTAssertEqual(page.truncated, true, "a truncated tree must be flagged, not silently partial")
    }

    func testErrorMapping() async {
        StubProtocol.handler = { _ in (403, Data("rate limit".utf8)) }
        do {
            _ = try await makeFetcher().fetchSkills(source: source)
            XCTFail("expected rateLimited")
        } catch {
            XCTAssertEqual(error as? CatalogError, .rateLimited)
        }

        StubProtocol.handler = { _ in (404, Data()) }
        do {
            _ = try await makeFetcher().fetchSkills(source: source)
            XCTFail("expected http(404)")
        } catch {
            XCTAssertEqual(error as? CatalogError, .http(status: 404))
        }

        StubProtocol.handler = { _ in (200, Data("not json".utf8)) }
        do {
            _ = try await makeFetcher().fetchSkills(source: source)
            XCTFail("expected invalidResponse")
        } catch {
            XCTAssertEqual(error as? CatalogError, .invalidResponse)
        }
    }

    // MARK: Document fetch

    func testFetchesSkillDocument() async throws {
        let body = "---\nname: pdf\n---\n# PDF skill\n"
        StubProtocol.handler = { [self] request in
            XCTAssertEqual(
                request.url?.absoluteString,
                "https://raw.githubusercontent.com/anthropics/skills/main/skills/pdf/SKILL.md"
            )
            return (200, Data(body.utf8))
        }
        let document = try await makeFetcher().fetchDocument(CatalogSkill(
            id: "anthropics/skills:skills/pdf/SKILL.md",
            sourceID: source.id,
            name: "pdf",
            skillPath: "skills/pdf/SKILL.md",
            githubURL: URL(string: "https://github.com/anthropics/skills/tree/main/skills/pdf")!,
            rawURL: URL(string: "https://raw.githubusercontent.com/anthropics/skills/main/skills/pdf/SKILL.md")!
        ))
        XCTAssertEqual(document, body)
    }

    func testOversizedDocumentIsRejected() async {
        let huge = Data(repeating: 0x41, count: CatalogFetcher.maximumDocumentBytes + 1)
        StubProtocol.handler = { _ in (200, huge) }
        do {
            _ = try await makeFetcher().fetchDocument(CatalogSkill(
                id: "x", sourceID: source.id, name: "big", skillPath: "skills/big/SKILL.md",
                githubURL: URL(string: "https://github.com/anthropics/skills")!,
                rawURL: URL(string: "https://raw.githubusercontent.com/anthropics/skills/main/skills/big/SKILL.md")!
            ))
            XCTFail("expected oversized")
        } catch {
            XCTAssertEqual(error as? CatalogError, .oversized)
        }
    }

    // MARK: Repo metadata

    private static let repoJSON = """
    {
      "name": "skills",
      "owner": { "login": "anthropics" },
      "stargazers_count": 12345,
      "forks_count": 678,
      "pushed_at": "2026-08-30T11:21:44Z",
      "default_branch": "main",
      "license": { "spdx_id": "MIT" }
    }
    """

    func testParsesRepoMetadata() throws {
        let repo = try CatalogFetcher.parseRepo(Data(Self.repoJSON.utf8))

        XCTAssertEqual(repo.owner, "anthropics")
        XCTAssertEqual(repo.repo, "skills")
        XCTAssertEqual(repo.stars, 12345)
        XCTAssertEqual(repo.forks, 678)
        XCTAssertEqual(repo.license, "MIT")
        XCTAssertEqual(repo.defaultBranch, "main")
        XCTAssertNotNil(repo.pushedAt)
    }

    func testParsesRepoWithoutLicenseOrPushDate() throws {
        let json = """
        { "name": "skills", "owner": { "login": "x" },
          "stargazers_count": 0, "forks_count": 0, "default_branch": "main",
          "pushed_at": null, "license": null }
        """
        let repo = try CatalogFetcher.parseRepo(Data(json.utf8))

        XCTAssertNil(repo.license)
        XCTAssertNil(repo.pushedAt)
    }

    func testMalformedRepoJSONThrows() {
        XCTAssertThrowsError(try CatalogFetcher.parseRepo(Data("{nope".utf8)))
    }

    func testFetchRepoInfo() async throws {
        StubProtocol.handler = { [self] request in
            XCTAssertEqual(
                request.url?.absoluteString,
                "https://api.github.com/repos/anthropics/skills"
            )
            return (200, Data(Self.repoJSON.utf8))
        }
        let repo = try await makeFetcher().fetchRepoInfo(source: source)

        XCTAssertEqual(repo.owner, "anthropics")
        XCTAssertEqual(repo.stars, 12345)
    }

    func testFetchRepoInfoRateLimited() async {
        StubProtocol.handler = { _ in (429, Data()) }
        do {
            _ = try await makeFetcher().fetchRepoInfo(source: source)
            XCTFail("expected rateLimited")
        } catch CatalogError.rateLimited {
            // Expected — anonymous rate limits surface as the same error.
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}
