# SkillSelector MVP Test Plan

This document records the release checks for the confirmed product specification. Automated checks use an isolated temporary directory; they do not read a real home directory, access the network, or invoke the macOS Trash.

## Automated Acceptance Coverage

Run the focused suite with:

```zsh
swift test --filter AcceptanceTests
```

`AcceptanceTests` creates a unique directory below the system temporary directory, including a disposable home, nested projects, fake executables, and an injected Trash adapter.

| Product behavior | Acceptance evidence |
| --- | --- |
| Allowlisted discovery and identity | Startup discovery deduplicates shared Agent paths, preserves malformed frontmatter diagnostics and symlink targets, recurses authorized projects, and skips dependency directories. |
| Refresh and descriptions | Manual refresh retains an inaccessible project record as unavailable; local descriptions override and a custom description overrides local content. |
| File safety | Copy conflict policies fail, cancel, keep both, and replace with a second confirmation. Move, symbolic-link creation, symbolic-link deletion, injected Trash, and unauthorized-source rejection are asserted. |
| Updates | Path-traversal and escaping-link archives are rejected. A changed local digest requires a second confirmation. A confirmed replacement updates a symlink target, moves the prior target through the injected Trash adapter, refreshes the affected root, and does not execute downloaded files. |

## Packaged-App Sandbox Check

Status: **manual, not executed by this automated run**. The release gate validates signing, sandbox entitlement, universal architectures, bundle version, and DMG integrity, but it cannot drive the macOS directory-panel authorization flow or make a trustworthy observation of sandbox boundaries. Perform this check before publishing a release.

1. Create a disposable directory with `home/.agents/skills/demo/SKILL.md`, `home/.cursor/skills/copied/SKILL.md`, and a separate `outside/` directory. Keep a small project tree below `home/projects/demo` with a registered project Skill directory.
2. Mount the versioned DMG and launch the packaged `SkillSelector.app`. In the first authorization panel, select only the disposable `home` directory. Do not grant access to its parent.
3. In English, run Home Check, add the disposable project, open `demo`, read its Markdown, set and remove a custom description, then copy, move, link, and delete a fixture Skill. Confirm the displayed source and destination for each operation.
4. Repeat the same actions with the system language set to Simplified Chinese. Confirm the same boundaries and confirmation screens are understandable in Chinese.
5. ~~Configure fake local `gh`, `npm`, and MCP entries only inside the disposable home. Trigger enrichment and update review; confirm that package runners are not launched, read-only MCP tools require the documented approvals, and update review shows changed files and the local-change warning.~~
6. Attempt to select, reveal, read, copy to, move to, link into, or delete `outside/`. Expected result: no browsing or structural write outside the individually authorized, registered roots. Verify the fixture outside directory is unchanged after quitting the app.

Record the package version, macOS version, locale, and observed results with the release evidence. Do not mark this scenario passed based only on unit or acceptance tests.

## Release Gate

Run from the repository root:

```zsh
swift test
swift build
zsh Scripts/package-dmg.sh 0.1.0
zsh Tests/Packaging/package-smoke.sh 0.1.0
git status --short
```

The smoke check verifies both the stable and versioned DMGs, the universal executable, the App Sandbox entitlement, and matching bundle versions. `git status --short` should contain only intended release-evidence changes before commit.
