import Foundation
import XCTest
@testable import SkillSelectorCore

final class SkillSimilarityFingerprintTests: XCTestCase {
    /// A realistic body: diverse sentences (no repeats), ~1,300 characters,
    /// far over the minimum length. Repeated-sentence fixtures are
    /// degenerate for shingling — nearly all shingles collapse into one —
    /// so the tests use varied prose like real Skill bodies.
    private let longBody: String = {
        let sentences = [
            "This skill guides the assistant through reviewing a pull request end to end.",
            "It first checks out the branch and reads the diff hunks carefully.",
            "Then it maps each hunk back to the surrounding module and its tests.",
            "The assistant flags risky changes that lack coverage or invariants.",
            "It writes concise comments that reference the exact lines in question.",
            "When the author replies, the skill tracks resolutions per thread.",
            "Before approval it re-runs the local suite and the lint pipeline.",
            "Finally it summarizes the verdict with a short bullet list.",
            "The summary mentions scope, risk, coverage, and follow-up work.",
            "Teams can customize thresholds through a small settings block.",
            "Everything runs locally without any network access or telemetry.",
            "Logs are redacted so no repository path leaves the machine.",
        ]
        return sentences.joined(separator: " ")
    }()

    private var driftedBody: String {
        longBody.replacingOccurrences(
            of: "It first checks out the branch and reads the diff hunks carefully.",
            with: "It first fetches the branch and scans the diff hunks deliberately."
        )
    }

    private var unrelatedBody: String {
        let sentences = [
            "Zebra migrations cross the savanna while satellites photograph river deltas.",
            "Coffee roasters adjust drum temperature by seconds during first crack.",
            "Bicycle couriers navigate alley shortcuts that maps do not record.",
            "Librarians catalogue marginalia left by readers across centuries.",
            "Radio operators bounce signals off meteor trails at dawn.",
            "Bakers laminate dough through repeated folds on cold marble.",
            "Cartographers redraw coastlines after each storm season.",
            "Teachers stage debates where every claim needs a citation.",
        ]
        return sentences.joined(separator: " ")
    }

    func testIdenticalBodiesShareTheFingerprint() {
        let lhs = SkillSimilarityFingerprint.compute(body: longBody)
        let rhs = SkillSimilarityFingerprint.compute(body: longBody)
        XCTAssertNotNil(lhs)
        XCTAssertEqual(lhs, rhs)
        XCTAssertEqual(SkillSimilarityFingerprint.similarityPercent(lhs!, rhs!), 100)
        XCTAssertTrue(lhs!.hasPrefix("s1:"))
    }

    func testSmallEditStaysWithinNearDuplicateSimilarity() {
        let lhs = SkillSimilarityFingerprint.compute(body: longBody)!
        let rhs = SkillSimilarityFingerprint.compute(body: driftedBody)!
        XCTAssertGreaterThanOrEqual(
            SkillSimilarityFingerprint.similarityPercent(lhs, rhs)!,
            SkillSimilarityFingerprint.minimumSimilarityPercent,
            "copies with a small edit must group as near duplicates"
        )
        XCTAssertTrue(SkillSimilarityFingerprint.areNearDuplicates(lhs, rhs))
    }

    func testUnrelatedBodiesAreFarApart() {
        let lhs = SkillSimilarityFingerprint.compute(body: longBody)!
        let rhs = SkillSimilarityFingerprint.compute(body: unrelatedBody)!
        XCTAssertLessThan(
            SkillSimilarityFingerprint.similarityPercent(lhs, rhs)!,
            SkillSimilarityFingerprint.minimumSimilarityPercent
        )
        XCTAssertFalse(SkillSimilarityFingerprint.areNearDuplicates(lhs, rhs))
    }

    func testHalfRewrittenBodyIsNotANearDuplicate() {
        let halfway = longBody.index(longBody.startIndex, offsetBy: longBody.count / 2)
        let rewritten = String(longBody[..<halfway])
            + String(repeating: "Fresh replacement material about shipping logistics and harbor scheduling fills the rest. ", count: 3)
        let lhs = SkillSimilarityFingerprint.compute(body: longBody)!
        let rhs = SkillSimilarityFingerprint.compute(body: rewritten)!
        XCTAssertFalse(
            SkillSimilarityFingerprint.areNearDuplicates(lhs, rhs),
            "half of the body replaced is no longer a drifted copy"
        )
    }

    func testFormattingOnlyChangesDoNotAffectTheFingerprint() {
        // Same words: uppercased, punctuation doubled, whitespace reflowed,
        // markdown decorations added, one extra short tag line appended.
        let decorated = "# \(longBody.uppercased())  \n\n> **emphasized** -- restated"
        let lhs = SkillSimilarityFingerprint.compute(body: longBody)!
        let rhs = SkillSimilarityFingerprint.compute(body: decorated)!
        XCTAssertGreaterThanOrEqual(
            SkillSimilarityFingerprint.similarityPercent(lhs, rhs)!,
            SkillSimilarityFingerprint.minimumSimilarityPercent
        )
    }

    func testShortBodiesGetNoFingerprint() {
        XCTAssertNil(SkillSimilarityFingerprint.compute(body: "# too short"))
        XCTAssertNil(
            SkillSimilarityFingerprint.compute(
                body: String(repeating: "a", count: SkillSimilarityFingerprint.minimumBodyLength - 1)
            )
        )
    }

    func testSimilarityRejectsForeignValues() {
        let fingerprint = SkillSimilarityFingerprint.compute(body: longBody)!
        XCTAssertNil(SkillSimilarityFingerprint.similarityPercent(fingerprint, "v2:deadbeef"))
        XCTAssertNil(SkillSimilarityFingerprint.similarityPercent(fingerprint, ""))
        XCTAssertNil(SkillSimilarityFingerprint.similarityPercent(fingerprint, "s1:zzzz"))
        XCTAssertFalse(SkillSimilarityFingerprint.areNearDuplicates(fingerprint, "s1:zzzz"))
    }

    func testSimilarityPercentIsSymmetricAndBounded() {
        let original = SkillSimilarityFingerprint.compute(body: longBody)!
        let edited = SkillSimilarityFingerprint.compute(body: driftedBody)!
        let forward = SkillSimilarityFingerprint.similarityPercent(original, edited)!
        let backward = SkillSimilarityFingerprint.similarityPercent(edited, original)!
        XCTAssertEqual(forward, backward)
        XCTAssertGreaterThanOrEqual(forward, 0)
        XCTAssertLessThanOrEqual(forward, 100)
    }

    func testComputePairReadsBothFingerprintsFromFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SimilarityFingerprintTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let entry = directory.appendingPathComponent("SKILL.md")
        try "---\nname: sample\ndescription: sample skill\n---\n\(longBody)".write(
            to: entry, atomically: true, encoding: .utf8
        )

        let pair = try SkillSimilarityFingerprint.computePair(entryFileURL: entry)
        // The exact fingerprint matches the v2 body-only SHA-256…
        XCTAssertEqual(
            pair.content,
            try SkillContentFingerprint.compute(entryFileURL: entry)
        )
        // …and the similarity fingerprint is the same value a direct body
        // computation produces (frontmatter excluded).
        XCTAssertEqual(pair.similarity, SkillSimilarityFingerprint.compute(body: longBody))
    }

    /// CJK bodies are unspaced — character shingles must handle them the
    /// same way as spaced scripts.
    func testCJKBodiesCompareByCharacterShingles() {
        let original = [
            "这个技能负责审查代码变更，并逐段阅读差异内容。",
            "它会把每处修改映射回所属模块与对应的测试用例。",
            "对于缺少覆盖率或缺少断言的高风险改动会做出标记。",
            "评论保持简洁，并精确引用相关行号与上下文。",
            "作者回复之后，按讨论串逐条跟踪解决状态。",
            "审批之前会重新运行本地测试与静态检查流程。",
            "最后以简短列表汇总审查结论与后续工作安排。",
            "所有步骤都在本地完成，不需要联网也不上传数据。",
            "日志输出经过脱敏处理，仓库路径不会离开本机。",
            "团队可以通过配置块调整各阈值的默认取值。",
            "技能入口文件只包含一份说明与若干模板。",
            "模板中的占位符会在执行前被逐个替换填充。",
        ].joined()
        let edited = original.replacingOccurrences(of: "逐段阅读差异内容", with: "逐段细读差异文本")
        let lhs = SkillSimilarityFingerprint.compute(body: original)!
        let rhs = SkillSimilarityFingerprint.compute(body: edited)!
        XCTAssertGreaterThanOrEqual(
            SkillSimilarityFingerprint.similarityPercent(lhs, rhs)!,
            SkillSimilarityFingerprint.minimumSimilarityPercent
        )
    }
}
