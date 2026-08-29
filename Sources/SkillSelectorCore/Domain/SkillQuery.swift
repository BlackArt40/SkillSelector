import Foundation

public struct SkillQuery: Hashable, Sendable {
    public enum Scope: Hashable, Sendable {
        case all
        case global
        case project(rootID: String)
        case root(rootID: String)
    }

    public enum Sort: Hashable, Sendable {
        case `default`
        case name
        case path
    }

    public var scope: Scope
    public var agentID: String?
    public var searchText: String
    public var sort: Sort

    public init(
        scope: Scope = .all,
        agentID: String? = nil,
        searchText: String = "",
        sort: Sort = .default
    ) {
        self.scope = scope
        self.agentID = agentID
        self.searchText = searchText
        self.sort = sort
    }

    public func apply(
        to snapshots: [SkillSnapshot],
        rootsByID: [String: AuthorizedRootSnapshot],
        agentNamesByID: [String: String] = [:],
        bodyTextsByPath: [String: String] = [:]
    ) -> [SkillSnapshot] {
        var snapshotsByPath: [String: SkillSnapshot] = [:]
        for snapshot in snapshots where snapshotsByPath[snapshot.path] == nil {
            snapshotsByPath[snapshot.path] = snapshot
        }

        let terms = Self.parseSearchTerms(searchText)
        return snapshotsByPath.values
            .filter { matchesScope($0, rootsByID: rootsByID) }
            .filter { matchesAgent($0) }
            .filter {
                matchesSearch(
                    $0,
                    terms: terms,
                    agentNamesByID: agentNamesByID,
                    bodyTextsByPath: bodyTextsByPath
                )
            }
            .sorted(by: comesBefore)
    }

    /// One whitespace-separated search token. Free terms fuzzy-match the
    /// Skill **name or body** (substring, case/diacritic-insensitive);
    /// prefixed terms (`name:`, `desc:`, `path:`, `agent:`, `body:`)
    /// restrict the match to a single field. Body text comes from the
    /// caller's in-memory index (keyed by installation path, pre-folded);
    /// a Skill without indexed body text simply falls back to name
    /// matching.
    struct SearchTerm: Hashable, Sendable {
        enum Field: String {
            case name
            case description = "desc"
            case path
            case agent
            case body
        }

        let field: Field?
        let term: String
    }

    /// Splits the raw text into terms; an unrecognized or empty prefix
    /// degrades that token to a free term instead of being ignored.
    static func parseSearchTerms(_ raw: String) -> [SearchTerm] {
        raw.split(whereSeparator: { $0.isWhitespace })
            .map { token in
                let token = String(token)
                guard let colon = token.firstIndex(of: ":"), colon != token.startIndex else {
                    return SearchTerm(field: nil, term: token)
                }
                let prefix = String(token[..<colon]).lowercased()
                let value = String(token[token.index(after: colon)...])
                guard let field = SearchTerm.Field(rawValue: prefix), !value.isEmpty else {
                    return SearchTerm(field: nil, term: token)
                }
                return SearchTerm(field: field, term: value)
            }
            .filter { !$0.term.isEmpty }
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

    private func matchesSearch(
        _ snapshot: SkillSnapshot,
        terms: [SearchTerm],
        agentNamesByID: [String: String],
        bodyTextsByPath: [String: String]
    ) -> Bool {
        guard !terms.isEmpty else { return true }
        return terms.allSatisfy { term in
            let key = Self.searchKey(term.term)
            switch term.field {
            case nil:
                // Free terms match the name or (when indexed) the body.
                if Self.searchKey(snapshot.name).contains(key) { return true }
                guard let body = bodyTextsByPath[snapshot.path] else { return false }
                return body.contains(key)
            case .name:
                return Self.searchKey(snapshot.name).contains(key)
            case .description:
                return Self.searchKey(Self.effectiveDescription(for: snapshot)).contains(key)
            case .path:
                return Self.searchKey(snapshot.path).contains(key)
            case .agent:
                let names = snapshot.agentIDs.map { agentNamesByID[$0] ?? $0 }
                return names.contains { Self.searchKey($0).contains(key) }
            case .body:
                guard let body = bodyTextsByPath[snapshot.path] else { return false }
                return body.contains(key)
            }
        }
    }

    private func comesBefore(_ lhs: SkillSnapshot, _ rhs: SkillSnapshot) -> Bool {
        switch sort {
        case .path:
            return lhs.path < rhs.path
        case .name, .default:
            let lhsName = Self.searchKey(lhs.name)
            let rhsName = Self.searchKey(rhs.name)
            return lhsName == rhsName ? lhs.path < rhs.path : lhsName < rhsName
        }
    }

    private static func searchKey(_ value: String) -> String {
        foldedSearchKey(value)
    }

    /// Shared folding for search keys — the app layer pre-folds body
    /// texts with the same rule so query-time matching is a plain
    /// substring test.
    public static func foldedSearchKey(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }
}
