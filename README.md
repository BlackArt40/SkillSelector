[![English](https://img.shields.io/badge/English-blue)](README.md)
[![简体中文](https://img.shields.io/badge/简体中文-blue)](README.zh-CN.md)

# SkillSelector

A native macOS app for managing Agent Skills on your local machine. Browse, copy, move, delete, link, and update Skills. Not a marketplace, not an installer, not an AI tool.

## Requirements

- macOS 14 Sonoma or later
- Universal 2 build (Apple Silicon + Intel)
- English and Simplified Chinese

## Supported Agents

Claude Code, Codex, Qoder, CodeBuddy, OpenCode, Cursor, Kilo Code, Cline, Roo Code, Windsurf, Gemini CLI, and GitHub Copilot. Roo Code works but only shows when detected or manually enabled. You can define custom Agents pointing to any local Skill directory.

## Privacy

Runs offline. Stores index records and security-scoped bookmarks—never copies Skill content. No telemetry, no crash reporter, no bundled model.

File operations touch only authorized Skill roots. Deletion goes to Trash.

## Build

```zsh
swift test
swift build
zsh Scripts/package-dmg.sh 0.1.0
zsh Tests/Packaging/package-smoke.sh 0.1.0
```

Produces `dist/SkillSelector.app`, `dist/SkillSelector.dmg`, and `dist/SkillSelector-0.1.0.dmg` for GitHub Releases.

## Installation

1. Download the `.dmg` from GitHub Releases
2. Drag `SkillSelector.app` to Applications
3. Right-click the app → **Open** → confirm **Open**

macOS Gatekeeper blocks unsigned apps by default. If the right-click menu doesn't show **Open**, go to System Settings → Privacy & Security → click **Open Anyway** next to the SkillSelector entry.

## License

Apache 2.0. See [LICENSE](LICENSE).
