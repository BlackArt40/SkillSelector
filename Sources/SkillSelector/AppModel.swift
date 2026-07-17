import Foundation
import Observation
import SkillSelectorCore

enum RefreshState: Hashable {
    case idle
    case running
    case finished(RefreshSummary)
    case failed(String)
}

struct SkillSelection: Hashable, Identifiable {
    let path: String
    var id: String { path }
}

@MainActor
@Observable
final class AppModel {
    private let refresher: IndexRefresher
    private let index: SkillIndex
    private let bookmarks: BookmarkStore?
    @ObservationIgnored private var activeRefresh: (id: UUID, task: Task<Void, Never>)?

    var refreshState: RefreshState = .idle
    var selection: SkillSelection?
    private(set) var snapshots: [SkillSnapshot] = []
    private(set) var authorizedRoots: [AuthorizedRootSnapshot] = []
    private(set) var rootsByID: [String: AuthorizedRootSnapshot] = [:]
    let agentDefinitions: [AgentDefinition]

    init(
        refresher: IndexRefresher,
        index: SkillIndex,
        bookmarks: BookmarkStore? = nil,
        registry: AgentRegistry
    ) {
        self.refresher = refresher
        self.index = index
        self.bookmarks = bookmarks
        agentDefinitions = registry.definitions
        do {
            try reloadSnapshot()
        } catch {
            refreshState = .failed(String(describing: error))
        }
    }

    func checkEnvironment() async {
        await refresh(.startup)
    }

    func checkEnvironmentOnLaunch() async {
        do {
            guard try bookmarks?.roots().isEmpty == false else { return }
            await checkEnvironment()
        } catch {
            refreshState = .failed(String(describing: error))
        }
    }

    func authorize(_ url: URL, as kind: AuthorizedRootKind) async {
        guard let bookmarks else {
            refreshState = .failed(L10n.string("Authorization storage is unavailable"))
            return
        }
        await waitForActiveRefresh()
        do {
            _ = try bookmarks.save(url: url, kind: kind)
            authorizedRoots = try bookmarks.roots()
            rootsByID = Dictionary(uniqueKeysWithValues: authorizedRoots.map { ($0.id, $0) })
            await refresh(.manual)
        } catch {
            refreshState = .failed(String(describing: error))
        }
    }

    func refresh(_ trigger: RefreshTrigger) async {
        if let activeRefresh {
            await activeRefresh.task.value
            clearRefresh(id: activeRefresh.id)
            return
        }

        let id = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performRefresh(trigger)
        }
        activeRefresh = (id, task)
        await task.value
        clearRefresh(id: id)
    }

    var hasAuthorization: Bool {
        !authorizedRoots.isEmpty
    }

    private func performRefresh(_ trigger: RefreshTrigger) async {
        refreshState = .running
        do {
            let summary = try await refresher.refresh(trigger)
            try reloadSnapshot()
            refreshState = .finished(summary)
        } catch {
            refreshState = .failed(String(describing: error))
        }
    }

    private func waitForActiveRefresh() async {
        guard let activeRefresh else { return }
        await activeRefresh.task.value
        clearRefresh(id: activeRefresh.id)
    }

    private func clearRefresh(id: UUID) {
        guard activeRefresh?.id == id else { return }
        activeRefresh = nil
    }

    private func reloadSnapshot() throws {
        let updatedSnapshots = try index.skills()
        let updatedRoots = try bookmarks?.roots() ?? []
        snapshots = updatedSnapshots
        authorizedRoots = updatedRoots
        rootsByID = Dictionary(uniqueKeysWithValues: updatedRoots.map { ($0.id, $0) })
        if let selection,
           !updatedSnapshots.contains(where: { $0.path == selection.path }) {
            self.selection = nil
        }
    }
}
