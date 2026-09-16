import XCTest
@testable import SkillSelector
@testable import SkillSelectorCore

/// Pins the two halves of the MCP explanation contract: every settled
/// verdict carries something to try, and a healthy one carries nothing.
/// The second half is the one worth a test — it is easy to "improve" a
/// running server with advice it does not need, and that trains people to
/// ignore the section.
final class McpExplanationsTests: XCTestCase {

    func testHealthyAndPendingVerdictsCarryNoNextStep() {
        XCTAssertNil(McpExplanations.probeNextStep(for: .running))
        XCTAssertNil(McpExplanations.probeNextStep(for: .unknown))
        XCTAssertNil(McpExplanations.probeNextStep(for: .probing))
    }

    func testEverySettledFailureCarriesANextStep() {
        for failure in Self.allFailures {
            let step = McpExplanations.probeNextStep(for: .failed(failure))
            XCTAssertNotNil(step, "\(failure) has no next step")
            XCTAssertFalse(step?.isEmpty ?? true, "\(failure) has an empty next step")
        }
    }

    func testNotRunningCarriesANextStep() {
        let step = McpExplanations.probeNextStep(for: .notRunning)
        XCTAssertNotNil(step)
        XCTAssertFalse(step?.isEmpty ?? true)
    }

    func testEveryFailureIsExplained() {
        for failure in Self.allFailures {
            XCTAssertFalse(McpExplanations.probeReason(failure).isEmpty)
        }
    }

    func testEverySkippedConfigCarriesAReasonAndANextStep() {
        let issues = [
            McpScanIssue(configPath: "/tmp/oversized.json", kind: .fileTooLarge(bytes: 4_194_304)),
            McpScanIssue(configPath: "/tmp/unreadable.json", kind: .unreadable),
            McpScanIssue(configPath: "/tmp/broken.json", kind: .parseFailed(description: "unexpected token")),
        ]
        for issue in issues {
            XCTAssertFalse(McpExplanations.scanIssueReason(issue).isEmpty)
            XCTAssertFalse(McpExplanations.scanIssueNextStep(issue).isEmpty)
        }
    }

    /// The parser message is the whole point of `.parseFailed`: without it
    /// the panel would say only "parse failed" and send the user hunting.
    func testParseFailureKeepsTheParserMessage() {
        let reason = McpExplanations.scanIssueReason(
            McpScanIssue(configPath: "/tmp/broken.json", kind: .parseFailed(description: "unexpected token at line 4"))
        )
        XCTAssertTrue(reason.contains("unexpected token at line 4"), "got: \(reason)")
    }

    /// Every case spelled out, so the tests above actually cover the enum.
    ///
    /// This list is not compiler-enforced: the switch inside
    /// `McpExplanations.probeNextStep` is what turns a new case into a
    /// compile error. This is what makes the assertions above reach the new
    /// case, so the two belong together.
    private static let allFailures: [McpProbeFailure] = [
        .missingCommand,
        .executableNotFound(command: "npx"),
        .launchFailed(detail: "Operation not permitted"),
        .writeFailed,
        .initializeError,
        .missingURL,
        .unsupportedScheme(url: "file:///tmp/server"),
    ]
}
