import Foundation
import SkillSelectorCore

/// One step of the fine-grained navigation history. View layers record
/// actions through `AppModel`; they never mutate the stacks directly.
enum NavigationEntry: Hashable {
    /// A sidebar view switch (global, duplicates, links, project, system,
    /// agent filter).
    case sidebar(BrowserDestination)
    /// Opening a Skill's detail pane.
    case skillDetail(SkillSelection)
    /// A search session. The entry is pushed when search starts and its
    /// query is rewritten in place while the user types — intermediate
    /// search-word changes never grow the stack.
    case search(String)

    /// The destination this entry restores when navigating back to it, if
    /// it is a sidebar view.
    var sidebarDestination: BrowserDestination? {
        if case .sidebar(let destination) = self {
            return destination
        }
        return nil
    }

    /// The selection this entry restores, if it is a detail view.
    var skillSelection: SkillSelection? {
        if case .skillDetail(let selection) = self {
            return selection
        }
        return nil
    }

    /// The query this entry restores, if it is a search session.
    var searchQuery: String? {
        if case .search(let query) = self {
            return query
        }
        return nil
    }
}
