import Foundation

/// One recorded refresh that changed something: the paths that were
/// added, changed, and removed, with the moment the refresh ran. Empty
/// refreshes are not recorded — the history answers "what moved", not
/// "when did nothing happen".
public struct RefreshChangeEntry: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let date: Date
    public let addedPaths: [String]
    public let changedPaths: [String]
    public let removedPaths: [String]

    public init(
        id: UUID = UUID(),
        date: Date = Date(),
        addedPaths: [String],
        changedPaths: [String],
        removedPaths: [String]
    ) {
        self.id = id
        self.date = date
        self.addedPaths = addedPaths
        self.changedPaths = changedPaths
        self.removedPaths = removedPaths
    }

    public init(summary: RefreshSummary, date: Date = Date()) {
        self.init(
            id: UUID(),
            date: date,
            addedPaths: summary.addedPaths,
            changedPaths: summary.changedPaths,
            removedPaths: summary.removedPaths
        )
    }
}

public protocol RefreshHistoryStoring: Sendable {
    func entries() throws -> [RefreshChangeEntry]
    func record(_ entry: RefreshChangeEntry) throws
    func removeAll() throws
}

/// UserDefaults-backed history: the refresh log is small (capped), derived
/// diagnostic-style data rather than index state, so it deliberately stays
/// out of the SwiftData schema.
public final class UserDefaultsRefreshHistoryStore: RefreshHistoryStoring, @unchecked Sendable {
    public static let maximumEntries = 20
    private static let key = "SkillSelector.refreshHistory"

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func entries() throws -> [RefreshChangeEntry] {
        guard let data = defaults.data(forKey: Self.key) else { return [] }
        return (try? decoder.decode([RefreshChangeEntry].self, from: data)) ?? []
    }

    public func record(_ entry: RefreshChangeEntry) throws {
        var current = try entries()
        // Newest first.
        current.insert(entry, at: 0)
        if current.count > Self.maximumEntries {
            current = Array(current.prefix(Self.maximumEntries))
        }
        defaults.set(try encoder.encode(current), forKey: Self.key)
    }

    public func removeAll() throws {
        defaults.removeObject(forKey: Self.key)
    }
}
