import Foundation
import SkillSelectorCore

/// Every user-facing explanation the MCP surfaces produce, in one place.
///
/// Two callers need the same words: the diagnostics record
/// (`AppModel.recordMcpScanIssues`) and the MCP panel itself. They used to
/// hold separate copies of the same switch, which is exactly how a reason
/// ends up phrased two ways depending on where you read it.
///
/// The house style here is that a `.strings` entry carries no placeholders —
/// dynamic values (commands, byte counts, parser messages) are appended in
/// Swift after a translated label. That keeps the localization parity checks
/// meaningful without format-specifier bookkeeping.
enum McpExplanations {

    // MARK: - Configs the scanner skipped

    /// What went wrong with a config file that exists but produced nothing.
    static func scanIssueReason(_ issue: McpScanIssue) -> String {
        switch issue.kind {
        case .fileTooLarge(let bytes):
            return "\(L10n.string("MCP Config Skipped Too Large")) (\(bytes))"
        case .unreadable:
            return L10n.string("MCP Config Skipped Unreadable")
        case .parseFailed(let description):
            return "\(L10n.string("MCP Config Parse Failed")): \(description)"
        }
    }

    /// The one action that would fix it. Present for every case: a reason
    /// without a next step is what made a broken config feel like a missing
    /// one in the first place.
    static func scanIssueNextStep(_ issue: McpScanIssue) -> String {
        switch issue.kind {
        case .fileTooLarge:
            return L10n.string("MCP Scan Next Step Too Large")
        case .unreadable:
            return L10n.string("MCP Scan Next Step Unreadable")
        case .parseFailed:
            return L10n.string("MCP Scan Next Step Parse Failed")
        }
    }

    // MARK: - Probe verdicts

    /// The primary cause of a failed probe. Dynamic details ride along after
    /// a translated label (review P2-16).
    static func probeReason(_ failure: McpProbeFailure) -> String {
        switch failure {
        case .missingCommand:
            return L10n.string("MCP Missing Command")
        case .executableNotFound(let command):
            return "\(L10n.string("MCP Executable Not Found")): \(command)"
        case .launchFailed(let detail):
            return "\(L10n.string("MCP Launch Failed")): \(detail)"
        case .writeFailed:
            return L10n.string("MCP Write Failed")
        case .initializeError:
            return L10n.string("MCP Initialize Error")
        case .missingURL:
            return L10n.string("MCP Missing URL")
        case .unsupportedScheme(let url):
            return "\(L10n.string("MCP Unsupported Scheme")): \(url)"
        }
    }

    /// What to do about a settled verdict, or nil when there is nothing to
    /// do (a healthy server, or one that has not been probed).
    ///
    /// `.notRunning` gets copy too: it is the verdict users hit most, and it
    /// is the one where the probe's silence is least informative — it
    /// discards stderr, so the server's own complaint never reaches here.
    static func probeNextStep(for status: McpProbeStatus) -> String? {
        switch status {
        case .running, .unknown, .probing:
            return nil
        case .notRunning:
            return L10n.string("MCP Probe Next Step Not Running")
        case .failed(let failure):
            switch failure {
            case .missingCommand:
                return L10n.string("MCP Probe Next Step Missing Command")
            case .executableNotFound:
                return L10n.string("MCP Probe Next Step Executable Not Found")
            case .launchFailed:
                return L10n.string("MCP Probe Next Step Launch Failed")
            case .writeFailed:
                return L10n.string("MCP Probe Next Step Write Failed")
            case .initializeError:
                return L10n.string("MCP Probe Next Step Initialize Error")
            case .missingURL:
                return L10n.string("MCP Probe Next Step Missing URL")
            case .unsupportedScheme:
                return L10n.string("MCP Probe Next Step Unsupported Scheme")
            }
        }
    }
}
