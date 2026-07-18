# SkillSelector

SkillSelector is a native macOS viewer and file manager for Agent Skills that already exist on your machine. It discovers, explains, filters, copies, moves, safely deletes, links, and updates local Skills. It is not an Agent runner, Skill marketplace, installer, recommendation system, code editor, or AI summarizer.

## Requirements

- macOS 14 Sonoma or later.
- Apple Silicon and Intel Macs are both supported by the Universal 2 release.
- The app is available in English and Simplified Chinese.

## Supported Agents

The first release recognizes twelve Agents: Claude Code, Codex, Qoder, CodeBuddy, OpenCode, Cursor, Kilo Code, Cline, Roo Code, Windsurf, Gemini CLI, and GitHub Copilot. Roo Code is retained for legacy compatibility and appears only when detected or manually enabled. Custom Agent definitions can point at additional local Skill directories.

## Privacy and Safety

The core application works offline. It stores local index records and security-scoped bookmarks, not copies of full Skill content. It has no telemetry, analytics SDK, remote crash reporter, bundled model, or API configuration.

GitHub queries use your local `gh` command. npm access is read-only. MCP Servers and package-runner commands are never started automatically; an exact command or read-only tool needs explicit approval. File operations are limited to authorized, registered Skill roots, and deletion uses macOS Trash.

## Build and Test

```zsh
swift test
swift build
zsh Scripts/package-dmg.sh 0.1.0
zsh Tests/Packaging/package-smoke.sh 0.1.0
```

Packaging writes `dist/SkillSelector.app`, `dist/SkillSelector.dmg`, and the versioned GitHub Release asset `dist/SkillSelector-0.1.0.dmg`.

The focused acceptance suite uses only a temporary disposable home, fake `gh`/`npm`/MCP services, an intercepted HTTP transport, and an injected Trash adapter. The remaining packaged-app directory-panel and sandbox-boundary checks are manual release evidence; see [docs/test-plan.md](docs/test-plan.md).

## Installing a GitHub Release

Releases are ad-hoc signed and sandboxed, but are not Developer ID signed or notarized. After downloading the `.dmg` from GitHub Releases, mount it and drag `SkillSelector.app` to Applications. In Finder, Control-click the app, choose **Open**, then choose **Open** in the confirmation dialog. macOS remembers that choice for later launches.

If the dialog does not offer **Open**, go to System Settings > Privacy & Security, scroll to the security message for SkillSelector, click **Open Anyway**, authenticate when macOS asks, then confirm **Open**. Do not use this procedure for an app obtained from somewhere other than the project's GitHub Release.

## License

Apache License 2.0. See [LICENSE](LICENSE).
