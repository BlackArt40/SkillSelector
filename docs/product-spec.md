# SkillSelector Product Specification

Status: Confirmed on 2026-07-17. Updated 2026-07-19 (features removed).

## Product boundary

SkillSelector is a small native macOS viewer and file manager for local Agent Skills. It discovers, explains, filters, copies, moves, safely deletes, links, and updates Skills that already exist locally. It is not an Agent runner, Skill marketplace, installer, recommendation system, code editor, or AI summarizer.

## Platform and distribution

- Native SwiftUI application using only Apple system frameworks.
- Minimum deployment target: macOS 14 Sonoma.
- Universal 2 release for Apple Silicon and Intel.
- SwiftData stores local index records and settings; full Skill content is not copied into the index.
- Simplified Chinese and English localizations follow the system language.
- GitHub Releases hosts an ad-hoc signed `.dmg` with App Sandbox enabled.
- No Developer ID, notarization, telemetry, analytics SDK, or remote crash reporter.
- Apache License 2.0.

## Permission model

On first environment check, the user authorizes their home directory through a macOS directory panel. SkillSelector persists a security-scoped bookmark and accesses only standard global paths listed in its bundled Agent registry. It never recursively scans unrelated home-directory content.

Project folders are added and authorized individually. Registered project-level path patterns are found recursively inside each project, while `.git`, dependency directories, build output, and caches are skipped. System-level Skill roots outside the home directory require a separate authorization. Structural writes are restricted to authorized and registered Skill roots.

## Agent registry

The first release includes Claude Code, Codex, Qoder, CodeBuddy, OpenCode, Cursor, Kilo Code, Cline, Roo Code, Windsurf, Gemini CLI, and GitHub Copilot. Roo Code is legacy compatibility and only appears when detected or manually enabled.

The bundled registry declares names, standard global roots, project-relative patterns, entry filenames, and source capabilities. It changes only with an app release. Users can define custom Agent types with a name, global roots, project patterns, and an entry filename that defaults to `SKILL.md`. The app does not parse Agent-specific custom path settings in the first release; users add those directories manually.

## Discovery and identity

Every directory containing a recognized `SKILL.md` is parsed best-effort and remains visible even when its frontmatter is invalid. Invalid records show diagnostics instead of silently disappearing.

An absolute installation path identifies a Skill record. Agent filters represent the canonical owner of the containing Agent-specific directory, not every tool that can consume it. Shared `.agents/skills` content has no Agent association: home-level shared content appears under Global Skills, while project-level shared content appears only under that project. Copies at different paths remain separate records. Symbolic links remain separate installations and record their resolved target.

After home authorization, every launch quickly checks only bundled allowlisted global roots and refreshes the local index. Project scans run for authorized projects. The app has no continuous filesystem watcher. Manual refresh and app-initiated file operations refresh affected roots. If a root becomes inaccessible, its records remain with an unavailable status; a record is removed only when its parent root is accessible and the Skill is confirmed absent.

## Main experience

The main window is a native three-column Skill browser:

- Sidebar: all Skills, global Skills, individual projects, and Agent filters.
- List: one row per installation path with search, status filters, and sorting.
- Detail: effective description and Markdown rendering, Agent associations, scope, path, and file operations.

`SKILL.md` is read-only in the app. Users can reveal it in Finder or open it in the default editor. Both the description and Skill document sections render Markdown formatting (headers, bold, lists, code, links, tables).

The effective description priority is user customization, local `SKILL.md` description, ~~trusted remote metadata~~, then a deterministic local fallback. All available sources remain visible, and the user can remove a customization to restore the default.

## ~~Trusted metadata enrichment~~

~~Enrichment is offline by default and user-triggered for one or more existing Skills. An optional setting may enrich missing descriptions after index refresh, but it defaults off. Only minimal identifying information is sent; local project paths, scripts, reference files, and full content are excluded.~~

~~No model is configured or called. Providers extract source text without rewriting it:~~

1. ~~Remote `SKILL.md` description.~~
2. ~~Official manifest or npm package description.~~
3. ~~README first descriptive paragraph.~~

~~`gh` performs all GitHub search, metadata, download, and update requests. Authentication remains in the user's `gh` installation. SkillSelector never reads or stores a GitHub token. GitHub-wide search is limited to matching existing local Skills, and every candidate source requires user confirmation.~~

~~npm is limited to Registry read operations equivalent to `npm search --json` and `npm view --json`. The app never invokes install, exec, package scripts, or an npm lifecycle.~~

~~The app may discover MCP configurations from supported Agents but never starts or invokes a Server until the user enables it and selects a read-only tool. It supports stdio and Streamable HTTP, not legacy HTTP+SSE. Package-runner commands such as `npx` or `uvx` are disabled until the user separately approves the exact executable and arguments; any configuration change invalidates that approval. Unknown or write-capable tools are not invoked automatically.~~

~~The app does not install `gh`, npm, MCP Servers, or any supporting package. It detects common executable locations and lets the user bind an executable when needed. External commands are launched directly with argument arrays, never through a shell command string.~~

## Sources and updates

An update source can come from explicit Skill metadata, a containing Git repository and relative path, a source previously recorded by SkillSelector, or a user-confirmed candidate. Search similarity by itself is insufficient.

GitHub operations use `gh`. Non-GitHub public sources are supported only when they provide a clear directly downloadable Skill package. Private repository authentication is out of scope for the first release.

The tracked unit is one Skill directory, even when its repository contains many Skills. Update availability is based on a normalized content digest for that directory; an available version string is displayed but is not required. Branch sources track changes, while tag and commit sources remain pinned.

Before updating, the app downloads into a temporary directory, validates `SKILL.md`, computes a file change summary, and asks for confirmation. Local changes since the previous index digest trigger an additional warning. On approval, the old directory moves to Trash and the replacement is installed atomically. App-owned custom descriptions survive because they live in the index.

Updating a symbolic link updates its resolved target only after showing that target and every affected link. The target must be authorized. Deleting a symbolic link removes only the link.

## File operations

Copy, move, delete, and create-symbolic-link actions always disclose source and destination before confirmation. Destinations must be authorized registered Skill roots; users add new roots through a directory panel rather than entering arbitrary paths.

Name conflicts never merge or silently overwrite directories. The user can keep both under a non-conflicting name, replace after a second confirmation while moving the old target to Trash, or cancel. All deletion uses macOS Trash.

## Diagnostics and safety

The app stores no remote credentials except security-scoped bookmark data needed for authorized paths. Local unified logs redact home paths, command environment variables, and remote response bodies. A user-initiated diagnostic export is also redacted.

~~External process output is bounded, parsed as structured data where available, and treated as untrusted input. Remote archives are checked for path traversal and symbolic-link escapes before installation. No downloaded content is executed by update or enrichment flows.~~

## Delivery milestones

1. App shell, authorization, registry, scanning, and SwiftData index.
2. Three-column browser, Markdown reading, custom descriptions, and localization.
3. Safe file operations and symbolic-link behavior.
4. ~~`gh`, npm, and MCP enrichment plus source binding.~~
5. Atomic Skill updates, packaging, diagnostics, and release documentation.
