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
        XCTAssertEqual(fetcher.skillFetchCount, CatalogRegistry.sources.count, "every declared source is fetched")

        // A repeat activation must not refetch — the loaded state is the cache.
        await model.loadCatalogIfNeeded()
        XCTAssertEqual(fetcher.skillFetchCount, CatalogRegistry.sources.count)
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
        XCTAssertEqual(fetcher.skillFetchCount, CatalogRegistry.sources.count)

        await model.refreshCatalog()
        XCTAssertEqual(
            fetcher.skillFetchCount,
            CatalogRegistry.sources.count * 2,
            "refresh always refetches"
        )
    }

    func testTruncatedFlagSurfaces() async {
        let fetcher = MockFetcher(pages: [
            "anthropics/skills": .success(CatalogPage(skills: page(["pdf"]).skills, truncated: true)),
        ])
        let model = makeModel(fetcher: fetcher)
        await model.loadCatalogIfNeeded()
        XCTAssertEqual(model.catalogState, .loaded(page(["pdf"]).skills, truncated: true))
    }

    func testSingleFailingSourceIsTolerated() async {
        // Per-source tolerance: one broken source lands in the failed-ids
        // list while the rest of the listing loads normally.
        let fetcher = MockFetcher(pages: [
            "anthropics/skills": .success(page(["pdf"])),
            "obra/superpowers": .failure(CatalogError.rateLimited),
        ])
        let model = makeModel(fetcher: fetcher)

        await model.loadCatalogIfNeeded()
        guard case .loaded(let skills, _) = model.catalogState else {
            return XCTFail("a single failing source must not fail the load")
        }
        XCTAssertEqual(skills.map(\.name), ["pdf"])
        XCTAssertEqual(model.catalogFailedSourceIDs, ["obra/superpowers"])
    }

    func testAllSourcesFailingMapsToFailure() async {
        var pages: [String: Result<CatalogPage, Error>] = [:]
        for source in CatalogRegistry.sources {
            pages[source.id] = .failure(CatalogError.rateLimited)
        }
        let model = makeModel(fetcher: MockFetcher(pages: pages))
        await model.loadCatalogIfNeeded()
        // Every source failed — that is a real load failure; the surfaced
        // reason comes from the first declared source's error.
        XCTAssertEqual(model.catalogState, .failed(.rateLimited))
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

    func testSectionsGroupBySourceInDeclarativeOrder() {
        // Pages arrive name-sorted from the fetcher; sections keep that
        // order within a source.
        let skills = page(["alpha", "zulu"]).skills
            + [CatalogSkill(
                id: "obra/superpowers:skills/brainstorming/SKILL.md",
                sourceID: "obra/superpowers",
                name: "brainstorming",
                skillPath: "skills/brainstorming/SKILL.md",
                githubURL: URL(string: "https://github.com/obra/superpowers")!,
                rawURL: URL(string: "https://raw.githubusercontent.com/obra/superpowers/main/skills/brainstorming/SKILL.md")!
            )]

        let sections = CatalogListView.sections(of: skills, sources: CatalogRegistry.sources)

        // Registry order with empty sources dropped; unknown sources ignored.
        XCTAssertEqual(sections.map(\.id), ["anthropics/skills", "obra/superpowers"])

        // The header's repository filter narrows to a single section.
        let filtered = CatalogListView.sections(
            of: skills,
            sources: CatalogRegistry.sources,
            sourceID: "obra/superpowers"
        )
        XCTAssertEqual(filtered.map(\.id), ["obra/superpowers"])
        XCTAssertEqual(filtered[0].skills.map(\.name), ["brainstorming"])
        // Filtering by a source with no listed skills yields nothing.
        XCTAssertTrue(
            CatalogListView.sections(
                of: skills,
                sources: CatalogRegistry.sources,
                sourceID: "mattpocock/skills"
            ).isEmpty
        )
        XCTAssertEqual(sections[0].skills.map(\.name), ["alpha", "zulu"])
        XCTAssertEqual(sections[1].skills.map(\.name), ["brainstorming"])
    }

    func testImportsAndRemovesCustomSource() async {
        let fetcher = MockFetcher(pages: [
            "me/my-skills": .success(page(["mine"])),
        ])
        let suite = "CatalogImport-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try! ModelContainer(
            for: SkillRecord.self,
            AuthorizedRootRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let registry = BuiltInAgentRegistry.make()
        let model = AppModel(
            refresher: IndexRefresher(
                registry: registry,
                bookmarks: BookmarkStore(container: container, adapter: CatalogPathBookmarkAdapter()),
                index: SkillIndex(container: container)
            ),
            index: SkillIndex(container: container),
            registry: registry,
            defaults: defaults,
            catalogFetcher: fetcher,
            catalogSourceStore: UserDefaultsCatalogSourceStore(defaults: defaults)
        )

        XCTAssertEqual(model.catalogSources.count, CatalogRegistry.sources.count)
        XCTAssertTrue(model.addCatalogSource(CustomCatalogSource(owner: "me", repo: "my-skills")))
        XCTAssertEqual(model.catalogSources.count, CatalogRegistry.sources.count + 1)
        XCTAssertFalse(
            model.addCatalogSource(CustomCatalogSource(owner: "me", repo: "my-skills")),
            "duplicate ids are rejected"
        )

        await model.loadCatalogIfNeeded()
        guard case .loaded(let skills, _) = model.catalogState else {
            return XCTFail("expected loaded")
        }
        XCTAssertTrue(skills.contains { $0.name == "mine" }, "the imported source is listed")

        // The import survives a fresh model (UserDefaults persistence).
        let reopened = AppModel(
            refresher: IndexRefresher(
                registry: registry,
                bookmarks: BookmarkStore(container: container, adapter: CatalogPathBookmarkAdapter()),
                index: SkillIndex(container: container)
            ),
            index: SkillIndex(container: container),
            registry: registry,
            defaults: defaults,
            catalogFetcher: fetcher,
            catalogSourceStore: UserDefaultsCatalogSourceStore(defaults: defaults)
        )
        XCTAssertTrue(reopened.catalogSources.contains { $0.id == "me/my-skills" })

        reopened.removeCatalogSource(id: "me/my-skills")
        XCTAssertFalse(reopened.catalogSources.contains { $0.id == "me/my-skills" })
        reopened.removeCatalogSource(id: "anthropics/skills")
        XCTAssertEqual(
            reopened.catalogSources.count,
            CatalogRegistry.sources.count,
            "built-in sources cannot be removed"
        )
    }

    func testFailingImportedSourceDoesNotBreakTheLoad() async {
        let fetcher = MockFetcher(pages: [
            "anthropics/skills": .success(page(["pdf"])),
            "broken/source": .failure(CatalogError.http(status: 404)),
        ])
        let suite = "CatalogPartial-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try! ModelContainer(
            for: SkillRecord.self,
            AuthorizedRootRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let registry = BuiltInAgentRegistry.make()
        let model = AppModel(
            refresher: IndexRefresher(
                registry: registry,
                bookmarks: BookmarkStore(container: container, adapter: CatalogPathBookmarkAdapter()),
                index: SkillIndex(container: container)
            ),
            index: SkillIndex(container: container),
            registry: registry,
            defaults: defaults,
            catalogFetcher: fetcher,
            catalogSourceStore: UserDefaultsCatalogSourceStore(defaults: defaults)
        )
        model.addCatalogSource(CustomCatalogSource(owner: "broken", repo: "source"))

        await model.loadCatalogIfNeeded()
        guard case .loaded(let skills, _) = model.catalogState else {
            return XCTFail("a single failing source must not fail the load")
        }
        XCTAssertEqual(skills.map(\.name), ["pdf"])
        XCTAssertEqual(model.catalogFailedSourceIDs, ["broken/source"])
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
