# Task 10 Report: Extract Trusted Metadata with gh and npm

## Result

Implemented reviewable, trusted metadata enrichment through local `gh` and `npm` commands. Metadata application and update-source binding are separate actions: applying a candidate persists only the remote description and provenance; source binding requires both the dedicated checkbox and a confirmation dialog.

## Implementation

- Added `MetadataProvider`, `MetadataQuery`, `MetadataCandidate`, provider error types, and shared validation/error helpers.
- Added fixture-driven GitHub lookup using only `gh search code`, repository APIs, and raw remote `SKILL.md`/README retrieval. Description precedence is remote `SKILL.md`, repository description, then README paragraph.
- Added fixture-driven npm lookup using only `npm search --json` and `npm view --json -- <package>`. Dash-prefixed package names are rejected before view lookup.
- Added candidate review UI showing provider, repository/package, optional Skill directory, exact extracted text, and evidence URL.
- Added selected/visible manual enrichment plus an opt-in, default-off post-refresh mode that processes only Skills with no custom, local, or remote description.
- Added explicit queue and sheet state. Refresh, file-operation planning/execution, and enrichment are mutually excluded so their sheets cannot compete.
- Added `SkillIndex.setEnrichedDescription` without source-binding side effects, with regression coverage proving binding is separately persisted.
- Made `ToolLocator` an actor and marked its bookmark dependencies Sendable; concrete system adapters and test fixtures declare `@unchecked Sendable` where their underlying storage is externally synchronized or system-owned.
- Added English and Simplified Chinese resources for the feature.

## Verification

| Command | Result |
| --- | --- |
| `swift test --filter GitHubMetadataProviderTests` | PASS, 7 tests |
| `swift test --filter NPMMetadataProviderTests` | PASS, 6 tests |
| `swift test --filter SkillIndexTests` | PASS, 11 tests |
| `swift test` | PASS, 157 tests |
| `swift build` | PASS |
| `swift build -Xswiftc -target -Xswiftc x86_64-apple-macosx14.0` | PASS |
| `swift build -Xswiftc -target -Xswiftc arm64-apple-macosx14.0` | PASS |
| `plutil -lint` for both localization files | PASS |
| English/Simplified Chinese localization key comparison | PASS, no differences |
| `git diff --check` | PASS, no whitespace errors |

## Candidate Selection Binding Regression Fix

- Switching candidates now clears both the pending update-source checkbox state and
  any pending confirmation dialog state.
- The Apply action requests source-binding confirmation only when the currently
  selected candidate has a concrete `sourceBinding`; its disabled condition
  explicitly rejects a binding request without one.
- Added `SourceBindingDecision` as the small Core-level, unit-tested decision
  boundary used by the SwiftUI view.

| Command | Result |
| --- | --- |
| `swift test --filter SourceBindingDecisionTests` | PASS, 1 test |
| `swift test` | PASS, 162 tests |
| `swift build` | PASS |
| `git diff --check` | PASS, no whitespace errors |

## Review Notes

- Providers decode JSON with `JSONDecoder`, preserve exact selected source text, and never concatenate description fallbacks.
- Query and package inputs reject option-like, path-like, oversized, and control-character values. npm package names are placed after `--` for the view command.
- Providers receive only a Skill name and remote search result locations; no local path or full local Skill content is sent to external tools.
- Native UI behavior is compile-verified. Provider, persistence, command boundary, and localization behavior have deterministic automated coverage.

## Independent Review Fixes

- Added `ToolAccess`/`ToolAccessResult` so executable and authorized-home security-scoped leases remain active for the complete GitHub/npm lookup. Validation and provider commands receive the authorized home URL as `HOME`; AppModel closes both accesses only after every provider command has finished.
- Made candidate source binding optional. npm candidates are metadata-only until a concrete Skill directory and `SKILL.md` are verified, the review UI hides update-source binding for them, and AppModel persists a binding only when one exists.
- Rejected colon-bearing local names before GitHub search, preventing values such as `language:swift` and `org:foo` from becoming search qualifiers.
- Replaced README fallback reformatting with an original-source slice, preserving multiline indentation and LF/CRLF line endings exactly.

## Review Fix Verification

| Command | Result |
| --- | --- |
| `swift test --filter 'ExternalCommandRunnerTests\|GitHubMetadataProviderTests\|NPMMetadataProviderTests\|SkillIndexTests'` | PASS, 41 tests |
| `swift test` | PASS, 161 tests |
| `swift build --scratch-path .build-validation/default` | PASS |
| `swift build --scratch-path .build-validation/x86_64 -Xswiftc -target -Xswiftc x86_64-apple-macosx14.0` | PASS |
| `swift build --scratch-path .build-validation/arm64 -Xswiftc -target -Xswiftc arm64-apple-macosx14.0` | PASS |
| `plutil -lint` for both localization files | PASS |
| English/Simplified Chinese localization key comparison | PASS, no differences |
| `git diff --check` | PASS, no whitespace errors |
