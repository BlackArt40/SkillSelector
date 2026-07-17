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
    private let bookmarks: BookmarkStore?

    var refreshState: RefreshState = .idle
    var selection: SkillSelection?

    init(refresher: IndexRefresher, bookmarks: BookmarkStore? = nil) {
        self.refresher = refresher
        self.bookmarks = bookmarks
    }

    func checkEnvironment() async {
        refreshState = .running
        do {
            refreshState = .finished(try await refresher.refresh(.startup))
        } catch {
            refreshState = .failed(String(describing: error))
        }
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
            refreshState = .failed("Authorization storage is unavailable")
            return
        }
        do {
            _ = try bookmarks.save(url: url, kind: kind)
            await checkEnvironment()
        } catch {
            refreshState = .failed(String(describing: error))
        }
    }
}
