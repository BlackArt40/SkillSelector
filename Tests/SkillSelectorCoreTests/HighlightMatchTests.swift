import XCTest
@testable import SkillSelector
@testable import SkillSelectorCore

/// 搜索命中区间查找器（`HighlightMatch.ranges`）单元测试：按空格分词、
/// 忽略大小写/变音符地返回文本中的命中区间，并合并重叠/相邻区间。纯函数，
/// 供所有搜索列表的「命中词高亮」使用。
final class HighlightMatchTests: XCTestCase {
    /// 空查询或纯空白查询不返回任何区间。
    func testReturnsEmptyForBlankQuery() {
        XCTAssertTrue(HighlightMatch.ranges(of: "", in: "anything").isEmpty)
        XCTAssertTrue(HighlightMatch.ranges(of: "  ", in: "anything").isEmpty)
    }

    /// 文本中不存在查询词时返回空。
    func testReturnsEmptyWhenNoHit() {
        XCTAssertTrue(HighlightMatch.ranges(of: "pdf", in: "browser").isEmpty)
    }

    /// 单个命中且忽略大小写：查询 "pdf" 命中文本中的 "PDF"。
    func testSingleHitIsCaseInsensitive() {
        let text = "PDF toolkit"
        let ranges = HighlightMatch.ranges(of: "pdf", in: text)
        XCTAssertEqual(ranges.map { String(text[$0]) }, ["PDF"])
    }

    /// 同一词多次出现时返回多个互不重叠的区间，保持文本顺序。
    func testMultipleNonOverlappingHitsInOrder() {
        let text = "pdf then pdf again"
        let ranges = HighlightMatch.ranges(of: "pdf", in: text)
        XCTAssertEqual(ranges.map { String(text[$0]) }, ["pdf", "pdf"])
        XCTAssertTrue(ranges[0].upperBound <= ranges[1].lowerBound)
    }

    /// 忽略变音符：查询 "cafe" 命中 "café"。
    func testDiacriticInsensitive() {
        let text = "café time"
        let ranges = HighlightMatch.ranges(of: "cafe", in: text)
        XCTAssertEqual(ranges.map { String(text[$0]) }, ["café"])
    }

    /// 按词匹配：查询 "create pdf" 在文本里没有完整连续串时，仍按词分别
    /// 高亮 "create" 与 "PDF"（搜索匹配是分词的，高亮必须跟得上）。
    func testTermWiseMatchingHighlightsPartialHits() {
        let text = "Read and create PDF files."
        // Only "create" and "pdf" appear (not the full "create pdf" run);
        // both words must still highlight, in order.
        let ranges = HighlightMatch.ranges(of: "create pdf", in: text)
        XCTAssertEqual(ranges.map { String(text[$0]) }, ["create", "PDF"])
    }

    /// 重复词命中同一位置时合并为单个区间（不产生重叠高亮）。
    func testDuplicateTermsMergeIntoOneRange() {
        let text = "pdf"
        let ranges = HighlightMatch.ranges(of: "pdf pdf", in: text)
        XCTAssertEqual(ranges.map { String(text[$0]) }, ["pdf"])
    }

    /// 词间有空格时不合并（空格不是命中词），各词独立成段。
    func testTermWiseMatchingHighlightsEachWordSeparately() {
        let text = "pdf toolkit"
        // Words separated by a space keep their own runs (the space is not
        // a hit); both terms still highlight.
        let ranges = HighlightMatch.ranges(of: "pdf tool", in: text)
        XCTAssertEqual(ranges.map { String(text[$0]) }, ["pdf", "tool"])
    }

    /// 相邻且无间隔字符的两个命中合并为一段连续高亮。
    func testAdjacentTermRangesMerge() {
        let text = "pd"
        // "p" and "d" are adjacent, so they merge into one continuous run.
        let ranges = HighlightMatch.ranges(of: "p d", in: text)
        XCTAssertEqual(ranges.map { String(text[$0]) }, ["pd"])
    }
}
