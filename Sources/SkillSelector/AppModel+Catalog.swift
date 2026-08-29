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
        do {
            var pages: [String: CatalogPage] = [:]
            try await withThrowingTaskGroup(of: (String, CatalogPage).self) { group in
                for source in CatalogRegistry.sources {
                    group.addTask { [catalogFetcher] in
                        (source.id, try await catalogFetcher.fetchSkills(source: source))
                    }
                }
                for try await (sourceID, page) in group {
                    pages[sourceID] = page
                }
            }
            // Source order stays declarative; each page is already sorted.
            let skills = CatalogRegistry.sources.flatMap { pages[$0.id]?.skills ?? [] }
            let truncated = CatalogRegistry.sources.contains { pages[$0.id]?.truncated == true }
            catalogState = .loaded(skills, truncated: truncated)
            startDescriptionPrefetch(for: skills)
        } catch {
            catalogState = .failed(Self.catalogFailure(for: error))
        }
    }

    /// Fetches every listed skill's SKILL.md and keeps its frontmatter
    /// description — rows fill in progressively. Raw GitHub downloads are
    /// CDN-served (outside the API rate limit), results are memory-only,
    /// and the whole pass is cancelled by the next load.
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
                for await (id, description) in group {
                    guard let self, !Task.isCancelled, let description, !description.isEmpty else {
                        continue
                    }
                    self.catalogDescriptions[id] = description
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
