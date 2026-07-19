# AGENTS.md

## Project identity

SkillSelector is a native macOS 14 SwiftUI app that discovers, views, manages, and updates local Agent Skills. It is NOT an Agent runner, marketplace, installer, recommendation system, code editor, or AI summarizer.

## Tech stack

- Swift 6.3, SwiftUI, SwiftData, Foundation, AppKit, Security, OSLog
- Apple system frameworks only — no third-party Swift packages
- macOS 14 Sonoma minimum deployment target
- Universal 2 build (Apple Silicon + Intel)
- Ad-hoc signed with App Sandbox, no Developer ID or notarization
- Apache License 2.0

## Build and test commands

```bash
swift build                        # build everything
swift test                         # run all tests
swift test --filter SmokeTests     # run a single test class
swift test --filter AgentRegistryTests  # example: targeted test
```

The MVP plan in `docs/superpowers/plans/2026-07-17-skillselector-mvp.md` defines the full scaffold including `Package.swift`, domain types, scanner, persistence, browser, operations, and packaging.

## Architecture

Two targets in a single Swift Package:
- `SkillSelector` — SwiftUI app (executable target)
- `SkillSelectorCore` — domain logic library (importable by tests and app)

Source layout follows the MVP plan's `Sources/SkillSelectorCore/` (Domain, Registry, Scanning, Persistence, Permissions, Operations, Commands, Documents, Updates, Diagnostics) and `Sources/SkillSelector/` (Browser, Resources, Settings).

Key modules:
- `AppModel` — main observable model (760 lines)
- `DocumentManager` — document loading, Finder reveal, default editor
- `MarkdownRenderer` — Markdown to AttributedString rendering
- `SkillFileOperator` — safe file operations with authorization
- `SkillUpdater` — atomic Skill updates
- `URLContainment` — `URL.isContained(in:)` utility extension

## Key constraints

- **Skill identity is path-based**: one record per absolute installation path; path is the unique ID. Copies at different paths are separate records.
- **No shell command strings**: external processes use `executableURL` + `arguments` array directly.
- **All deletion uses macOS Trash**, never permanent delete.
- **No telemetry, no AI model, no marketplace, no package installer, no code editor, no continuous file watcher.**
- **No third-party packages** — Apple system frameworks only.
- **Localized** in Simplified Chinese and English; path strings and Agent names stay untranslated.
- **`SKILL.md` is read-only in the app** — users reveal in Finder or open in default editor.
- **No private repository authentication** in the first release.

## Product spec and ADRs

- Product spec: `docs/product-spec.md`
- ADRs: `docs/adr/` (5 active decisions, 4 superseded)
- Agent skill directory research: `docs/research/agent-skill-support.md`

## .gitignore rules

The following directories are excluded from git (Agent state, planning, worktrees):
- `.agents/`, `.claude/`, `.codex/`, `.opencode/`, `.qoder/`, `.codebuddy/`, `.skills/`
- `.worktrees/`, `需求.md`

## CONTEXT.md terminology

`CONTEXT.md` defines precise terms for this project. Respect the "Avoid" lists — e.g., say "Skill" not "plugin" or "extension"; say "Skill viewer" not "marketplace" or "runner".

## Commit convention

Follow conventional commits: `feat:`, `fix:`, `build:`, `test:`, `docs:`.
