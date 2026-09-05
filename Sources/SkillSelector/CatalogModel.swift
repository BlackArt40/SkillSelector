import Combine
import Foundation
import SkillSelectorCore

/// Read-only marketplace catalog state, extracted from `AppModel`
/// (Brooks-Lint finding 2).
///
/// Product discipline (spec「市场目录只读」): the catalog is fetched on
/// demand when the user opens the section or hits refresh — never polled,
/// never persisted, no background work. Remote content is rendered
/// read-only; installation stays with the ecosystem's own tooling.
@MainActor
final class CatalogModel: ObservableObject {
    @Published var state: CatalogState = .idle
    /// Effective catalog sources: the built-in table (minus any the user
    /// hid) plus the user's imported ones (UserDefaults-persisted).
    @Published var sources: [CatalogSource] = CatalogRegistry.sources
    /// Built-in source ids the user removed from the marketplace. Persisted
    /// in UserDefaults; a hidden built-in can only return by clearing it.
    @Published private(set) var hiddenBuiltInSourceIDs: Set<String> = []
    /// Source ids whose last fetch failed while other sources loaded.
    @Published var failedSourceIDs: [String] = []
    /// Frontmatter descriptions keyed by skill id, prefetched in the
    /// background after a catalog load; rows fill them in progressively.
    /// Same memory-only discipline as the listing itself.
    @Published var descriptions: [String: String] = [:]
    /// Repository metadata keyed by source id, prefetched in the background
    /// with the listing; the detail page's「仓库信息」section reads it.
    @Published var repoInfoBySourceID: [String: CatalogRepoMetadata] = [:]

    /// Catalog network boundary; injected for tests, immutable after init.
    let fetcher: any CatalogFetching
    /// Persistence for user-imported sources; immutable after init.
    let sourceStore: any CatalogSourceStoring
    /// Persistence for the hidden built-in source ids.
    private let defaults: UserDefaults
    /// In-flight catalog load; guards duplicate concurrent loads.
    var loadTask: Task<Void, Never>?
    /// In-flight description prefetch; cancelled by the next load.
    var descriptionTask: Task<Void, Never>?
    /// In-flight repo-metadata prefetch; cancelled by the next load.
    var repoInfoTask: Task<Void, Never>?

    init(
        fetcher: any CatalogFetching,
        sourceStore: any CatalogSourceStoring,
        defaults: UserDefaults = .standard
    ) {
        self.fetcher = fetcher
        self.sourceStore = sourceStore
        self.defaults = defaults
        hiddenBuiltInSourceIDs = Set(
            defaults.stringArray(forKey: Self.hiddenBuiltInSourcesKey) ?? []
        )
        sources = Self.effectiveSources(
            builtIn: CatalogRegistry.sources,
            hiddenBuiltIn: hiddenBuiltInSourceIDs,
            custom: sourceStore.loadCustomSources().map(\.source)
        )
    }

    /// The effective source list: built-ins (minus hidden ones) followed by
    /// imported sources in insertion order.
    private static func effectiveSources(
        builtIn: [CatalogSource],
        hiddenBuiltIn: Set<String>,
        custom: [CatalogSource]
    ) -> [CatalogSource] {
        builtIn.filter { !hiddenBuiltIn.contains($0.id) } + custom
    }

    /// Rebuilds `sources` from the persisted state after a removal or edit.
    private func reloadSources() {
        sources = Self.effectiveSources(
            builtIn: CatalogRegistry.sources,
            hiddenBuiltIn: hiddenBuiltInSourceIDs,
            custom: sourceStore.loadCustomSources().map(\.source)
        )
    }

    private func persistHiddenBuiltInSources() {
        defaults.set(
            hiddenBuiltInSourceIDs.sorted(),
            forKey: Self.hiddenBuiltInSourcesKey
        )
    }

    private static let hiddenBuiltInSourcesKey = "SkillSelector.hiddenBuiltInCatalogSources"

    /// Loads the catalog on demand: no-op unless still idle, so switching
    /// to the section repeatedly doesn't refetch (memory cache is the
    /// loaded state itself).
    func loadIfNeeded() async {
        guard case .idle = state else { return }
        await refresh()
    }

    /// Forces a refetch of every declared source. A complete refresh
    /// covers the description prefetch too — the listing itself lands
    /// first (`.loaded`), rows fill descriptions progressively after.
    func refresh() async {
        if let running = loadTask {
            await running.value
        } else {
            let task = Task { [weak self] in
                guard let self else { return }
                await self.performLoad()
            }
            loadTask = task
            await task.value
            loadTask = nil
        }
        await descriptionTask?.value
        await repoInfoTask?.value
    }

    /// Fetches a skill's SKILL.md for the detail view. On-demand, capped
    /// by the fetcher; the content is held by the view, not the model.
    func loadDocument(_ skill: CatalogSkill) async throws -> String {
        try await fetcher.fetchDocument(skill)
    }

    private func performLoad() async {
        state = .loading
        descriptionTask?.cancel()
        repoInfoTask?.cancel()
        descriptions = [:]
        repoInfoBySourceID = [:]
        failedSourceIDs = []
        var pages: [String: CatalogPage] = [:]
        var failures: [String: Error] = [:]
        // Per-source tolerance: one bad imported repo must not take
        // down the whole listing — failures land in failedSourceIDs
        // and the load continues.
        await withTaskGroup(of: (CatalogSource, Result<CatalogPage, Error>).self) { group in
            for source in sources {
                group.addTask { [fetcher] in
                    do {
                        return (source, .success(try await fetcher.fetchSkills(source: source)))
                    } catch {
                        return (source, .failure(error))
                    }
                }
            }
            for await (source, result) in group {
                switch result {
                case .success(let page):
                    pages[source.id] = page
                case .failure(let error):
                    failures[source.id] = error
                }
            }
        }
        // Source order stays declarative; each page is already sorted.
        let skills = sources.flatMap { pages[$0.id]?.skills ?? [] }
        let truncated = sources.contains { pages[$0.id]?.truncated == true }
        if !failures.isEmpty, failures.count == sources.count {
            // Every source failed — that is a load failure, not a
            // partial one. Surface the most actionable error.
            let ordered = sources.compactMap { failures[$0.id] }.first
            state = .failed(Self.failure(for: ordered ?? CatalogError.invalidResponse))
            return
        }
        state = .loaded(skills, truncated: truncated)
        failedSourceIDs = sources.filter { failures[$0.id] != nil }.map(\.id)
        startDescriptionPrefetch(for: skills)
        startRepoInfoPrefetch()
    }

    /// Imports a user marketplace source. Returns false when a source
    /// with the same owner/repo already exists (built-in or imported).
    @discardableResult
    func addSource(_ custom: CustomCatalogSource) -> Bool {
        let source = custom.source
        guard !sources.contains(where: { $0.id == source.id }) else { return false }
        var stored = sourceStore.loadCustomSources()
        stored.append(custom)
        sourceStore.saveCustomSources(stored)
        sources.append(source)
        return true
    }

    /// Removes a source from the marketplace. Imported sources are deleted
    /// from the store; built-in sources are hidden (persisted) so they stop
    /// appearing but the code-declared table stays intact.
    func removeSource(id: String) {
        guard let source = sources.first(where: { $0.id == id }) else { return }
        if source.isCustom {
            var stored = sourceStore.loadCustomSources()
            stored.removeAll { "\($0.owner)/\($0.repo)" == id }
            sourceStore.saveCustomSources(stored)
            sources.removeAll { $0.id == id }
        } else {
            hiddenBuiltInSourceIDs.insert(id)
            persistHiddenBuiltInSources()
            sources.removeAll { $0.id == id }
        }
    }

    /// Updates a source in place (e.g. re-importing on a different branch).
    /// `originalID` is the current "owner/repo" identity. Editing a built-in
    /// source migrates it to a user-managed entry (persisted like an
    /// imported one) while hiding the original built-in, so the edit sticks
    /// across restarts. Returns false when the original is missing or the
    /// new identity collides with another source. The caller decides
    /// whether to refresh.
    @discardableResult
    func updateSource(_ custom: CustomCatalogSource, originalID: String) -> Bool {
        let newID = "\(custom.owner)/\(custom.repo)"
        guard !sources.contains(where: { $0.id == newID && $0.id != originalID }) else {
            return false
        }
        let isBuiltIn = CatalogRegistry.sources.contains { $0.id == originalID }
        if isBuiltIn {
            // 内置来源被编辑：迁移为用户自定义覆盖，并隐藏原内置条目。
            var stored = sourceStore.loadCustomSources()
            stored.removeAll { "\($0.owner)/\($0.repo)" == originalID }
            stored.append(custom)
            sourceStore.saveCustomSources(stored)
            hiddenBuiltInSourceIDs.insert(originalID)
            persistHiddenBuiltInSources()
            reloadSources()
            return true
        }
        var stored = sourceStore.loadCustomSources()
        guard let index = stored.firstIndex(where: { "\($0.owner)/\($0.repo)" == originalID }) else {
            return false
        }
        stored[index] = custom
        sourceStore.saveCustomSources(stored)
        reloadSources()
        return true
    }

    /// Restores every built-in source the user removed or edited: clears the
    /// hidden set and drops the user-managed overrides that carry a built-in
    /// id (added by editing a built-in), leaving only genuine imports.
    func restoreAllBuiltInSources() {
        let builtInIDs = Set(CatalogRegistry.sources.map(\.id))
        var stored = sourceStore.loadCustomSources()
        stored.removeAll { builtInIDs.contains("\($0.owner)/\($0.repo)") }
        sourceStore.saveCustomSources(stored)
        hiddenBuiltInSourceIDs = []
        persistHiddenBuiltInSources()
        reloadSources()
    }

    /// Fetches every listed skill's SKILL.md and keeps its frontmatter
    /// description — rows fill in progressively. Raw GitHub downloads are
    /// CDN-served (outside the API rate limit), results are memory-only,
    /// and the whole pass is cancelled by the next load. Writes are
    /// batched: with hundreds of skills, per-item observable writes would
    /// re-render the browser for every single row.
    private func startDescriptionPrefetch(for skills: [CatalogSkill]) {
        guard !skills.isEmpty else { return }
        let fetcher = fetcher
        descriptionTask = Task { [weak self] in
            await withTaskGroup(of: (String, String?).self) { group in
                for skill in skills {
                    group.addTask {
                        guard let document = try? await fetcher.fetchDocument(skill) else {
                            return (skill.id, nil)
                        }
                        return (skill.id, FrontmatterParser.parse(document).description)
                    }
                }
                var pending: [String: String] = [:]
                for await (id, description) in group {
                    guard let self, !Task.isCancelled, let description, !description.isEmpty else {
                        continue
                    }
                    pending[id] = description
                    if pending.count >= 40 {
                        self.descriptions.merge(pending) { _, new in new }
                        pending.removeAll()
                    }
                }
                if let self, !Task.isCancelled, !pending.isEmpty {
                    self.descriptions.merge(pending) { _, new in new }
                }
            }
        }
    }

    private static func failure(for error: Error) -> CatalogLoadFailure {
        switch error as? CatalogError {
        case .rateLimited:
            return .rateLimited
        case .http(let status):
            return .http(status: status)
        case .invalidResponse, .oversized:
            return .invalidResponse
        case nil:
            return .network
        }
    }

    /// Fetches repository metadata for every source in the background —
    /// one small `/repos/{owner}/{repo}` call per source. Failures are
    /// tolerated: a source without metadata simply shows no「仓库信息」
    /// section. Results are memory-only, like the listing.
    private func startRepoInfoPrefetch() {
        let fetcher = fetcher
        let sources = sources
        repoInfoTask = Task { [weak self] in
            await withTaskGroup(of: (String, CatalogRepoMetadata?).self) { group in
                for source in sources {
                    group.addTask {
                        let info = try? await fetcher.fetchRepoInfo(source: source)
                        return (source.id, info)
                    }
                }
                for await (id, info) in group {
                    guard let self, !Task.isCancelled, let info else { continue }
                    self.repoInfoBySourceID[id] = info
                }
            }
        }
    }
}

/// Catalog fetch lifecycle. `loaded` doubles as the memory cache — there
/// is no second copy of the listing anywhere, and app restart resets it.
enum CatalogState: Equatable {
    case idle
    case loading
    case loaded([CatalogSkill], truncated: Bool)
    case failed(CatalogLoadFailure)
}

/// Failure reasons, kept UI-agnostic so views localize them.
enum CatalogLoadFailure: Equatable {
    case network
    case rateLimited
    case invalidResponse
    case http(status: Int)
}