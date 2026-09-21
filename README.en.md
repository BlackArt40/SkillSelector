[![English](https://img.shields.io/badge/English-blue)](README.en.md)
[![简体中文](https://img.shields.io/badge/简体中文-blue)](README.md)

<div align="center">

# SkillSelector

**A native macOS dashboard for Agent Skills — browse, search, inspect. Strictly read-only.**

[![CI](https://github.com/BlackArt40/SkillSelector/actions/workflows/ci.yml/badge.svg)](https://github.com/BlackArt40/SkillSelector/actions/workflows/ci.yml)
![Platform](https://img.shields.io/badge/platform-macOS%2012%2B-black)
![Arch](https://img.shields.io/badge/arch-Universal%202-blue)
[![Release](https://img.shields.io/github/v/release/BlackArt40/SkillSelector)](https://github.com/BlackArt40/SkillSelector/releases)
[![License](https://img.shields.io/badge/license-Apache%202.0-green)](LICENSE)

![Main window (English)](screenshots/main-en.png)

</div>

SkillSelector gathers the Agent Skills installed across your coding agents (Claude Code, Codex, Cursor, …) into one local dashboard: browse them together, search across agents, inspect duplicates and symlinks, verify MCP configurations, and window-shop the skill market. It is **not an installer** — there is no AI inside, no telemetry, and it never touches your skill files; copying, moving and deleting belong to Finder.

## ✨ Features

### Browse & search

- **Three-pane browser** — a sidebar grouped by scope and Agent, a searchable, sortable skill list, and a detail pane showing the selected skill's description, frontmatter, rendered Markdown, associated agents and install locations; the middle column's edge is draggable to resize
- **Fielded search** — a plain term matches the name, description, or indexed body; `name:`, `desc:`, `path:`, `agent:`, `body:` prefixes search one field only (e.g. `agent:cursor path:.agents`). The duplicates, MCP, rules and links pages each carry an in-column search bar
- **Navigation history** — ⌘[ / ⌘] or the Go menu steps back and forward, ⌘F focuses the search field; sidebar switches, detail openings and each search session record one history step
- **Light / dark** — one click in the top bar, or follow the system
- **Localization** — English and Simplified Chinese, following the system language; agent rows show brand icons with initial-letter badges as a fallback

### Duplicates · links · rules

- **Duplicate skills** — identical copies scattered across agents are grouped by a content fingerprint of the SKILL.md body; whole groups can be marked ignored (persists across relaunches)
- **Near duplicates & comparison** — MinHash similarity fingerprints surface near-duplicate groups; compare two copies side by side across frontmatter, body, and subfile diffs
- **Symbolic links** — every link installation (source → target) is listed, and broken targets are highlighted
- **Rules files** — the agents' instruction files: `CLAUDE.md`, `AGENTS.md`, `.cursorrules`, plus directory sources like `.cursor/rules`, `.claude/rules`, `.roo/rules` and the `GEMINI.md` hierarchy; details render Markdown, still read-only

### MCP probing

- Detects the MCP servers in agent configs: Codex's TOML, the JSON of Cursor / Claude and friends, and project `.mcp.json`
- "Probe" performs a real MCP initialize handshake — stdio servers are launched, checked alive, then reaped; http/sse receives an initialize request. Read-only, on demand, never resident

### Skill market

- Fetches 7 vetted GitHub repositories on demand (Anthropic official plus community collections such as Superpowers and Vercel, ≈680 skills), grouped by repo, filterable by source, each skill with a description and docs
- "Import market" adds custom repositories (`owner/repo` or a link)
- Browse-only: open on GitHub, copy the link, or copy the `npx skills add …` command and let the ecosystem CLI install

### Diagnostics

- The health report is viewable in-app (same redaction as export) or exportable as JSON
- Each refresh's change history (what was added / modified / removed) stays local for later review

### Import & authorization

- No forced authorization: browse the empty state on first launch; later launches auto-scan. Add just a project folder — an import scans only that directory and the skill list appears immediately, without waiting on a full scan
- "System directories" stay resident in the sidebar once imported (a + at the row end imports in one click); All Skills, Global Skills, Duplicates, Symbolic Links and Agents are always visible
- Roots with broken authorization surface in a top banner and in "needs re-authorization", one click to re-authorize

## 📸 Screenshots

| Duplicates | MCP probing |
| --- | --- |
| ![Duplicates (English)](screenshots/duplicates-en.png) | ![MCP probing (English)](screenshots/mcp-en.png) |

| Rules files | Market |
| --- | --- |
| ![Rules files (English)](screenshots/rules-en.png) | ![Market (English)](screenshots/catalog-en.png) |

| Agent editor | Settings |
| --- | --- |
| ![Agent editor (English)](screenshots/agent-editor-en.png) | ![Settings (English)](screenshots/settings-en.png) |

**Diagnostics viewer**

![Diagnostics viewer (English)](screenshots/diagnostics-en.png)

## 🤖 Supported agents

The app ships 19 built in: Claude Code, Codex, Qoder, CodeBuddy, OpenCode, Cursor, Kilo Code, Cline, Roo Code, Windsurf, Gemini CLI, GitHub Copilot, Amp, Tabnine, Letta, OpenHands, Goose, Kiro, Factory Droid.

- **Roo Code** is legacy-compat: hidden until existing skills are detected or it is enabled in Settings
- Any local skill directory can be registered as a **custom agent**

## 🔐 Privacy

- Local features run fully offline: no telemetry, no crash reporting, no file watchers, no bundled models
- The only outbound traffic is the market's on-demand fetch of its declared GitHub sources — requested only when you open that section or hit refresh; no polling, nothing persisted
- Description translation is an optional cloud feature: configure your own API key (stored encrypted on this machine) and requests go only to the provider you chose; without a key nothing is ever sent, and no key ships with the app
- The index stores metadata only (paths, owning agent, summaries, …) — never skill content
- Directory access goes through App Sandbox security-scoped bookmarks, and scanning is limited to the registry's declared paths

## 📦 Install

Requires macOS 12 Monterey or newer, Universal 2 (Apple Silicon and Intel).

1. Download the `.dmg` and its matching `.sha256` from [GitHub Releases](https://github.com/BlackArt40/SkillSelector/releases). The universal build suits every Mac; you can also pick the smaller single-arch one — `-arm64` for Apple Silicon, `-x86_64` for Intel
2. Verify the checksum (keep both files in one directory):

   ```zsh
   shasum -a 256 -c SkillSelector-1.03.dmg.sha256
   ```

   It must print `SkillSelector-1.03.dmg: OK`. If not, don't install it.

3. Mount the `.dmg` and drag `SkillSelector.app` into Applications
4. Right-click the app → Open → confirm

> [!NOTE]
> Gatekeeper blocks un-notarized apps — that is expected. If "Open" is missing from the context menu, go to System Settings → Privacy & Security and click "Open Anyway" next to SkillSelector.

> [!WARNING]
> The first launch after upgrading from the old 2.x line starts fresh: the index rebuilds automatically, directories need re-authorization, and duplicate-ignore marks reset.

Description translation is an optional cloud feature: configure your own API key in Settings; without one the app never sends a translation request.

## 🛠 Build from source

```zsh
git clone https://github.com/BlackArt40/SkillSelector.git
cd SkillSelector
swift build
zsh Scripts/package-dmg.sh 1.03
```

Outputs `dist/SkillSelector.app` (Universal 2) plus `dist/SkillSelector-arm64.app` and `dist/SkillSelector-x86_64.app`, three DMGs (`SkillSelector.dmg`, `SkillSelector-1.03.dmg`, and the two single-arch ones), and matching `.sha256` files.

- Tests: `swift test`; CI runs them on every PR and push. On macOS 12 Intel hosts use `zsh Scripts/local-build.sh`
- The only third-party dependencies are Yams (frontmatter parsing), GRDB (local index), and MarkdownUI (Markdown rendering)

## 🗂 Project structure

```
Sources/SkillSelectorCore/     Logic library: domain, scanners, persistence, permissions, registry, diagnostics
Sources/SkillSelector/         SwiftUI app: three-pane browser, settings, design tokens
Tests/SkillSelectorCoreTests/  XCTest (includes docs-drift and L10n parity guards)
Scripts/                       Packaging scripts (app & DMG)
Packaging/                     Sandbox entitlements
```

## 🤝 Contributing

Issues and PRs are welcome. Commit messages follow Conventional Commits; new user-facing strings must land in both the English and Simplified Chinese resource files (identical key sets).

## 📄 License

Apache 2.0. See [LICENSE](LICENSE).
