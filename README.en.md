[![English](https://img.shields.io/badge/English-blue)](README.en.md)
[![简体中文](https://img.shields.io/badge/简体中文-blue)](README.md)

# SkillSelector

A native macOS app for managing Agent Skills on your local machine. Browse, copy, move, delete, link, and update Skills. Not a marketplace, not an installer, not an AI tool.

## Screenshots

| Main Window | Settings |
|:---:|:---:|
| ![Main Window](screenshots/main-en.png) | ![Settings](screenshots/settings-en.png) |

## Requirements

- macOS 14 Sonoma or later
- Universal 2 build (Apple Silicon + Intel)
- English and Simplified Chinese

## Supported Agents

Claude Code, Codex, Qoder, CodeBuddy, OpenCode, Cursor, Kilo Code, Cline, Roo Code, Windsurf, Gemini CLI, GitHub Copilot, Amp, Tabnine, Letta, and OpenHands. Roo Code works but only shows when detected or manually enabled. You can define custom Agents pointing to any local Skill directory.

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

Produces `dist/SkillSelector.app`, `dist/SkillSelector.dmg`, `dist/SkillSelector-0.1.0.dmg`, and a matching `.sha256` for GitHub Releases.

## Installation

1. Download the `.dmg` and its `.sha256` from GitHub Releases
2. Verify integrity (keep both files in the same directory):

   ```zsh
   shasum -a 256 -c SkillSelector-0.1.0.dmg.sha256
   ```

   It must print `SkillSelector-0.1.0.dmg: OK`. If it doesn't, don't install it.

3. Mount the `.dmg` and drag `SkillSelector.app` to Applications
4. Right-click the app → **Open** → confirm **Open**

macOS Gatekeeper blocks un-notarized apps by default. If the right-click menu doesn't show **Open**, go to System Settings → Privacy & Security → click **Open Anyway** next to the SkillSelector entry.

## Code signing

Releases are **ad-hoc signed** (`codesign --sign -`): **no Apple Developer certificate, no notarization**. Be clear on what that does and does not buy you:

- ✅ App Sandbox is enabled; the requested entitlements are in [`Packaging/SkillSelector.entitlements`](Packaging/SkillSelector.entitlements)
- ✅ The signature detects tampering with the app bundle after signing
- ❌ **It proves nothing about who published it** — anyone can produce an ad-hoc signature. Download only from this repository's GitHub Releases and check the `.sha256`
- ❌ Not notarized, so Gatekeeper blocks the first launch and you must allow it manually per step 4

If that's not acceptable, build from source (see **Build**) — releases go through the same packaging script.

## License

Apache 2.0. See [LICENSE](LICENSE).
