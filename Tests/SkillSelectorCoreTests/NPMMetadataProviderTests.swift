import Foundation
import XCTest
@testable import SkillSelectorCore

final class NPMMetadataProviderTests: XCTestCase {
    func testPackageDescriptionWinsAndNPMUsesOnlySearchAndViewJSON() async throws {
        let runner = MetadataFixtureRunner(results: [
            .success(result(stdout: #"[{"name":"@acme/demo"}]"#)),
            .success(result(stdout: ##"{"name":"@acme/demo","description":"Exact package description.","readme":"# Demo\n\nREADME fallback."}"##)),
        ])
        let provider = NPMMetadataProvider(
            executableURL: URL(fileURLWithPath: "/usr/bin/npm"),
            runner: runner
        )

        let candidates = try await provider.candidates(for: MetadataQuery(name: "demo"))

        XCTAssertEqual(candidates, [
            MetadataCandidate(
                provider: .npm,
                sourceIdentifier: "@acme/demo",
                skillSubdirectory: nil,
                description: "Exact package description.",
                evidenceURL: URL(string: "https://www.npmjs.com/package/%40acme%2Fdemo")!,
                sourceBinding: nil
            ),
        ])
        XCTAssertEqual(runner.commands.map(\.arguments), [
            ["search", "demo", "--json"],
            ["view", "--json", "--", "@acme/demo"],
        ])
        XCTAssertTrue(runner.commands.flatMap(\.arguments).allSatisfy {
            !["install", "exec", "run", "npx"].contains($0)
        })
    }

    func testReadmeParagraphIsFallbackWhenPackageDescriptionIsMissing() async throws {
        let runner = MetadataFixtureRunner(results: [
            .success(result(stdout: #"[{"name":"demo"}]"#)),
            .success(result(stdout: ###"{"name":"demo","readme":"# Demo\n\nExact npm README paragraph.\n\n## Usage"}"###)),
        ])
        let provider = NPMMetadataProvider(executableURL: URL(fileURLWithPath: "/usr/bin/npm"), runner: runner)

        let candidates = try await provider.candidates(for: MetadataQuery(name: "demo"))
        let candidate = try XCTUnwrap(candidates.first)

        XCTAssertEqual(candidate.description, "Exact npm README paragraph.")
        XCTAssertEqual(candidate.evidenceURL.absoluteString, "https://www.npmjs.com/package/demo")
        XCTAssertNil(candidate.sourceBinding)
    }

    func testReadmeFallbackPreservesExactMultilineSourceSlice() async throws {
        let runner = MetadataFixtureRunner(results: [
            .success(result(stdout: #"[{"name":"demo"}]"#)),
            .success(result(stdout: ###"{"name":"demo","readme":"# Demo\n\nFirst source line\n  indented continuation\nthird source line\n\n## Usage"}"###)),
        ])
        let provider = NPMMetadataProvider(executableURL: URL(fileURLWithPath: "/usr/bin/npm"), runner: runner)

        let candidates = try await provider.candidates(for: MetadataQuery(name: "demo"))
        let candidate = try XCTUnwrap(candidates.first)

        XCTAssertEqual(
            candidate.description,
            "First source line\n  indented continuation\nthird source line"
        )
    }

    func testDashPrefixedPackageNamesAreRejectedBeforeView() async throws {
        let runner = MetadataFixtureRunner(results: [
            .success(result(stdout: #"[{"name":"--help"},{"name":"valid-demo"}]"#)),
            .success(result(stdout: #"{"name":"valid-demo","description":"Valid."}"#)),
        ])
        let provider = NPMMetadataProvider(executableURL: URL(fileURLWithPath: "/usr/bin/npm"), runner: runner)

        let candidates = try await provider.candidates(for: MetadataQuery(name: "demo"))

        XCTAssertEqual(candidates.map(\.sourceIdentifier), ["valid-demo"])
        XCTAssertEqual(runner.commands.map(\.arguments), [
            ["search", "demo", "--json"],
            ["view", "--json", "--", "valid-demo"],
        ])
    }

    func testEmptyAndMalformedResults() async throws {
        let empty = NPMMetadataProvider(
            executableURL: URL(fileURLWithPath: "/usr/bin/npm"),
            runner: MetadataFixtureRunner(results: [.success(result(stdout: "[]"))])
        )
        let emptyCandidates = try await empty.candidates(for: MetadataQuery(name: "demo"))
        XCTAssertEqual(emptyCandidates, [])

        let malformed = NPMMetadataProvider(
            executableURL: URL(fileURLWithPath: "/usr/bin/npm"),
            runner: MetadataFixtureRunner(results: [.success(result(stdout: "{"))])
        )
        await XCTAssertThrowsMetadataError(
            try await malformed.candidates(for: MetadataQuery(name: "demo")),
            expected: .invalidResponse(provider: .npm)
        )
    }

    func testRateLimitedSearchIsClassified() async {
        let provider = NPMMetadataProvider(
            executableURL: URL(fileURLWithPath: "/usr/bin/npm"),
            runner: MetadataFixtureRunner(results: [
                .success(result(stderr: "npm error code E429 Too Many Requests", status: 1)),
            ])
        )

        await XCTAssertThrowsMetadataError(
            try await provider.candidates(for: MetadataQuery(name: "demo")),
            expected: .rateLimited(provider: .npm)
        )
    }

    func testInvalidLocalNameIsRejectedWithoutRunningACommand() async {
        let runner = MetadataFixtureRunner(results: [])
        let provider = NPMMetadataProvider(executableURL: URL(fileURLWithPath: "/usr/bin/npm"), runner: runner)

        await XCTAssertThrowsMetadataError(
            try await provider.candidates(for: MetadataQuery(name: "--help")),
            expected: .invalidQuery
        )
        XCTAssertEqual(runner.commands, [])
    }
}
