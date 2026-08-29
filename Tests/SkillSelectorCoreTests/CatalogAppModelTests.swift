import Foundation
import SwiftData
import XCTest
@testable import SkillSelector
@testable import SkillSelectorCore

/// State-machine coverage for the read-only catalog: on-demand load,
/// memory-cache semantics, forced refresh, and failure mapping. The
/// fetcher is a mock — no network in tests.
@MainActor
final class CatalogAppModelTests: XCTestCase {
    private final class MockFetcher: CatalogFetching, @unchecked Sendable {
        private let lock = NSLock()
        private var pages: [String: Result<CatalogPage, Error>]
        private var document: Result<String, Error>
        private(set) var skillFetchCount = 0
        private(set) var documentFetchCount = 0

        init(
            pages: [String: Result<CatalogPage, Error>],
            document: Result<String, Error> = .success("# body\n")
        ) {
            self.pages = pages
            self.document = document
        }

        func fetchSkills(source: CatalogSource) async throws -> CatalogPage {
            try nextSkillPage(for: source).get()
        }

        func fetchDocument(_ skill: CatalogSkill) async throws -> String {
            try nextDocument().get()
        }

        private func nextSkillPage(for source: CatalogSource) -> Result<CatalogPage, Error> {
            lock.lock()
            defer { lock.unlock() }
            skillFetchCount += 1
            return pages[source.id] ?? .success(CatalogPage(skills: [], truncated: false))
        }

        private func nextDocument() -> Result<String, Error> {
            lock.lock()
            defer { lock.unlock() }
            documentFetchCount += 1
            return document
        }
    }

    private func makeModel(fetcher: MockFetcher) -> AppModel {
        let suite = "CatalogAppModelTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let container = try! ModelContainer(
            for: SkillRecord.self,
            AuthorizedRootRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let registry = BuiltInAgentRegistry.make()
        return AppModel(
            refresher: IndexRefresher(
                registry: registry,
                bookmarks: BookmarkStore(container: container, adapter: CatalogPathBookmarkAdapter()),
                index: SkillIndex(container: container)
            ),
            index: SkillIndex(container: container),
            registry: registry,
            defaults: defaults,
            catalogFetcher: fetcher
        )
    }

    private func page(_ names: [String]) -> CatalogPage {
        CatalogPage(
            skills: names.map { name in
                CatalogSkill(
                    id: "s:\(name)",
                    sourceID: "anthropics/skills",
                    name: name,
                    skillPath: "skills/\(name)/SKILL.md",
                    githubURL: URL(string: "https://github.com/anthropics/skills")!,
                    rawURL: URL(string: "https://raw.githubusercontent.com/anthropics/skills/main/skills/\(name)/SKILL.md")!
                )
            },
            truncated: false
        )
    }

    func testLoadsOnDemandThenServesFromMemoryCache() async {
        let fetcher = MockFetcher(pages: [
            "anthropics/skills": .success(page(["pdf", "pptx"])),
            "obra/superpowers": .success(page([])),
        ])
        let model = makeModel(fetcher: fetcher)

        XCTAssertEqual(model.catalogState, .idle)
        await model.loadCatalogIfNeeded()
        XCTAssertEqual(
            model.catalogState,
            .loaded(page(["pdf", "pptx"]).skills + [], truncated: false)
        )
        XCTAssertEqual(fetcher.skillFetchCount, 2, "both declared sources are fetched")

        // A repeat activation must not refetch — the loaded state is the cache.
        await model.loadCatalogIfNeeded()
        XCTAssertEqual(fetcher.skillFetchCount, 2)
    }

    func testRefreshForcesRefetchAndAggregatesSourcesInOrder() async {
        let fetcher = MockFetcher(pages: [
            "anthropics/skills": .success(page(["pdf"])),
            "obra/superpowers": .success(CatalogPage(
                skills: [CatalogSkill(
                    id: "obra/superpowers:skills/brainstorming/SKILL.md",
                    sourceID: "obra/superpowers",
                    name: "brainstorming",
                    skillPath: "skills/brainstorming/SKILL.md",
                    githubURL: URL(string: "https://github.com/obra/superpowers")!,
                    rawURL: URL(string: "https://raw.githubusercontent.com/obra/superpowers/main/skills/brainstorming/SKILL.md")!
                )],
                truncated: false
            )),
        ])
        let model = makeModel(fetcher: fetcher)

        await model.refreshCatalog()
        guard case .loaded(let skills, truncated: false) = model.catalogState else {
            return XCTFail("expected loaded, got \(model.catalogState)")
        }
        XCTAssertEqual(skills.map(\.name), ["pdf", "brainstorming"], "declarative source order holds")
        XCTAssertEqual(fetcher.skillFetchCount, 2)

        await model.refreshCatalog()
        XCTAssertEqual(fetcher.skillFetchCount, 4, "refresh always refetches")
    }

    func testTruncatedFlagSurfaces() async {
        let fetcher = MockFetcher(pages: [
            "anthropics/skills": .success(CatalogPage(skills: page(["pdf"]).skills, truncated: true)),
        ])
        let model = makeModel(fetcher: fetcher)
        await model.loadCatalogIfNeeded()
        XCTAssertEqual(model.catalogState, .loaded(page(["pdf"]).skills, truncated: true))
    }

    func testFailureMapsAndRecoversOnRefresh() async {
        // One failing source fails the whole load (all-or-nothing); the
        // mapping is deterministic with a single thrower.
        let fetcher = MockFetcher(pages: [
            "anthropics/skills": .success(page(["pdf"])),
            "obra/superpowers": .failure(CatalogError.rateLimited),
        ])
        let model = makeModel(fetcher: fetcher)

        await model.loadCatalogIfNeeded()
        XCTAssertEqual(model.catalogState, .failed(.rateLimited))

        // Recovery on the next refresh once the source cooperates again.
        let recovered = MockFetcher(pages: [
            "anthropics/skills": .success(page(["pdf"])),
        ])
        let retryModel = makeModel(fetcher: recovered)
        await retryModel.loadCatalogIfNeeded()
        XCTAssertEqual(retryModel.catalogState, .loaded(page(["pdf"]).skills, truncated: false))
    }

    func testTransportFailureMapsToNetwork() async {
        let fetcher = MockFetcher(pages: [
            "anthropics/skills": .success(page([])),
            "obra/superpowers": .failure(URLError(.notConnectedToInternet)),
        ])
        let model = makeModel(fetcher: fetcher)
        await model.loadCatalogIfNeeded()
        XCTAssertEqual(model.catalogState, .failed(.network))
    }

    func testDescriptionsPrefetchedAfterLoad() async {
        let fetcher = MockFetcher(
            pages: [
                "anthropics/skills": .success(page(["pdf", "pptx"])),
                "obra/superpowers": .success(page([])),
            ],
            document: .success("---\nname: pdf\ndescription: Read and create PDF files.\n---\n# pdf\n")
        )
        let model = makeModel(fetcher: fetcher)

        await model.loadCatalogIfNeeded()
        XCTAssertEqual(
            model.catalogDescriptions["s:pdf"],
            "Read and create PDF files."
        )
        XCTAssertEqual(
            model.catalogDescriptions["s:pptx"],
            "Read and create PDF files."
        )
        XCTAssertEqual(fetcher.documentFetchCount, 2, "one document fetch per listed skill")
    }

    func testDescriptionFetchFailureLeavesNoEntry() async {
        let fetcher = MockFetcher(
            pages: ["anthropics/skills": .success(page(["pdf"]))],
            document: .failure(CatalogError.rateLimited)
        )
        let model = makeModel(fetcher: fetcher)

        await model.loadCatalogIfNeeded()
        XCTAssertTrue(model.catalogDescriptions.isEmpty, "failed prefetch must not crash the listing")
        guard case .loaded = model.catalogState else {
            return XCTFail("listing itself must stay loaded")
        }
    }

    func testDocumentFetchDelegatesToFetcher() async throws {
        let fetcher = MockFetcher(
            pages: [:],
            document: .success("---\nname: pdf\n---\n# PDF\n")
        )
        let model = makeModel(fetcher: fetcher)
        let skill = page(["pdf"]).skills[0]
        let body = try await model.loadCatalogDocument(skill)
        XCTAssertEqual(body, "---\nname: pdf\n---\n# PDF\n")
        XCTAssertEqual(fetcher.documentFetchCount, 1)
    }
}

/// Path-encoding bookmark adapter — same pattern as the other test files'
/// adapters: a bare `swift test` process lacks security-scoped bookmarks.
private final class CatalogPathBookmarkAdapter: BookmarkDataCreating, @unchecked Sendable {
    func createBookmarkData(for url: URL) throws -> Data { Data(url.path.utf8) }

    func resolveBookmarkData(_ data: Data) throws -> BookmarkResolution {
        BookmarkResolution(
            url: URL(fileURLWithPath: String(decoding: data, as: UTF8.self)),
            isStale: false
        )
    }

    func startAccessing(_ url: URL) -> Bool { true }

    func stopAccessing(_ url: URL) {}
}
