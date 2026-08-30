import Foundation

/// Back/forward navigation history for the browser's detail pane. Owned
/// exclusively by `AppModel` — views go through the model's forwarding
/// accessors and never touch the stacks directly.
struct NavigationHistory {
    private(set) var backEntries: [NavigationEntry] = []
    private(set) var forwardEntries: [NavigationEntry] = []

    /// Soft cap on the back stack: the stack bottom (the launch default
    /// seed) is preserved while older entries above it are dropped, so a
    /// very long session cannot grow history without bound.
    static let maximumBackEntries = 200

    var canGoBack: Bool { !backEntries.isEmpty }
    var canGoForward: Bool { !forwardEntries.isEmpty }

    /// Records a navigation action. Re-recording a search session replaces
    /// the in-flight search entry instead of pushing a second one, so
    /// intermediate search-word changes never grow the stack. Any forward
    /// history is cleared, per macOS convention.
    mutating func record(_ entry: NavigationEntry) {
        if case .search(let query) = entry,
           case .search = backEntries.last {
            backEntries[backEntries.count - 1] = .search(query)
            return
        }
        backEntries.append(entry)
        forwardEntries = []
        if backEntries.count > Self.maximumBackEntries {
            // Keep the stack bottom (the launch default seed) and drop the
            // oldest entry above it.
            backEntries.remove(at: 1)
        }
    }

    /// Pops the current state onto the forward stack and returns the state
    /// to restore. The stack bottom is the launch default destination
    /// (seeded by the root view); at the bottom, nil is returned and the
    /// caller restores the default view (AC-16).
    mutating func goBack() -> NavigationEntry? {
        guard backEntries.count >= 2 else { return nil }
        guard let current = backEntries.popLast() else { return nil }
        forwardEntries.append(current)
        return backEntries.last
    }

    /// Pops the forward stack back onto the back stack and returns the
    /// state to restore.
    mutating func goForward() -> NavigationEntry? {
        guard let entry = forwardEntries.popLast() else { return nil }
        backEntries.append(entry)
        return entry
    }

    /// Ends an in-flight search session (clicking a result or dismissing the
    /// field): the search entry is removed so back returns directly to the
    /// pre-search state — the whole session counts as one step (AC-15).
    mutating func endSearchIfNeeded() {
        if case .search = backEntries.last {
            _ = backEntries.popLast()
        }
    }
}
