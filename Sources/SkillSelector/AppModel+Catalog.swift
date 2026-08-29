import Foundation
import SkillSelectorCore

/// Read-only marketplace catalog support in the app model.
///
/// Product discipline (spec「市场目录只读」): the catalog is fetched on
/// demand when the user opens the section or hits refresh — never polled,
/// never persisted, no background work. Remote content is rendered
/// read-only; installation stays with the ecosystem's own tooling.
extension AppModel {
    /// Loads the catalog on demand: no-op unless still idle, so switching
    /// to the section repeatedly doesn't refetch (memory cache is the
    /// loaded state itself).
    func loadCatalogIfNeeded() async {
        guard case .idle = catalogState else { return }
        await refreshCatalog()
    }

    /// Forces a refetch of every declared source. A complete refresh
    /// covers the description prefetch too — the listing itself lands
    /// first (`.loaded`), rows fill descriptions progressively after.
    func refreshCatalog() async {
        if let running = catalogLoadTask {
            await running.value
        } else {
            let task = Task { [weak self] in
                guard let self else { return }
                await self.performCatalogLoad()
            }
            catalogLoadTask = task
            await task.value
            catalogLoadTask = nil
        }
        await catalogDescriptionTask?.value
    }

    /// Fetches a skill's SKILL.md for the detail view. On-demand, capped
    /// by the fetcher; the content is held by the view, not the model.
    func loadCatalogDocument(_ skill: CatalogSkill) async throws -> String {
        try await catalogFetcher.fetchDocument(skill)
    }

    private func performCatalogLoad() async {
        catalogState = .loading
        catalogDescriptionTask?.cancel()
        catalogDescriptions = [:]
        catalogFailedSourceIDs = []
        do {
            var pages: [String: CatalogPage] = [:]
            var failures: [String: Error] = [:]
            // Per-source tolerance: one bad imported repo must not take
            // down the whole listing — failures land in
            // catalogFailedSourceIDs and the load continues.
            await withTaskGroup(of: (CatalogSource, Result<CatalogPage, Error>).self) { group in
                for source in catalogSources {
                    group.addTask { [catalogFetcher] in
                        do {
                            return (source, .success(try await catalogFetcher.fetchSkills(source: source)))
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
            let skills = catalogSources.flatMap { pages[$0.id]?.skills ?? [] }
            let truncated = catalogSources.contains { pages[$0.id]?.truncated == true }
            if !failures.isEmpty, failures.count == catalogSources.count {
                // Every source failed — that is a load failure, not a
                // partial one. Surface the most actionable error.
                let ordered = catalogSources.compactMap { failures[$0.id] }.first
                catalogState = .failed(Self.catalogFailure(for: ordered ?? CatalogError.invalidResponse))
                return
            }
            catalogState = .loaded(skills, truncated: truncated)
            catalogFailedSourceIDs = catalogSources.filter { failures[$0.id] != nil }.map(\.id)
            startDescriptionPrefetch(for: skills)
        } catch {
            catalogState = .failed(Self.catalogFailure(for: error))
        }
    }

    /// Imports a user marketplace source. Returns false when a source
    /// with the same owner/repo already exists (built-in or imported).
    @discardableResult
    func addCatalogSource(_ custom: CustomCatalogSource) -> Bool {
        let source = custom.source
        guard !catalogSources.contains(where: { $0.id == source.id }) else { return false }
        var stored = catalogSourceStore.loadCustomSources()
        stored.append(custom)
        catalogSourceStore.saveCustomSources(stored)
        catalogSources.append(source)
        return true
    }

    /// Removes a previously imported source; built-in sources are
    /// ignored (they cannot be removed).
    func removeCatalogSource(id: String) {
        guard let source = catalogSources.first(where: { $0.id == id }), source.isCustom else {
            return
        }
        var stored = catalogSourceStore.loadCustomSources()
        stored.removeAll { "\($0.owner)/\($0.repo)" == id }
        catalogSourceStore.saveCustomSources(stored)
        catalogSources.removeAll { $0.id == id }
    }

    /// Fetches every listed skill's SKILL.md and keeps its frontmatter
    /// description — rows fill in progressively. Raw GitHub downloads are
    /// CDN-served (outside the API rate limit), results are memory-only,
    /// and the whole pass is cancelled by the next load. Writes are
    /// batched: with hundreds of skills, per-item observable writes would
    /// re-render the browser for every single row.
    private func startDescriptionPrefetch(for skills: [CatalogSkill]) {
        guard !skills.isEmpty else { return }
        let fetcher = catalogFetcher
        catalogDescriptionTask = Task { [weak self] in
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
                        self.catalogDescriptions.merge(pending) { _, new in new }
                        pending.removeAll()
                    }
                }
                if let self, !Task.isCancelled, !pending.isEmpty {
                    self.catalogDescriptions.merge(pending) { _, new in new }
                }
            }
        }
    }

    private static func catalogFailure(for error: Error) -> CatalogLoadFailure {
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
