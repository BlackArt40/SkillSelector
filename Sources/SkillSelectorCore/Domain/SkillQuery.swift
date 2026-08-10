import Foundation

public struct SkillQuery: Hashable, Sendable {
    public enum Scope: Hashable, Sendable {
        case all
        case global
        case project(rootID: String)
        case root(rootID: String)
    }

    public enum Status: Hashable, Sendable {
        case all
        case available
        case unavailable
    }

    public enum Sort: Hashable, Sendable {
        case `default`
        case name
        case path
    }

    public var scope: Scope
    public var agentID: String?
    public var searchText: String
    public var status: Status
    public var sort: Sort

    public init(
        scope: Scope = .all,
        agentID: String? = nil,
        searchText: String = "",
        status: Status = .all,
        sort: Sort = .default
    ) {
        self.scope = scope
        self.agentID = agentID
        self.searchText = searchText
        self.status = status
        self.sort = sort
    }

    public func apply(
        to snapshots: [SkillSnapshot],
        rootsByID: [String: AuthorizedRootSnapshot]
    ) -> [SkillSnapshot] {
        var snapshotsByPath: [String: SkillSnapshot] = [:]
        for snapshot in snapshots where snapshotsByPath[snapshot.path] == nil {
            snapshotsByPath[snapshot.path] = snapshot
        }

        let searchTerm = Self.searchKey(
            searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        return snapshotsByPath.values
            .filter { matchesScope($0, rootsByID: rootsByID) }
            .filter { matchesAgent($0) }
            .filter { matchesStatus($0) }
            .filter { matchesSearch($0, term: searchTerm) }
            .sorted(by: comesBefore)
    }

    public static func effectiveDescription(for snapshot: SkillSnapshot) -> String {
        DescriptionResolver.resolve(DescriptionCandidates(snapshot: snapshot))
    }

    private func matchesScope(
        _ snapshot: SkillSnapshot,
        rootsByID: [String: AuthorizedRootSnapshot]
    ) -> Bool {
        switch scope {
        case .all:
            true
        case .global:
            snapshot.agentIDs.isEmpty && snapshot.rootIDs.contains { rootID in
                guard let kind = rootsByID[rootID]?.kind else { return false }
                return kind == .home || kind == .system || kind == .custom
            }
        case .project(let rootID):
            rootsByID[rootID]?.kind == .project && snapshot.rootIDs.contains(rootID)
        case .root(let rootID):
            snapshot.rootIDs.contains(rootID)
        }
    }

    private func matchesAgent(_ snapshot: SkillSnapshot) -> Bool {
        guard let agentID else { return true }
        return snapshot.agentIDs.contains(agentID)
    }

    private func matchesStatus(_ snapshot: SkillSnapshot) -> Bool {
        switch status {
        case .all:
            true
        case .available:
            snapshot.availability == .available
        case .unavailable:
            snapshot.availability == .unavailable
        }
    }

    private func matchesSearch(_ snapshot: SkillSnapshot, term: String) -> Bool {
        guard !term.isEmpty else { return true }
        return Self.searchKey(snapshot.name).contains(term)
            || Self.searchKey(Self.effectiveDescription(for: snapshot)).contains(term)
    }

    private func comesBefore(_ lhs: SkillSnapshot, _ rhs: SkillSnapshot) -> Bool {
        switch sort {
        case .path:
            return lhs.path < rhs.path
        case .name:
            let lhsName = Self.searchKey(lhs.name)
            let rhsName = Self.searchKey(rhs.name)
            return lhsName == rhsName ? lhs.path < rhs.path : lhsName < rhsName
        case .default:
            if lhs.availability != rhs.availability {
                return lhs.availability == .available
            }
            let lhsName = Self.searchKey(lhs.name)
            let rhsName = Self.searchKey(rhs.name)
            return lhsName == rhsName ? lhs.path < rhs.path : lhsName < rhsName
        }
    }

    private static func searchKey(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }
}
