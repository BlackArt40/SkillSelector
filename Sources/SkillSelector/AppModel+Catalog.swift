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

    /// Forces a refetch of every declared source.
    func refreshCatalog() async {
        if let running = catalogLoadTask {
            await running.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performCatalogLoad()
        }
        catalogLoadTask = task
        await task.value
        catalogLoadTask = nil
    }

    /// Fetches a skill's SKILL.md for the detail view. On-demand, capped
    /// by the fetcher; the content is held by the view, not the model.
    func loadCatalogDocument(_ skill: CatalogSkill) async throws -> String {
        try await catalogFetcher.fetchDocument(skill)
    }

    private func performCatalogLoad() async {
        catalogState = .loading
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
        } catch {
            catalogState = .failed(Self.catalogFailure(for: error))
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
