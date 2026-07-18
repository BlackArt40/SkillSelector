import Foundation
import XCTest
@testable import SkillSelectorCore

final class GitHubMetadataProviderTests: XCTestCase {
    func testRemoteSkillDescriptionWinsAndCommandsDiscloseOnlyNameAndRemoteSkillLocation() async throws {
        let runner = MetadataFixtureRunner(results: [
            .success(result(stdout: #"[{"path":"skills/demo/SKILL.md","repository":{"nameWithOwner":"acme/skills"},"url":"https://github.com/acme/skills/blob/main/skills/demo/SKILL.md"}]"#)),
            .success(result(stdout: "---\nname: demo\ndescription: Exact remote description.\n---\n\n# Demo\n\nREADME fallback.")),
        ])
        let provider = GitHubMetadataProvider(
            executableURL: URL(fileURLWithPath: "/usr/bin/gh"),
            runner: runner
        )

        let candidates = try await provider.candidates(for: MetadataQuery(name: "demo"))

        XCTAssertEqual(candidates, [
            MetadataCandidate(
                provider: .github,
                sourceIdentifier: "acme/skills",
                skillSubdirectory: "skills/demo",
                description: "Exact remote description.",
                evidenceURL: URL(string: "https://github.com/acme/skills/blob/main/skills/demo/SKILL.md")!,
                sourceBinding: "github:acme/skills:skills/demo:branch:main"
            ),
        ])
        XCTAssertEqual(runner.commands.map(\.arguments), [
            ["search", "code", "demo", "--filename", "SKILL.md", "--json", "path,repository,url", "--limit", "20"],
            ["api", "repos/acme/skills/contents/skills/demo/SKILL.md", "-H", "Accept: application/vnd.github.raw+json"],
        ])
        XCTAssertFalse(runner.commands.flatMap(\.arguments).contains { $0.contains("/Users/") })
    }

    func testRepositoryDescriptionFallsBackWhenRemoteSkillHasNoDescription() async throws {
        let runner = MetadataFixtureRunner(results: [
            .success(result(stdout: #"[{"path":"SKILL.md","repository":{"nameWithOwner":"acme/demo"},"url":"https://github.com/acme/demo/blob/main/SKILL.md"}]"#)),
            .success(result(stdout: "# Demo\n")),
            .success(result(stdout: #"{"description":"Official repository description.","html_url":"https://github.com/acme/demo"}"#)),
        ])
        let provider = GitHubMetadataProvider(executableURL: URL(fileURLWithPath: "/usr/bin/gh"), runner: runner)

        let candidates = try await provider.candidates(for: MetadataQuery(name: "demo"))
        let candidate = try XCTUnwrap(candidates.first)

        XCTAssertEqual(candidate.description, "Official repository description.")
        XCTAssertEqual(candidate.evidenceURL.absoluteString, "https://github.com/acme/demo")
        XCTAssertEqual(runner.commands.last?.arguments, ["api", "repos/acme/demo"])
    }

    func testReadmeParagraphIsFinalFallbackAndPreservesSourceText() async throws {
        let runner = MetadataFixtureRunner(results: [
            .success(result(stdout: #"[{"path":"SKILL.md","repository":{"nameWithOwner":"acme/demo"},"url":"https://github.com/acme/demo/blob/main/SKILL.md"}]"#)),
            .success(result(stdout: "# Demo\n")),
            .success(result(stdout: #"{"description":null,"html_url":"https://github.com/acme/demo"}"#)),
            .success(result(stdout: "# Demo\n\nExact README paragraph, unchanged.\n\n## Install\n")),
        ])
        let provider = GitHubMetadataProvider(executableURL: URL(fileURLWithPath: "/usr/bin/gh"), runner: runner)

        let candidates = try await provider.candidates(for: MetadataQuery(name: "demo"))
        let candidate = try XCTUnwrap(candidates.first)

        XCTAssertEqual(candidate.description, "Exact README paragraph, unchanged.")
        XCTAssertEqual(candidate.evidenceURL.absoluteString, "https://github.com/acme/demo#readme")
        XCTAssertEqual(runner.commands.last?.arguments, [
            "api", "repos/acme/demo/readme", "-H", "Accept: application/vnd.github.raw+json",
        ])
    }

    func testReadmeFallbackPreservesExactMultilineSourceSlice() async throws {
        let runner = MetadataFixtureRunner(results: [
            .success(result(stdout: #"[{"path":"SKILL.md","repository":{"nameWithOwner":"acme/demo"},"url":"https://github.com/acme/demo/blob/main/SKILL.md"}]"#)),
            .success(result(stdout: "# Demo\n")),
            .success(result(stdout: #"{"description":null,"html_url":"https://github.com/acme/demo"}"#)),
            .success(result(stdout: "# Demo\r\n\r\nFirst source line\r\n  indented continuation\r\nthird source line\r\n\r\n## Install\r\n")),
        ])
        let provider = GitHubMetadataProvider(executableURL: URL(fileURLWithPath: "/usr/bin/gh"), runner: runner)

        let candidates = try await provider.candidates(for: MetadataQuery(name: "demo"))
        let candidate = try XCTUnwrap(candidates.first)

        XCTAssertEqual(
            candidate.description,
            "First source line\r\n  indented continuation\r\nthird source line"
        )
    }

    func testEmptySearchReturnsNoCandidates() async throws {
        let runner = MetadataFixtureRunner(results: [.success(result(stdout: "[]"))])
        let provider = GitHubMetadataProvider(executableURL: URL(fileURLWithPath: "/usr/bin/gh"), runner: runner)

        let candidates = try await provider.candidates(for: MetadataQuery(name: "demo"))
        XCTAssertEqual(candidates, [])
        XCTAssertEqual(runner.commands.count, 1)
    }

    func testMalformedJSONThrowsInvalidResponse() async {
        let runner = MetadataFixtureRunner(results: [.success(result(stdout: "not-json"))])
        let provider = GitHubMetadataProvider(executableURL: URL(fileURLWithPath: "/usr/bin/gh"), runner: runner)

        await XCTAssertThrowsMetadataError(
            try await provider.candidates(for: MetadataQuery(name: "demo")),
            expected: .invalidResponse(provider: .github)
        )
    }

    func testRateLimitAndUnauthenticatedFailuresAreClassifiedWithoutParsingBodies() async {
        let rateLimited = GitHubMetadataProvider(
            executableURL: URL(fileURLWithPath: "/usr/bin/gh"),
            runner: MetadataFixtureRunner(results: [.success(result(stderr: "HTTP 403: API rate limit exceeded", status: 1))])
        )
        await XCTAssertThrowsMetadataError(
            try await rateLimited.candidates(for: MetadataQuery(name: "demo")),
            expected: .rateLimited(provider: .github)
        )

        let unauthenticated = GitHubMetadataProvider(
            executableURL: URL(fileURLWithPath: "/usr/bin/gh"),
            runner: MetadataFixtureRunner(results: [.success(result(stderr: "To get started with GitHub CLI, run: gh auth login", status: 4))])
        )
        await XCTAssertThrowsMetadataError(
            try await unauthenticated.candidates(for: MetadataQuery(name: "demo")),
            expected: .unauthenticated(provider: .github)
        )
    }

    func testInvalidRemoteRepositoryAndTraversalPathsAreIgnored() async throws {
        let runner = MetadataFixtureRunner(results: [.success(result(stdout: #"""
            [
            {"path":"../SKILL.md","repository":{"nameWithOwner":"acme/demo"},"url":"https://example.invalid/a"},
            {"path":"SKILL.md","repository":{"nameWithOwner":"-R"},"url":"https://example.invalid/b"}
            ]
            """#))])
        let provider = GitHubMetadataProvider(executableURL: URL(fileURLWithPath: "/usr/bin/gh"), runner: runner)

        let candidates = try await provider.candidates(for: MetadataQuery(name: "demo"))
        XCTAssertEqual(candidates, [])
        XCTAssertEqual(runner.commands.count, 1)
    }

    func testQualifierLikeNamesAreRejectedWithoutRunningACommand() async {
        for name in ["language:swift", "org:foo"] {
            let runner = MetadataFixtureRunner(results: [])
            let provider = GitHubMetadataProvider(
                executableURL: URL(fileURLWithPath: "/usr/bin/gh"),
                runner: runner
            )

            await XCTAssertThrowsMetadataError(
                try await provider.candidates(for: MetadataQuery(name: name)),
                expected: .invalidQuery
            )
            XCTAssertEqual(runner.commands, [])
        }
    }
}

final class MetadataFixtureRunner: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<CommandResult, Error>]
    private var recorded: [ExternalCommand] = []

    init(results: [Result<CommandResult, Error>]) { self.results = results }

    var commands: [ExternalCommand] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    func run(_ command: ExternalCommand) async throws -> CommandResult {
        let result = lock.withLock {
            recorded.append(command)
            return results.isEmpty
                ? Result<CommandResult, Error>.failure(MetadataFixtureError.missingResult)
                : results.removeFirst()
        }
        return try result.get()
    }
}

enum MetadataFixtureError: Error { case missingResult }

func result(stdout: String = "", stderr: String = "", status: Int32 = 0) -> CommandResult {
    CommandResult(
        stdout: Data(stdout.utf8),
        stderr: Data(stderr.utf8),
        terminationStatus: status,
        terminationReason: .exit
    )
}

func XCTAssertThrowsMetadataError<T>(
    _ expression: @autoclosure () async throws -> T,
    expected: MetadataProviderError,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected metadata provider error", file: file, line: line)
    } catch {
        XCTAssertEqual(error as? MetadataProviderError, expected, file: file, line: line)
    }
}
