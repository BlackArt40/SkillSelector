import Dispatch
import Foundation
import XCTest
@testable import SkillSelectorCore

/// Pins the shape of the index's cost curve on a synthetic corpus, so a
/// change that turns a linear path into a superlinear one fails here rather
/// than being discovered by someone with a large install.
///
/// Recorded baseline — debug build, in-memory SQLite, 2026-09-16 dev host
/// (macOS 12, Intel i7-9750H), which is what CI's `swift test` also builds:
///
///     n=500   apply_cold=264ms  read_all=37ms   apply_warm=292ms  single_read×500=303ms
///     n=3000  apply_cold=1539ms read_all=202ms  apply_warm=1747ms single_read×3000=1840ms
///
/// Two readings of that table, both of which contradict the obvious guess
/// and are worth keeping before anyone optimises:
///
/// - **`apply` is the expensive call, not `skills()`.** The M14 note points
///   at the full-table read, but that read is 202ms at 3000 rows — `apply`
///   is ~8.7x more. It costs the same whether or not anything changed,
///   because it never dirty-checks: every installation is re-encoded and
///   upserted on every refresh. A no-op refresh of 3000 skills is therefore
///   ~1.7s of write traffic that changed nothing.
/// - **`skill(path:)` is not a bulk read.** Each call opens its own read
///   transaction (~0.61ms/row), so walking the whole table row by row costs
///   1840ms where one `skills()` costs 202ms — 9x worse. It is a win for
///   the targeted fingerprint backfill it was added for, and a trap if used
///   for anything wider.
///
/// The bounds are deliberately loose. This runs on a shared CI runner, so
/// the load-bearing guard is the *ratio* between corpus sizes (a linear
/// path measures ~6x from 500 to 3000; a quadratic one would be ~36x).
/// The absolute values are recorded for the log and to catch outright
/// catastrophe. Tighten them once CI variance is known.
final class PerformanceBaselineTests: XCTestCase {

    /// A linear path measures ~6x across these sizes. Anything past 12x is
    /// superlinear, not noise.
    private let maximumLinearRatio = 12.0

    private struct Timing {
        let count: Int
        let applyCold: Double
        let readAll: Double
        let applyWarm: Double
        let singleReads: Double
    }

    func testIndexCostCurveStaysLinearOnSyntheticCorpus() throws {
        let small = try measure(count: 500)
        let large = try measure(count: 3_000)

        for timing in [small, large] {
            print(
                "PERF|n=\(timing.count)"
                    + "|apply_cold=\(format(timing.applyCold))ms"
                    + "|read_all=\(format(timing.readAll))ms"
                    + "|apply_warm=\(format(timing.applyWarm))ms"
                    + "|single_read_xN=\(format(timing.singleReads))ms"
                    + "|per_skill_read=\(format(timing.singleReads / Double(timing.count)))ms"
            )
        }

        // Superlinearity guard — machine-independent, so this is the one
        // that should be trusted across hosts.
        try assertLinear(label: "apply_cold", small.applyCold, large.applyCold)
        try assertLinear(label: "read_all", small.readAll, large.readAll)
        try assertLinear(label: "apply_warm", small.applyWarm, large.applyWarm)
        try assertLinear(label: "single_read_xN", small.singleReads, large.singleReads)

        // Catastrophe guard — the value on the larger corpus must at least
        // stay inside an order of magnitude of the recorded baseline.
        XCTAssertLessThan(large.applyCold, 12_000, "apply on 3000 skills collapsed")
        XCTAssertLessThan(large.readAll, 1_600, "full read of 3000 skills collapsed")
        XCTAssertLessThan(large.applyWarm, 14_000, "no-op refresh of 3000 skills collapsed")
        XCTAssertLessThan(large.singleReads, 15_000, "3000 single-row reads collapsed")
    }

    /// The incremental single-row read exists to make a partial update cheap.
    /// If it ever becomes cheaper to fetch everything, this fails and whoever
    /// is touching it gets told why the narrow accessor was added.
    ///
    /// Deliberately a smaller corpus than the curve test: the relationship
    /// holds at any size, and this one only needs to be true, not large.
    func testFullReadStaysCheaperThanWalkingTheTableRowByRow() throws {
        let timing = try measure(count: 1_000)
        XCTAssertLessThan(
            timing.readAll,
            timing.singleReads,
            "a full skills() read (\(format(timing.readAll))ms) should beat "
                + "1000 targeted skill(path:) reads (\(format(timing.singleReads))ms)"
        )
    }

    // MARK: - Harness

    private func measure(count: Int) throws -> Timing {
        let index = SkillIndex(database: try SkillStore.inMemory())
        let report = syntheticReport(count: count)

        let applyCold = try milliseconds { try index.apply(report: report) }
        let readAll = try milliseconds { _ = try index.skills() }
        // The second apply carries identical data: this is the cost of a
        // refresh that changed nothing, which is the common case.
        let applyWarm = try milliseconds { try index.apply(report: report) }
        let singleReads = try milliseconds {
            for i in 0..<count {
                _ = try index.skill(path: Self.path(i))
            }
        }

        XCTAssertEqual(try index.skills().count, count, "corpus did not persist")
        return Timing(
            count: count,
            applyCold: applyCold,
            readAll: readAll,
            applyWarm: applyWarm,
            singleReads: singleReads
        )
    }

    private func assertLinear(label: String, _ small: Double, _ large: Double) throws {
        let ratio = large / max(small, 0.001)
        XCTAssertLessThan(
            ratio,
            maximumLinearRatio,
            "\(label) grew \(format(ratio))x from 500 to 3000 skills; a linear path is ~6x"
        )
    }

    private static func path(_ i: Int) -> String {
        "/tmp/project/.agents/skills/skill-\(i)"
    }

    /// Shaped like a real multi-agent install: several agents share one root,
    /// and the fingerprints repeat so the duplicate and near-duplicate
    /// groupings have something to group.
    private func syntheticReport(count: Int) -> ScanReport {
        let rootID = "project"
        let agents: Set<String> = ["cursor", "codex"]

        var installations: [ScannedSkill] = []
        installations.reserveCapacity(count)
        for i in 0..<count {
            installations.append(
                ScannedSkill(
                    installation: SkillInstallation(
                        path: URL(fileURLWithPath: Self.path(i)),
                        resolvedTarget: nil,
                        agentIDs: agents
                    ),
                    document: ParsedSkillDocument(
                        name: "skill-\(i)",
                        description: "Synthetic skill #\(i) for the performance baseline; not a real skill.",
                        title: "Skill \(i)",
                        firstDescriptiveParagraph: "Paragraph body for synthetic skill #\(i).",
                        fields: ["name": "skill-\(i)"],
                        issues: []
                    ),
                    agentIDsByRoot: [rootID: agents],
                    entryFilename: "SKILL.md",
                    entryModificationDate: Date(timeIntervalSince1970: 1_700_000_000 + Double(i)),
                    contentFingerprint: "content-\(i % 250)",
                    similarityFingerprint: "sim-\(i % 400)"
                )
            )
        }

        return ScanReport(
            installations: installations,
            roots: [
                ScannedRoot(
                    id: rootID,
                    url: URL(fileURLWithPath: "/tmp/project"),
                    availability: .available
                )
            ]
        )
    }

    private func milliseconds(_ body: () throws -> Void) rethrows -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        try body()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    private func format(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}
