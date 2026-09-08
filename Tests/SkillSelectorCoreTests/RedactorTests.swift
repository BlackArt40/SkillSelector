import Foundation
import XCTest
@testable import SkillSelectorCore

final class RedactorTests: XCTestCase {
    private let redactor = Redactor(
        homeDirectory: URL(fileURLWithPath: "/Users/alice"),
        projectDirectories: [
            URL(fileURLWithPath: "/Users/alice/Work/Secret Project"),
            URL(fileURLWithPath: "/Volumes/Clients/Acme"),
        ]
    )

    func testRedactsKnownPathsUsingStableMostSpecificLabels() {
        let input = "Scanned /Users/alice/Work/Secret Project/.agents/skills/demo and /Users/alice/.codex/skills plus /Volumes/Clients/Acme/.cursor/skills"

        XCTAssertEqual(
            redactor.redact(input),
            "Scanned <project:1>/.agents/skills/demo and <home>/.codex/skills plus <project:2>/.cursor/skills"
        )
        XCTAssertEqual(redactor.redact(input), redactor.redact(input))
    }

    func testPathRedactionDoesNotMatchPartialPathComponents() {
        XCTAssertEqual(
            redactor.redact("User /Users/alice2 and project /Volumes/Clients/AcmeTools"),
            "User /Users/alice2 and project /Volumes/Clients/AcmeTools"
        )
    }

    func testPathRedactionIsCaseInsensitive() {
        XCTAssertEqual(
            redactor.redact("Found at /USERS/alice/.codex/skills and /users/alice/Work/Secret Project/.agents"),
            "Found at <home>/.codex/skills and <project:1>/.agents"
        )
    }

    func testRedactsConfiguredPathsInsideQuotesAndCommonPunctuation() {
        let input = "ASCII \"/Users/alice/.codex/skills\", project '/Users/alice/Work/Secret Project/.agents'; exact home \u{2018}/Users/alice\u{2019}, exact project \u{201C}/Users/alice/Work/Secret Project\u{201D}!"

        XCTAssertEqual(
            redactor.redact(input),
            "ASCII \"<home>/.codex/skills\", project '<project:1>/.agents'; exact home \u{2018}<home>\u{2019}, exact project \u{201C}<project:1>\u{201D}!"
        )
    }

    func testRedactsInlineAuthorizationButPreservesAgentNamesAndErrorCodes() {
        XCTAssertEqual(
            redactor.redact("Cursor and Kilo Code failed with ERR_MCP_401; Authorization: Bearer abc.def.ghi"),
            "Cursor and Kilo Code failed with ERR_MCP_401; Authorization: \(Redactor.redactedValue)"
        )
        XCTAssertEqual(
            redactor.redact("Codex scan completed: 12 Skills, status HTTP_304_NOT_MODIFIED"),
            "Codex scan completed: 12 Skills, status HTTP_304_NOT_MODIFIED"
        )
    }

    func testRedactsExplicitInlineSecretAssignmentsWithoutRemovingMetrics() {
        XCTAssertEqual(
            redactor.redact("request token=ghp_abcdef client_secret: hidden-value token_count=128"),
            "request token=<redacted> client_secret: <redacted> token_count=128"
        )
    }

    func testOrdinaryLongIdentifiersAreNotTreatedAsSecrets() {
        let message = "Agent cursor error diagnostic.unableToReadEntry repository openai/skills request 12345678901234567890"

        XCTAssertEqual(redactor.redact(message), message)
    }

    func testDiagnosticExportContainsOnlyRedactedAppOwnedSummaries() throws {
        let diagnostics = [
            AppDiagnostic(
                timestamp: Date(timeIntervalSince1970: 1_000),
                category: .operations,
                code: "ERR_GH_401",
                message: "gh failed at /Users/alice/Work/Secret Project with Authorization: Bearer abc.def.ghi"
            ),
        ]
        let input = DiagnosticExportInput(
            appVersion: "1.2.3",
            macOSVersion: "14.6.1",
            registryIDs: ["cursor", "kilo-code"],
            roots: [
                DiagnosticRootSummary(id: "root-project", kind: .project, isAvailable: false),
            ],
            diagnostics: diagnostics
        )

        let data = try DiagnosticExporter(redactor: redactor).archive(input)
        let output = String(decoding: data, as: UTF8.self)

        XCTAssertTrue(output.contains("ERR_GH_401"))
        XCTAssertTrue(output.contains("cursor"))
        XCTAssertTrue(output.contains("kilo-code"))
        XCTAssertTrue(output.contains("<project:1>"))
        XCTAssertFalse(output.contains("/Users/alice"))
        XCTAssertFalse(output.contains("Secret Project"))
        XCTAssertFalse(output.contains("abc.def.ghi"))
        XCTAssertFalse(output.contains("SKILL.md"))
        XCTAssertFalse(output.contains("private Skill body"))
    }

    func testRedactsQuotedJSONKeysAndURLUserinfo() {
        // JSON-style config shapes are the most common MCP env form.
        XCTAssertEqual(
            redactor.redact(#"mcp env {"api_key": "sk-12345678"} loaded"#),
            #"mcp env {"api_key": <redacted>} loaded"#
        )
        // URL userinfo keeps the user, drops the password.
        XCTAssertEqual(
            redactor.redact("failed https://user:super-secret@example.com/api"),
            "failed https://user:\(Redactor.redactedValue)@example.com/api"
        )
        // host:port without a trailing "@" is not userinfo — ports survive.
        XCTAssertEqual(
            redactor.redact("port https://example.com:8080/path untouched"),
            "port https://example.com:8080/path untouched"
        )
    }

    func testRedactsNonBearerAuthorizationSchemesAndBareCredentials() {
        // Non-bearer/basic Authorization schemes are redacted up to the
        // next segment separator.
        XCTAssertEqual(
            redactor.redact(#"reply Authorization: Digest realm="x", nonce=abc"#),
            #"reply Authorization: <redacted>, nonce=abc"#
        )
        // Bare credentials after a "token " label (GitHub style).
        XCTAssertEqual(
            redactor.redact("sent token ghp_0123456789abcdef"),
            "sent token \(Redactor.redactedValue)"
        )
        // Unlabeled sk-… prefixes.
        XCTAssertEqual(
            redactor.redact("key sk-ant-api03-0123456789"),
            "key sk-\(Redactor.redactedValue)"
        )
        // Ordinary words containing the same fragments are untouched.
        XCTAssertEqual(
            redactor.redact("task-list updated and skills repo synced"),
            "task-list updated and skills repo synced"
        )
    }

    func testDiagnosticStoreBoundsAndRedactsMessagesBeforeRetention() {
        let store = DiagnosticStore(capacity: 2)

        store.record(category: .scanning, code: "SCAN_1", message: "/Users/alice/one", redactor: redactor)
        store.record(category: .persistence, code: "SAVE_2", message: "Cursor saved", redactor: redactor)
        store.record(category: .operations, code: "UPDATE_3", message: "Bearer top-secret-token", redactor: redactor)

        XCTAssertEqual(store.recent().map(\.code), ["SAVE_2", "UPDATE_3"])
        XCTAssertEqual(store.recent().map(\.message), ["Cursor saved", "Bearer <redacted>"])
    }
}
