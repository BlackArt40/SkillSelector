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
@Observable
final class CatalogModel {
    var state: CatalogState = .idle
    /// Effective catalog sources: the built-in table plus the user's
    /// imported ones (UserDefaults-persisted).
    var sources: [CatalogSource] = CatalogRegistry.sources
    /// Source ids whose last fetch failed while other sources loaded.
    var failedSourceIDs: [String] = []
    /// Frontmatter descriptions keyed by skill id, prefetched in the
    /// background after a catalog load; rows fill them in progressively.
    /// Same memory-only discipline as the listing itself.
    var descriptions: [String: String] = [:]

    /// Catalog network boundary; injected for tests, immutable after init.
    @ObservationIgnored let fetcher: any CatalogFetching
    /// Persistence for user-imported sources; immutable after init.
    @ObservationIgnored let sourceStore: any CatalogSourceStoring
    /// In-flight catalog load; guards duplicate concurrent loads.
    @ObservationIgnored var loadTask: Task<Void, Never>?
    /// In-flight description prefetch; cancelled by the next load.
    @ObservationIgnored var descriptionTask: Task<Void, Never>?

    init(fetcher: any CatalogFetching, sourceStore: any CatalogSourceStoring) {
        self.fetcher = fetcher
        self.sourceStore = sourceStore
        sources = CatalogRegistry.sources + sourceStore.loadCustomSources().map(\.source)
    }

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
    }

    /// Fetches a skill's SKILL.md for the detail view. On-demand, capped
    /// by the fetcher; the content is held by the view, not the model.
    func loadDocument(_ skill: CatalogSkill) async throws -> String {
        try await fetcher.fetchDocument(skill)
    }

    private func performLoad() async {
        state = .loading
        descriptionTask?.cancel()
        descriptions = [:]
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

    /// Removes a previously imported source; built-in sources are
    /// ignored (they cannot be removed).
    func removeSource(id: String) {
        guard let source = sources.first(where: { $0.id == id }), source.isCustom else {
            return
        }
        var stored = sourceStore.loadCustomSources()
        stored.removeAll { "\($0.owner)/\($0.repo)" == id }
        sourceStore.saveCustomSources(stored)
        sources.removeAll { $0.id == id }
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