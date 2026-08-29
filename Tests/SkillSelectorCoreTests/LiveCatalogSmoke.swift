import XCTest
@testable import SkillSelectorCore

/// Live smoke for the catalog fetch path against the real GitHub API.
/// Inert unless LIVE_CATALOG=1 — the normal suite must stay offline and
/// deterministic (run manually: LIVE_CATALOG=1 swift test --filter LiveCatalogSmoke).
final class LiveCatalogSmoke: XCTestCase {
    func testRealSourcesListAndDocumentLoad() async throws {
        guard ProcessInfo.processInfo.environment["LIVE_CATALOG"] == "1" else {
            throw XCTSkip("set LIVE_CATALOG=1 to run against the real GitHub API")
        }
        let fetcher = CatalogFetcher()
        for source in CatalogRegistry.sources {
            let page = try await fetcher.fetchSkills(source: source)
            print("LIVE \(source.id): \(page.skills.count) skills, truncated=\(page.truncated)")
            print("LIVE   first: \(page.skills.prefix(8).map(\.name).joined(separator: ", "))")
            XCTAssertFalse(page.skills.isEmpty, "\(source.id) listed zero skills")
            for skill in page.skills {
                XCTAssertTrue(skill.name == "skills" || !skill.name.isEmpty)
                XCTAssertTrue(skill.rawURL.absoluteString.hasPrefix("https://raw.githubusercontent.com/"))
            }
        }
        // Detail fetch: first skill of the official source, real frontmatter.
        let official = try XCTUnwrap(CatalogRegistry.sources.first)
        let page = try await fetcher.fetchSkills(source: official)
        let target = try XCTUnwrap(page.skills.first { $0.name == "pdf" } ?? page.skills.first)
        let document = try await fetcher.fetchDocument(target)
        print("LIVE document \(target.name): \(document.count) bytes, head:")
        print(document.prefix(160))
        XCTAssertTrue(document.contains("---"), "SKILL.md should carry YAML frontmatter")
        XCTAssertLessThanOrEqual(document.utf8.count, CatalogFetcher.maximumDocumentBytes)
    }
}
