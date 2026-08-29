import Foundation

/// One remote marketplace source the catalog browses. Declarative and
/// code-embedded — same philosophy as `McpRegistry` and `RulesRegistry`:
/// known sources shipped with the app, discovered at review time, never
/// probed heuristically and never added at runtime.
public struct CatalogSource: Hashable, Sendable, Identifiable {
    /// "owner/repo" — also the stable identity.
    public let id: String
    /// Display name for the list UI.
    public let displayName: String
    public let owner: String
    public let repo: String
    public let branch: String

    public init(id: String, displayName: String, owner: String, repo: String, branch: String) {
        self.id = id
        self.displayName = displayName
        self.owner = owner
        self.repo = repo
        self.branch = branch
    }
}

/// Fixed, code-embedded table of the marketplace sources the read-only
/// catalog browses. Read-only discipline: the app lists and renders these
/// remote skills — installation stays with the ecosystem's own tooling
/// (CLI / Finder), never in-app.
public enum CatalogRegistry {
    public static let sources: [CatalogSource] = [
        CatalogSource(
            id: "anthropics/skills",
            displayName: "Anthropic Skills",
            owner: "anthropics",
            repo: "skills",
            branch: "main"
        ),
        CatalogSource(
            id: "obra/superpowers",
            displayName: "Superpowers",
            owner: "obra",
            repo: "superpowers",
            branch: "main"
        ),
    ]
}

/// A skill discovered in a catalog source's repository. Pure metadata —
/// the SKILL.md content is only fetched on demand when the user opens the
/// detail view.
public struct CatalogSkill: Identifiable, Hashable, Sendable {
    /// "sourceId:skillPath" — stable within a source's tree.
    public let id: String
    public let sourceID: String
    /// Directory name holding the SKILL.md ("pdf").
    public let name: String
    /// Repo-relative path of the SKILL.md ("skills/pdf/SKILL.md").
    public let skillPath: String
    /// The skill's GitHub page (browser handoff).
    public let githubURL: URL
    /// Raw SKILL.md URL (document fetch).
    public let rawURL: URL

    /// Install command for the ecosystem's own CLI (vercel-labs/skills,
    /// syntax verified against its docs: `npx skills add <owner/repo>
    /// --skill <name>`). The app copies this string; it never runs it.
    public var installCommand: String {
        "npx skills add \(sourceID) --skill \(name)"
    }

    public init(
        id: String,
        sourceID: String,
        name: String,
        skillPath: String,
        githubURL: URL,
        rawURL: URL
    ) {
        self.id = id
        self.sourceID = sourceID
        self.name = name
        self.skillPath = skillPath
        self.githubURL = githubURL
        self.rawURL = rawURL
    }
}

/// One source's listing result. `truncated` mirrors GitHub's flag: a huge
/// tree may be incomplete, and the UI must say so instead of implying the
/// list is exhaustive.
public struct CatalogPage: Hashable, Sendable {
    public let skills: [CatalogSkill]
    public let truncated: Bool

    public init(skills: [CatalogSkill], truncated: Bool) {
        self.skills = skills
        self.truncated = truncated
    }
}

public enum CatalogError: Error, Equatable {
    /// Non-200 response other than rate limiting.
    case http(status: Int)
    /// 403/429 — GitHub's anonymous rate limit or an abuse rejection.
    case rateLimited
    /// Response could not be decoded as the expected shape.
    case invalidResponse
    /// The document exceeds the read-size cap and is not shown.
    case oversized
}

/// The catalog network boundary — injected into the app model so tests
/// drive the state machine without touching the network.
public protocol CatalogFetching: Sendable {
    func fetchSkills(source: CatalogSource) async throws -> CatalogPage
    func fetchDocument(_ skill: CatalogSkill) async throws -> String
}
