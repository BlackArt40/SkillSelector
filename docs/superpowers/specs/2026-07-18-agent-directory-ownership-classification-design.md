# Agent Directory Ownership Classification Design

## Goal

Classify each indexed Skill by the Agent-specific directory that physically owns it. An Agent's ability to read another Agent's directory is compatibility information and must not create an Agent association in SkillSelector.

## Classification Semantics

Agent filters represent directory ownership, not runtime compatibility:

- `~/.codex/skills` and project `.codex/skills` belong only to Codex.
- `~/.claude/skills` and project `.claude/skills` belong only to Claude Code.
- A Skill in one owned directory has only that directory owner's Agent association, even when other tools can consume the directory.
- Shared `.agents` directories have no Agent association.
- A custom Agent owns the roots and project patterns that the user explicitly declares only when they do not overlap a bundled owned or shared declaration.
- Bundled ownership declarations take precedence over custom overlap; shared `.agents` declarations remain ownerless.

The absolute installation path remains the Skill identity. Multiple physical copies in different Agent directories remain separate records.

## Bundled Ownership Map

| Agent | Owned global roots | Owned project patterns |
| --- | --- | --- |
| Claude Code | `~/.claude/skills` | `.claude/skills` |
| Codex | `~/.codex/skills` | `.codex/skills` |
| Qoder | `~/.qoder/skills` | `.qoder/skills` |
| CodeBuddy | `~/.codebuddy/skills` | `.codebuddy/skills` |
| OpenCode | `~/.config/opencode/skills`, `~/.opencode/skills` | `.opencode/skills` |
| Cursor | `~/.cursor/skills` | `.cursor/skills` |
| Kilo Code | `~/.kilo/skills` | `.kilo/skills` |
| Cline | `~/.cline/skills` | `.cline/skills`, `.clinerules/skills` |
| Roo Code | `~/.roo/skills`, `~/.roo/skills-{modeSlug}` | `.roo/skills`, `.roo/skills-{modeSlug}` |
| Windsurf | `~/.codeium/windsurf/skills`, `/Library/Application Support/Windsurf/skills` | `.windsurf/skills` |
| Gemini CLI | `~/.gemini/skills` | `.gemini/skills` |
| GitHub Copilot | `~/.copilot/skills` | `.github/skills` |

The following are shared declarations, not an Agent definition:

- Global: `~/.agents/skills`, `~/.agents/skills-{modeSlug}`
- Project: `.agents/skills`, `.agents/skills-{modeSlug}`

Compatibility paths remain documented in research but are removed from Agent ownership declarations.

## Registry Model

`AgentRegistry` will hold two kinds of declarations:

1. Agent-owned roots and patterns from `AgentDefinition`.
2. Shared global roots and project patterns with an entry filename but no Agent ID.

The registry exposes normalized scan declarations so scanning and file-operation validation use the same source of truth. A declaration yields its path or pattern, entry filename, and zero or one owning Agent ID. Shared declarations always yield no owner, including when a custom definition overlaps a bundled shared path.

## Discovery And Indexing

Home discovery expands both owned and shared global declarations. Project discovery matches both owned and shared project patterns.

- Owned match: the scanned installation receives exactly the canonical owner ID for that declaration.
- Shared match: the installation receives an empty Agent ID set.
- Multiple compatibility claims do not accumulate IDs.
- If multiple declarations for the same physical path and entry filename match, the bundled canonical declaration takes precedence. This prevents a custom overlap from recreating an incorrect multi-Agent category.

Refreshing an accessible root replaces its previous associations with the newly scanned ownership result. This removes legacy compatibility-derived Agent IDs from existing SwiftData records without a destructive database migration. Unavailable roots retain their previous records until they can be scanned again, preserving the existing availability policy.

## Sidebar And Rows

The existing sidebar detection rule remains: an Agent appears only when at least one indexed Skill record contains that Agent's canonical owner ID.

- A missing Agent directory does not show the Agent.
- An existing but empty Agent directory does not show the Agent.
- A directory containing a recognized entry file produces a record and shows its Agent even when frontmatter parsing reports diagnostics.
- Shared `.agents` records never cause an Agent to appear.
- Shared global records appear under Global Skills because their authorized root is the home root.
- Shared project records appear only under their corresponding project scope.

Skill rows and details show only the canonical owner association. Shared records show no Agent label.

## File Operations

Shared roots and patterns remain registered destinations for copy, move, and link operations. A destination under `.agents/skills` produces no Agent association while retaining its home-global or project scope. Agent-owned destinations produce only their canonical owner ID.

Authorization, confirmation, conflict, Trash, rollback, and refresh behavior remain unchanged. Registry fingerprints include shared declarations so a plan expires when shared-root configuration changes.

## Custom Agents

Custom Agent definitions continue to own explicitly declared paths that are not already claimed by the bundled registry. Their persistent UUID-backed ID remains unchanged. Built-in owned paths retain their canonical owner, and shared `.agents` paths remain ownerless when a custom declaration overlaps either kind.

## Product Documentation

The product specification will distinguish directory ownership from tool compatibility. The research document remains the factual record of directories each tool can consume; those compatibility entries no longer imply SkillSelector sidebar membership.

## Verification

- Registry tests assert the exact owned map and shared declarations.
- Home refresh tests cover `.codex`, `.claude`, and shared `.agents` records and prove their Agent ID sets are respectively Codex-only, Claude-only, and empty.
- Project scan tests prove the same behavior for project patterns, including shared mode-specific `.agents` paths.
- Sidebar/query tests prove missing, empty, and shared-only directories do not show Agent categories, while a recognized diagnostic record does.
- Index reconciliation tests prove a successful refresh removes legacy compatibility-derived Agent IDs.
- File-operation tests prove shared destinations remain legal and produce no Agent IDs.
- Full test, build, and packaged application smoke verification remain required.

## Out Of Scope

- Changing which directories an Agent can consume at runtime.
- Parsing Agent-specific custom compatibility settings.
- Merging duplicate physical Skill installations across different paths.
- Changing the previously approved Skill-list control alignment design; that implementation plan remains separate and pending.
