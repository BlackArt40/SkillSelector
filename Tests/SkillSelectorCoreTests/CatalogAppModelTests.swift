import Foundation
import GRDB
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
        private var repoInfo: Result<CatalogRepoMetadata, Error>
        private(set) var skillFetchCount = 0
        private(set) var documentFetchCount = 0
        private(set) var repoInfoFetchCount = 0

        init(
            pages: [String: Result<CatalogPage, Error>],
            document: Result<String, Error> = .success("# body\n"),
            repoInfo: Result<CatalogRepoMetadata, Error> = .success(
                CatalogRepoMetadata(
                    owner: "anthropics",
                    repo: "skills",
                    stars: 120,
                    forks: 30,
                    pushedAt: nil,
                    license: "MIT",
                    defaultBranch: "main"
                )
            )
        ) {
            self.pages = pages
            self.document = document
            self.repoInfo = repoInfo
        }

        func fetchSkills(source: CatalogSource) async throws -> CatalogPage {
            try nextSkillPage(for: source).get()
        }

        func fetchDocument(_ skill: CatalogSkill) async throws -> String {
            try nextDocument().get()
        }

        func fetchRepoInfo(source: CatalogSource) async throws -> CatalogRepoMetadata {
            try nextRepoInfo().get()
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

        private func nextRepoInfo() -> Result<CatalogRepoMetadata, Error> {
            lock.lock()
            defer { lock.unlock() }
            repoInfoFetchCount += 1
            return repoInfo
        }
    }

    private func makeModel(fetcher: MockFetcher) -> AppModel {
        let suite = "CatalogAppModelTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let database = try! SkillStore.inMemory()
        let registry = BuiltInAgentRegistry.make()
        return AppModel(
            refresher: IndexRefresher(
                registry: registry,
                bookmarks: BookmarkStore(database: database, adapter: CatalogPathBookmarkAdapter()),
                index: SkillIndex(database: database)
            ),
            index: SkillIndex(database: database),
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

        XCTAssertEqual(model.catalog.state, .idle)
        await model.catalog.loadIfNeeded()
        XCTAssertEqual(
            model.catalog.state,
            .loaded(page(["pdf", "pptx"]).skills + [], truncated: false)
        )
        XCTAssertEqual(fetcher.skillFetchCount, CatalogRegistry.sources.count, "every declared source is fetched")

        // A repeat activation must not refetch — the loaded state is the cache.
        await model.catalog.loadIfNeeded()
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

        await model.catalog.refresh()
        guard case .loaded(let skills, truncated: false) = model.catalog.state else {
            return XCTFail("expected loaded, got \(model.catalog.state)")
        }
        XCTAssertEqual(skills.map(\.name), ["pdf", "brainstorming"], "declarative source order holds")
        XCTAssertEqual(fetcher.skillFetchCount, CatalogRegistry.sources.count)

        await model.catalog.refresh()
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
        await model.catalog.loadIfNeeded()
        XCTAssertEqual(model.catalog.state, .loaded(page(["pdf"]).skills, truncated: true))
    }

    func testPrefetchesRepoMetadataPerSource() async {
        let fetcher = MockFetcher(pages: [
            "anthropics/skills": .success(page(["pdf"])),
            "obra/superpowers": .success(page([])),
        ])
        let model = makeModel(fetcher: fetcher)

        await model.catalog.loadIfNeeded()
        XCTAssertEqual(
            fetcher.repoInfoFetchCount,
            CatalogRegistry.sources.count,
            "repo metadata is prefetched for every declared source"
        )
        XCTAssertEqual(
            model.catalog.repoInfoBySourceID["anthropics/skills"]?.stars,
            120
        )
        XCTAssertEqual(
            model.catalog.repoInfoBySourceID["anthropics/skills"]?.license,
            "MIT"
        )
    }

    func testRepoInfoFailureIsTolerated() async {
        // A failed repo-metadata prefetch must not fail the listing — the
        // source simply shows no「仓库信息」section.
        let fetcher = MockFetcher(
            pages: [
                "anthropics/skills": .success(page(["pdf"])),
                "obra/superpowers": .success(page([])),
            ],
            repoInfo: .failure(CatalogError.rateLimited)
        )
        let model = makeModel(fetcher: fetcher)

        await model.catalog.loadIfNeeded()
        guard case .loaded = model.catalog.state else {
            return XCTFail("a failing repo-metadata prefetch must not fail the load")
        }
        XCTAssertTrue(
            model.catalog.repoInfoBySourceID.isEmpty,
            "failed repo fetches leave no stale metadata behind"
        )
    }

    func testSingleFailingSourceIsTolerated() async {
        // Per-source tolerance: one broken source lands in the failed-ids
        // list while the rest of the listing loads normally.
        let fetcher = MockFetcher(pages: [
            "anthropics/skills": .success(page(["pdf"])),
            "obra/superpowers": .failure(CatalogError.rateLimited),
        ])
        let model = makeModel(fetcher: fetcher)

        await model.catalog.loadIfNeeded()
        guard case .loaded(let skills, _) = model.catalog.state else {
            return XCTFail("a single failing source must not fail the load")
        }
        XCTAssertEqual(skills.map(\.name), ["pdf"])
        XCTAssertEqual(model.catalog.failedSourceIDs, ["obra/superpowers"])
    }

    func testAllSourcesFailingMapsToFailure() async {
        var pages: [String: Result<CatalogPage, Error>] = [:]
        for source in CatalogRegistry.sources {
            pages[source.id] = .failure(CatalogError.rateLimited)
        }
        let model = makeModel(fetcher: MockFetcher(pages: pages))
        await model.catalog.loadIfNeeded()
        // Every source failed — that is a real load failure; the surfaced
        // reason comes from the first declared source's error.
        XCTAssertEqual(model.catalog.state, .failed(.rateLimited))
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

        await model.catalog.loadIfNeeded()
        XCTAssertEqual(
            model.catalog.descriptions["s:pdf"],
            "Read and create PDF files."
        )
        XCTAssertEqual(
            model.catalog.descriptions["s:pptx"],
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

        await model.catalog.loadIfNeeded()
        XCTAssertTrue(model.catalog.descriptions.isEmpty, "failed prefetch must not crash the listing")
        guard case .loaded = model.catalog.state else {
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
        let database = try! SkillStore.inMemory()
        let registry = BuiltInAgentRegistry.make()
        let model = AppModel(
            refresher: IndexRefresher(
                registry: registry,
                bookmarks: BookmarkStore(database: database, adapter: CatalogPathBookmarkAdapter()),
                index: SkillIndex(database: database)
            ),
            index: SkillIndex(database: database),
            registry: registry,
            defaults: defaults,
            catalogFetcher: fetcher,
            catalogSourceStore: UserDefaultsCatalogSourceStore(defaults: defaults)
        )

        XCTAssertEqual(model.catalog.sources.count, CatalogRegistry.sources.count)
        XCTAssertTrue(model.catalog.addSource(CustomCatalogSource(owner: "me", repo: "my-skills")))
        XCTAssertEqual(model.catalog.sources.count, CatalogRegistry.sources.count + 1)
        XCTAssertFalse(
            model.catalog.addSource(CustomCatalogSource(owner: "me", repo: "my-skills")),
            "duplicate ids are rejected"
        )

        await model.catalog.loadIfNeeded()
        guard case .loaded(let skills, _) = model.catalog.state else {
            return XCTFail("expected loaded")
        }
        XCTAssertTrue(skills.contains { $0.name == "mine" }, "the imported source is listed")

        // The import survives a fresh model (UserDefaults persistence).
        let reopened = AppModel(
            refresher: IndexRefresher(
                registry: registry,
                bookmarks: BookmarkStore(database: database, adapter: CatalogPathBookmarkAdapter()),
                index: SkillIndex(database: database)
            ),
            index: SkillIndex(database: database),
            registry: registry,
            defaults: defaults,
            catalogFetcher: fetcher,
            catalogSourceStore: UserDefaultsCatalogSourceStore(defaults: defaults)
        )
        XCTAssertTrue(reopened.catalog.sources.contains { $0.id == "me/my-skills" })

        reopened.catalog.removeSource(id: "me/my-skills")
        XCTAssertFalse(reopened.catalog.sources.contains { $0.id == "me/my-skills" })
        reopened.catalog.removeSource(id: "anthropics/skills")
        XCTAssertEqual(
            reopened.catalog.sources.count,
            CatalogRegistry.sources.count - 1,
            "removing a built-in source hides it from the marketplace"
        )
    }

    func testRemovesAndEditsBuiltInSources() {
        let fetcher = MockFetcher(pages: [:])
        let suite = "CatalogBuiltIn-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let database = try! SkillStore.inMemory()
        let registry = BuiltInAgentRegistry.make()
        let makeModel = { () -> AppModel in
            AppModel(
                refresher: IndexRefresher(
                    registry: registry,
                    bookmarks: BookmarkStore(database: database, adapter: CatalogPathBookmarkAdapter()),
                    index: SkillIndex(database: database)
                ),
                index: SkillIndex(database: database),
                registry: registry,
                defaults: defaults,
                catalogFetcher: fetcher,
                catalogSourceStore: UserDefaultsCatalogSourceStore(defaults: defaults)
            )
        }
        let model = makeModel()
        XCTAssertEqual(model.catalog.sources.count, CatalogRegistry.sources.count)

        // 删除内置来源：从列表移除并持久化为「隐藏」。
        model.catalog.removeSource(id: "anthropics/skills")
        XCTAssertFalse(model.catalog.sources.contains { $0.id == "anthropics/skills" })
        XCTAssertTrue(model.catalog.hiddenBuiltInSourceIDs.contains("anthropics/skills"))

        // 编辑内置来源：迁移为用户自定义覆盖（改分支），原内置条目隐藏。
        XCTAssertTrue(model.catalog.updateSource(
            CustomCatalogSource(owner: "obra", repo: "superpowers", branch: "dev"),
            originalID: "obra/superpowers"
        ))
        let migrated = model.catalog.sources.first { $0.id == "obra/superpowers" }
        XCTAssertEqual(migrated?.isCustom, true)
        XCTAssertEqual(migrated?.branch, "dev")
        XCTAssertTrue(model.catalog.hiddenBuiltInSourceIDs.contains("obra/superpowers"))

        // 冲突仍被拒绝（迁移后的自定义 id 与现存来源冲突）。
        XCTAssertFalse(model.catalog.updateSource(
            CustomCatalogSource(owner: "wshobson", repo: "agents"),
            originalID: "obra/superpowers"
        ))

        // 持久化：重开 model 后删除与编辑都保持生效。
        let reopened = makeModel()
        XCTAssertFalse(reopened.catalog.sources.contains { $0.id == "anthropics/skills" })
        XCTAssertEqual(reopened.catalog.sources.first { $0.id == "obra/superpowers" }?.branch, "dev")
    }

    func testRestoresAllBuiltInSources() {
        let fetcher = MockFetcher(pages: [:])
        let suite = "CatalogRestore-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let database = try! SkillStore.inMemory()
        let registry = BuiltInAgentRegistry.make()
        let makeModel = { () -> AppModel in
            AppModel(
                refresher: IndexRefresher(
                    registry: registry,
                    bookmarks: BookmarkStore(database: database, adapter: CatalogPathBookmarkAdapter()),
                    index: SkillIndex(database: database)
                ),
                index: SkillIndex(database: database),
                registry: registry,
                defaults: defaults,
                catalogFetcher: fetcher,
                catalogSourceStore: UserDefaultsCatalogSourceStore(defaults: defaults)
            )
        }
        let model = makeModel()
        // 一个真实导入 + 一个被删除的内置 + 一个被编辑（迁移）的内置。
        XCTAssertTrue(model.catalog.addSource(CustomCatalogSource(owner: "me", repo: "mine")))
        model.catalog.removeSource(id: "anthropics/skills")
        XCTAssertTrue(model.catalog.updateSource(
            CustomCatalogSource(owner: "obra", repo: "superpowers", branch: "dev"),
            originalID: "obra/superpowers"
        ))
        XCTAssertFalse(model.catalog.sources.contains { $0.id == "anthropics/skills" })

        model.catalog.restoreAllBuiltInSources()

        // 内置全部恢复（含被删除与被迁移的），真实导入保留。
        XCTAssertTrue(model.catalog.sources.contains { $0.id == "anthropics/skills" })
        XCTAssertTrue(model.catalog.sources.contains { $0.id == "obra/superpowers" && !$0.isCustom })
        XCTAssertTrue(model.catalog.sources.contains { $0.id == "me/mine" })
        XCTAssertEqual(model.catalog.sources.count, CatalogRegistry.sources.count + 1)
        XCTAssertTrue(model.catalog.hiddenBuiltInSourceIDs.isEmpty)

        // 持久化：重开 model 后保持恢复状态。
        let reopened = makeModel()
        XCTAssertTrue(reopened.catalog.sources.contains { $0.id == "anthropics/skills" })
        XCTAssertTrue(reopened.catalog.sources.contains { $0.id == "obra/superpowers" && !$0.isCustom })
        XCTAssertTrue(reopened.catalog.sources.contains { $0.id == "me/mine" })
    }

    /// 没有任何隐藏/迁移的内置来源时，恢复是无副作用的空操作：来源列表
    /// 与隐藏集合都不变，真实导入不受影响。
    func testRestoreIsNoOpWhenNothingHidden() {
        let fetcher = MockFetcher(pages: [:])
        let suite = "CatalogRestoreNoop-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let database = try! SkillStore.inMemory()
        let registry = BuiltInAgentRegistry.make()
        let model = AppModel(
            refresher: IndexRefresher(
                registry: registry,
                bookmarks: BookmarkStore(database: database, adapter: CatalogPathBookmarkAdapter()),
                index: SkillIndex(database: database)
            ),
            index: SkillIndex(database: database),
            registry: registry,
            defaults: defaults,
            catalogFetcher: fetcher,
            catalogSourceStore: UserDefaultsCatalogSourceStore(defaults: defaults)
        )
        XCTAssertTrue(model.catalog.addSource(CustomCatalogSource(owner: "me", repo: "mine")))
        let before = model.catalog.sources.count

        model.catalog.restoreAllBuiltInSources()

        XCTAssertEqual(model.catalog.sources.count, before)
        XCTAssertEqual(model.catalog.sources.count, CatalogRegistry.sources.count + 1)
        XCTAssertTrue(model.catalog.sources.contains { $0.id == "me/mine" })
        XCTAssertTrue(model.catalog.hiddenBuiltInSourceIDs.isEmpty)
    }

    /// 编辑内置来源并改成不同的 owner/repo（id 变化）后恢复：原内置回来，
    /// 而改 id 的条目作为用户新增来源保留（它的 id 不属于内置，不属于恢复
    /// 范围）。
    func testRestoreKeepsReidentifiedBuiltInEdit() {
        let fetcher = MockFetcher(pages: [:])
        let suite = "CatalogRestoreReid-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let database = try! SkillStore.inMemory()
        let registry = BuiltInAgentRegistry.make()
        let model = AppModel(
            refresher: IndexRefresher(
                registry: registry,
                bookmarks: BookmarkStore(database: database, adapter: CatalogPathBookmarkAdapter()),
                index: SkillIndex(database: database)
            ),
            index: SkillIndex(database: database),
            registry: registry,
            defaults: defaults,
            catalogFetcher: fetcher,
            catalogSourceStore: UserDefaultsCatalogSourceStore(defaults: defaults)
        )
        XCTAssertTrue(model.catalog.updateSource(
            CustomCatalogSource(owner: "me", repo: "reimported", branch: "dev"),
            originalID: "anthropics/skills"
        ))
        XCTAssertFalse(model.catalog.sources.contains { $0.id == "anthropics/skills" })
        XCTAssertTrue(model.catalog.sources.contains { $0.id == "me/reimported" })

        model.catalog.restoreAllBuiltInSources()

        XCTAssertTrue(model.catalog.sources.contains { $0.id == "anthropics/skills" })
        XCTAssertTrue(model.catalog.sources.contains { $0.id == "me/reimported" })
        XCTAssertEqual(model.catalog.sources.count, CatalogRegistry.sources.count + 1)
        XCTAssertTrue(model.catalog.hiddenBuiltInSourceIDs.isEmpty)
    }

    /// 「导入来源管理」：`updateSource` 支持改分支重导（身份不变仅 branch
    /// 变化）与改 owner/repo（身份变化、旧条目被替换）；不存在的原身份、
    /// 与内置/已有来源冲突的新身份被拒绝；更新持久化到 UserDefaults，
    /// 重开 model 后仍生效。
    func testUpdatesImportedSourceBranchAndIdentity() {
        let fetcher = MockFetcher(pages: [:])
        let suite = "CatalogUpdate-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let database = try! SkillStore.inMemory()
        let registry = BuiltInAgentRegistry.make()
        let makeModel = { () -> AppModel in
            AppModel(
                refresher: IndexRefresher(
                    registry: registry,
                    bookmarks: BookmarkStore(database: database, adapter: CatalogPathBookmarkAdapter()),
                    index: SkillIndex(database: database)
                ),
                index: SkillIndex(database: database),
                registry: registry,
                defaults: defaults,
                catalogFetcher: fetcher,
                catalogSourceStore: UserDefaultsCatalogSourceStore(defaults: defaults)
            )
        }
        let model = makeModel()
        XCTAssertTrue(model.catalog.addSource(CustomCatalogSource(owner: "me", repo: "repo")))
        XCTAssertEqual(model.catalog.sources.first { $0.id == "me/repo" }?.branch, "main")

        // 改分支重导：identity 不变，仅 branch 变化。
        XCTAssertTrue(model.catalog.updateSource(
            CustomCatalogSource(owner: "me", repo: "repo", branch: "dev"),
            originalID: "me/repo"
        ))
        XCTAssertEqual(model.catalog.sources.first { $0.id == "me/repo" }?.branch, "dev")

        // 改 owner/repo：identity 变化，旧条目被替换。
        XCTAssertTrue(model.catalog.updateSource(
            CustomCatalogSource(owner: "me", repo: "repo2"),
            originalID: "me/repo"
        ))
        XCTAssertNil(model.catalog.sources.first { $0.id == "me/repo" })
        XCTAssertNotNil(model.catalog.sources.first { $0.id == "me/repo2" })

        // 不存在的 originalID 被拒绝。
        XCTAssertFalse(model.catalog.updateSource(
            CustomCatalogSource(owner: "nope", repo: "nope"),
            originalID: "missing/id"
        ))

        // 更新到与内置源冲突的 identity 被拒绝。
        XCTAssertFalse(model.catalog.updateSource(
            CustomCatalogSource(owner: "anthropics", repo: "skills"),
            originalID: "me/repo2"
        ))

        // 更新持久化：重开 model 后仍可见。
        let reopened = makeModel()
        XCTAssertNotNil(reopened.catalog.sources.first { $0.id == "me/repo2" })
    }

    func testFailingImportedSourceDoesNotBreakTheLoad() async {
        let fetcher = MockFetcher(pages: [
            "anthropics/skills": .success(page(["pdf"])),
            "broken/source": .failure(CatalogError.http(status: 404)),
        ])
        let suite = "CatalogPartial-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let database = try! SkillStore.inMemory()
        let registry = BuiltInAgentRegistry.make()
        let model = AppModel(
            refresher: IndexRefresher(
                registry: registry,
                bookmarks: BookmarkStore(database: database, adapter: CatalogPathBookmarkAdapter()),
                index: SkillIndex(database: database)
            ),
            index: SkillIndex(database: database),
            registry: registry,
            defaults: defaults,
            catalogFetcher: fetcher,
            catalogSourceStore: UserDefaultsCatalogSourceStore(defaults: defaults)
        )
        model.catalog.addSource(CustomCatalogSource(owner: "broken", repo: "source"))

        await model.catalog.loadIfNeeded()
        guard case .loaded(let skills, _) = model.catalog.state else {
            return XCTFail("a single failing source must not fail the load")
        }
        XCTAssertEqual(skills.map(\.name), ["pdf"])
        XCTAssertEqual(model.catalog.failedSourceIDs, ["broken/source"])
    }

    func testMarketSearchMatching() {
        let skill = page(["pdf"]).skills[0]
        // Empty/whitespace queries match everything.
        XCTAssertTrue(CatalogListView.matches(skill, description: nil, query: ""))
        XCTAssertTrue(CatalogListView.matches(skill, description: nil, query: "  "))
        // Name match is case-insensitive.
        XCTAssertTrue(CatalogListView.matches(skill, description: nil, query: "PDF"))
        XCTAssertTrue(CatalogListView.matches(skill, description: "Read and create PDF files.", query: "create pdf"))
        // Description match only counts when the name doesn't.
        XCTAssertFalse(CatalogListView.matches(skill, description: nil, query: "spreadsheets"))
        XCTAssertTrue(CatalogListView.matches(
            page(["xlsx"]).skills[0],
            description: "Use this skill any time a spreadsheet file is the primary input.",
            query: "spreadsheet"
        ))
    }

    /// 搜索增强：市场列表结果中，名称命中的 Skill 排在仅简介命中的之前；
    /// 双方名称都未命中时保持稳定顺序（不重排）。
    func testSearchFloatsNameHitsFirst() {
        let pdf = page(["pdf"]).skills[0]
        let docs = page(["docs"]).skills[0]
        // pdf's name contains the query, docs' does not — the name hit
        // must sort ahead.
        XCTAssertTrue(CatalogListView.nameMatchComesFirst(lhs: pdf, rhs: docs, query: "pdf"))
        XCTAssertFalse(CatalogListView.nameMatchComesFirst(lhs: docs, rhs: pdf, query: "pdf"))
        // With neither name hitting, the declared order is kept (stable).
        XCTAssertFalse(CatalogListView.nameMatchComesFirst(lhs: pdf, rhs: docs, query: "spreadsheets"))
    }

    func testSearchMatchesNameAndDescriptionCaseInsensitively() {

        let skill = CatalogSkill(
            id: "s:pdf",
            sourceID: "anthropics/skills",
            name: "pdf",
            skillPath: "skills/pdf/SKILL.md",
            githubURL: URL(string: "https://github.com/anthropics/skills")!,
            rawURL: URL(string: "https://raw.githubusercontent.com/anthropics/skills/main/skills/pdf/SKILL.md")!
        )
        XCTAssertTrue(CatalogListView.matches(skill, description: nil, query: ""))
        XCTAssertTrue(CatalogListView.matches(skill, description: nil, query: "   "))
        XCTAssertTrue(
            CatalogListView.matches(skill, description: nil, query: "PDF"),
            "name match is case-insensitive"
        )
        XCTAssertTrue(
            CatalogListView.matches(skill, description: "Work with PDF files and forms.", query: "forms"),
            "description match counts too"
        )
        XCTAssertFalse(
            CatalogListView.matches(skill, description: "Work with PDF files and forms.", query: "spreadsheets"
            )
        )
    }

    func testDocumentFetchDelegatesToFetcher() async throws {
        let fetcher = MockFetcher(
            pages: [:],
            document: .success("---\nname: pdf\n---\n# PDF\n")
        )
        let model = makeModel(fetcher: fetcher)
        let skill = page(["pdf"]).skills[0]
        let body = try await model.catalog.loadDocument(skill)
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
