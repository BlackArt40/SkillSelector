# SkillSelector MVP Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **Note (2026-07-19):** The following features have been removed from the implementation:
> - Task 9 (Local tool detection for gh/npm) — deleted
> - Task 10 (Trusted metadata enrichment with gh/npm) — deleted
> - Task 11 (MCP tool discovery and invocation) — deleted
> - Related UI: Trusted Metadata section, Source section, Diagnostics section in skill detail
> - Related settings: "Enrich Missing Descriptions After Refresh" toggle, "Local Tools" section
> - Related sidebar: "Manage" section with "Directories" link

**Goal:** Build and package the confirmed SkillSelector macOS 14 application for safely discovering, viewing, managing, ~~enriching,~~ and updating existing local Agent Skills.

**Architecture:** A Swift Package contains a native SwiftUI executable and a `SkillSelectorCore` library. The core exposes deep interfaces for registry lookup, scanning/indexing, file operations, ~~enrichment,~~ and updates; SwiftUI calls those interfaces through one `@MainActor` app model. SwiftData persists metadata, while security-scoped bookmarks and external command execution remain behind dedicated adapters.

**Tech Stack:** Swift 6.3, SwiftUI, SwiftData, Foundation, AppKit, Security, OSLog, XCTest, Swift Package Manager, shell packaging scripts, Xcode 26.5 toolchain.

## Global Constraints

- Minimum deployment target is macOS 14 Sonoma.
- Release output is a Universal 2 `.dmg` for Apple Silicon and Intel.
- Release uses ad-hoc signing with App Sandbox, without Developer ID or notarization.
- Runtime code uses Apple system frameworks only; no third-party Swift packages.
- UI is localized in Simplified Chinese and English.
- Full Skill contents are read on demand and are never copied into SwiftData.
- Paths are unique Skill installation identities; one installation may belong to several Agents.
- All deletion moves content to macOS Trash.
- No telemetry, AI model, Skill marketplace, package installation, shell command strings, or continuous file watcher.
- Product behavior must remain consistent with `docs/product-spec.md` and accepted ADRs.

---

## Planned File Structure

```text
Package.swift                                  SwiftPM products and targets
Sources/SkillSelector/                         SwiftUI app and presentation state
Sources/SkillSelector/Resources/               en/zh-Hans strings and app resources
Sources/SkillSelectorCore/Domain/              value types and invariants
Sources/SkillSelectorCore/Registry/            built-in/custom Agent definitions
Sources/SkillSelectorCore/Scanning/            parser, traversal, and scan reports
Sources/SkillSelectorCore/Persistence/         SwiftData records and index module
Sources/SkillSelectorCore/Permissions/         security-scoped bookmark adapter
Sources/SkillSelectorCore/Operations/          copy/move/trash/link module
Sources/SkillSelectorCore/Commands/            direct external process runner
Sources/SkillSelectorCore/Enrichment/           gh, npm, and MCP metadata adapters
Sources/SkillSelectorCore/Updates/              source binding, diff, and replacement
Sources/SkillSelectorCore/Diagnostics/          redacted OSLog and report export
Tests/SkillSelectorCoreTests/                  deterministic unit/integration tests
Tests/Fixtures/                                temporary Skill tree fixture templates
Packaging/Info.plist                           generated app bundle metadata
Packaging/SkillSelector.entitlements           sandbox entitlements
Scripts/package-dmg.sh                         Universal 2 app and DMG build
```

### Task 1: Initialize a Compilable Native App Package

**Files:**
- Create: `Package.swift`
- Create: `Sources/SkillSelector/SkillSelectorApp.swift`
- Create: `Sources/SkillSelector/RootView.swift`
- Create: `Sources/SkillSelectorCore/SkillSelectorCore.swift`
- Create: `Tests/SkillSelectorCoreTests/SmokeTests.swift`
- Modify: `.gitignore`

**Interfaces:**
- Produces: `SkillSelectorApp` executable and importable `SkillSelectorCore` library.

- [ ] **Step 1: Write the failing smoke test**

Create this test in the already initialized implementation worktree:

```swift
import XCTest
@testable import SkillSelectorCore

final class SmokeTests: XCTestCase {
    func testCoreReportsProductName() {
        XCTAssertEqual(SkillSelectorCore.productName, "SkillSelector")
    }
}
```

- [ ] **Step 2: Add the Swift package manifest and verify the test fails**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SkillSelector",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SkillSelectorCore", targets: ["SkillSelectorCore"]),
        .executable(name: "SkillSelector", targets: ["SkillSelector"]),
    ],
    targets: [
        .target(name: "SkillSelectorCore"),
        .executableTarget(
            name: "SkillSelector",
            dependencies: ["SkillSelectorCore"]
        ),
        .testTarget(name: "SkillSelectorCoreTests", dependencies: ["SkillSelectorCore"]),
    ]
)
```

Run: `swift test --filter SmokeTests`

Expected: FAIL because `SkillSelectorCore.productName` does not exist.

- [ ] **Step 3: Implement the minimal core and app shell**

```swift
public enum SkillSelectorCore {
    public static let productName = "SkillSelector"
}
```

```swift
import SwiftUI

@main
struct SkillSelectorApp: App {
    var body: some Scene {
        WindowGroup { RootView() }
            .defaultSize(width: 1120, height: 720)
    }
}
```

```swift
import SwiftUI

struct RootView: View {
    var body: some View {
        NavigationSplitView {
            Text("SkillSelector")
        } content: {
            ContentUnavailableView("No Skills", systemImage: "tray")
        } detail: {
            ContentUnavailableView("Select a Skill", systemImage: "doc.text")
        }
    }
}
```

- [ ] **Step 4: Add generated-output ignores and verify the package**

Append `.build/`, `DerivedData/`, `dist/`, `.firecrawl/`, and `*.dmg` to `.gitignore`.

Run: `swift test && swift build`

Expected: all tests pass and the executable builds without warnings.

- [ ] **Step 5: Commit the scaffold**

```bash
git add Package.swift Sources Tests .gitignore
git commit -m "build: scaffold native SkillSelector package"
```

### Task 2: Define Skill Identity and the Agent Registry

**Files:**
- Create: `Sources/SkillSelectorCore/Domain/AgentDefinition.swift`
- Create: `Sources/SkillSelectorCore/Domain/SkillInstallation.swift`
- Create: `Sources/SkillSelectorCore/Registry/AgentRegistry.swift`
- Create: `Sources/SkillSelectorCore/Registry/BuiltInAgentRegistry.swift`
- Test: `Tests/SkillSelectorCoreTests/AgentRegistryTests.swift`

**Interfaces:**
- Produces: `AgentDefinition`, `SkillInstallation`, `AgentRegistry`, and `BuiltInAgentRegistry.make()`.
- Invariant: normalized absolute installation path is identity; resolved target is metadata, not identity.

- [ ] **Step 1: Write registry and identity tests**

```swift
import XCTest
@testable import SkillSelectorCore

final class AgentRegistryTests: XCTestCase {
    func testBuiltInRegistryContainsConfirmedAgents() {
        let ids = Set(BuiltInAgentRegistry.make().definitions.map(\.id))
        XCTAssertEqual(ids, Set([
            "claude-code", "codex", "qoder", "codebuddy", "opencode",
            "cursor", "kilo-code", "cline", "roo-code", "windsurf",
            "gemini-cli", "github-copilot",
        ]))
    }

    func testOnePathCanAccumulateAgentAssociations() {
        var skill = SkillInstallation(path: URL(fileURLWithPath: "/tmp/shared/demo"))
        skill.agentIDs.formUnion(["cursor", "gemini-cli"])
        XCTAssertEqual(skill.agentIDs.count, 2)
        XCTAssertEqual(skill.id, "/tmp/shared/demo")
    }
}
```

- [ ] **Step 2: Run the tests to verify failure**

Run: `swift test --filter AgentRegistryTests`

Expected: FAIL because the domain and registry types do not exist.

- [ ] **Step 3: Implement the domain interfaces**

```swift
import Foundation

public struct AgentDefinition: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public var displayName: String
    public var globalRoots: [String]
    public var projectPatterns: [String]
    public var entryFilename: String
    public var isLegacy: Bool

    public init(
        id: String,
        displayName: String,
        globalRoots: [String],
        projectPatterns: [String],
        entryFilename: String = "SKILL.md",
        isLegacy: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.globalRoots = globalRoots
        self.projectPatterns = projectPatterns
        self.entryFilename = entryFilename
        self.isLegacy = isLegacy
    }
}

public struct SkillInstallation: Identifiable, Hashable, Sendable {
    public let id: String
    public let path: URL
    public var resolvedTarget: URL?
    public var agentIDs: Set<String>

    public init(path: URL, resolvedTarget: URL? = nil, agentIDs: Set<String> = []) {
        let normalized = path.standardizedFileURL.path
        self.id = normalized
        self.path = URL(fileURLWithPath: normalized)
        self.resolvedTarget = resolvedTarget
        self.agentIDs = agentIDs
    }
}
```

- [ ] **Step 4: Implement the registry and all confirmed path definitions**

Define `AgentRegistry` with `definition(id:)`, `matchingGlobalRoot(_:)`, and custom-definition merge behavior. Populate the researched paths from `docs/research/agent-skill-support.md`. For the five original requirements, encode Claude Code (`~/.claude/skills`, `.claude/skills`), Codex (`~/.codex/skills`, `.codex/skills`, and shared `.agents/skills`), Qoder (`~/.qoder/skills`, `.qoder/skills`), CodeBuddy (`~/.codebuddy/skills`, `.codebuddy/skills`), and OpenCode (`~/.config/opencode/skills`, `~/.opencode/skills`, `.opencode/skills`, and shared `.agents/skills`). Encode Roo Code with `isLegacy: true`; encode shared `.agents/skills` roots on every Agent that officially supports them. Add a table-driven assertion for every global root and project pattern.

Run: `swift test --filter AgentRegistryTests`

Expected: PASS with exactly 12 built-in IDs.

- [ ] **Step 5: Commit the registry**

```bash
git add Sources/SkillSelectorCore/Domain Sources/SkillSelectorCore/Registry Tests/SkillSelectorCoreTests/AgentRegistryTests.swift
git commit -m "feat: define Skill identity and Agent registry"
```

### Task 3: Parse and Scan Skill Trees

**Files:**
- Create: `Sources/SkillSelectorCore/Scanning/FrontmatterParser.swift`
- Create: `Sources/SkillSelectorCore/Scanning/SkillScanner.swift`
- Create: `Sources/SkillSelectorCore/Scanning/ScanTypes.swift`
- Test: `Tests/SkillSelectorCoreTests/FrontmatterParserTests.swift`
- Test: `Tests/SkillSelectorCoreTests/SkillScannerTests.swift`

**Interfaces:**
- Consumes: `AgentRegistry`, `SkillInstallation`.
- Produces: `FrontmatterParser.parse(_:) -> ParsedSkillDocument` and `SkillScanner.scan(_:) async -> ScanReport`.

- [ ] **Step 1: Write parser tests for valid, multiline, and invalid frontmatter**

```swift
func testParsesRequiredFieldsAndBlockDescription() throws {
    let text = """
    ---
    name: release-notes
    description: |
      Draft release notes
      from merged changes.
    ---
    # Release Notes
    """
    let parsed = FrontmatterParser.parse(text)
    XCTAssertEqual(parsed.name, "release-notes")
    XCTAssertEqual(parsed.description, "Draft release notes\nfrom merged changes.")
    XCTAssertTrue(parsed.issues.isEmpty)
}

func testInvalidFrontmatterRemainsRepresentable() {
    let parsed = FrontmatterParser.parse("---\nname: [broken\n---\n# Broken")
    XCTAssertFalse(parsed.issues.isEmpty)
    XCTAssertEqual(parsed.title, "Broken")
}
```

- [ ] **Step 2: Run parser tests and implement the bounded YAML subset**

Run: `swift test --filter FrontmatterParserTests`

Expected: FAIL because `FrontmatterParser` is absent.

Implement scalar strings, quoted strings, `|` and `>` block values, frontmatter boundaries, heading extraction, and first descriptive paragraph. Preserve unknown fields as `[String: String]`; report malformed syntax instead of throwing away the document.

Run the same command again.

Expected: PASS.

- [ ] **Step 3: Write scanner tests using temporary directories**

```swift
func testSharedRootProducesOneInstallationWithManyAgents() async throws {
    let fixture = try ScanFixture()
    try fixture.writeSkill(at: ".agents/skills/demo", name: "demo", description: "Demo")
    let roots = fixture.rootsForSharedAgents(["cursor", "gemini-cli"])
    let report = await SkillScanner().scan(roots)
    XCTAssertEqual(report.installations.count, 1)
    XCTAssertEqual(report.installations[0].agentIDs, ["cursor", "gemini-cli"])
}

func testProjectTraversalSkipsDependencies() async throws {
    let fixture = try ScanFixture()
    try fixture.writeSkill(at: "packages/app/.cursor/skills/real", name: "real")
    try fixture.writeSkill(at: "node_modules/pkg/.cursor/skills/ignored", name: "ignored")
    let report = await SkillScanner().scan([fixture.projectRoot])
    XCTAssertEqual(report.installations.map(\.path.lastPathComponent), ["real"])
}
```

- [ ] **Step 4: Implement safe traversal and symlink metadata**

`SkillScanner` must enumerate only authorized roots, skip `.git`, `node_modules`, `.build`, `build`, `dist`, `DerivedData`, `.swiftpm`, `Pods`, and vendor caches, and stop descending after recognizing a Skill package. Use resource keys for directory and symbolic-link state. Deduplicate by `standardizedFileURL.path`, union Agent IDs, and return root-level availability separately from parse issues.

Run: `swift test --filter SkillScannerTests`

Expected: PASS for recursive monorepo discovery, skipped directories, shared paths, malformed Skills, and symbolic links.

- [ ] **Step 5: Commit scanning**

```bash
git add Sources/SkillSelectorCore/Scanning Tests/SkillSelectorCoreTests/FrontmatterParserTests.swift Tests/SkillSelectorCoreTests/SkillScannerTests.swift Tests/Fixtures
git commit -m "feat: scan and parse local Skill trees"
```

### Task 4: Persist Authorization and the Metadata Index

**Files:**
- Create: `Sources/SkillSelectorCore/Permissions/BookmarkStore.swift`
- Create: `Sources/SkillSelectorCore/Persistence/SkillRecord.swift`
- Create: `Sources/SkillSelectorCore/Persistence/AuthorizedRootRecord.swift`
- Create: `Sources/SkillSelectorCore/Persistence/SkillIndex.swift`
- Test: `Tests/SkillSelectorCoreTests/BookmarkStoreTests.swift`
- Test: `Tests/SkillSelectorCoreTests/SkillIndexTests.swift`

**Interfaces:**
- Produces: `BookmarkStore.save(url:kind:)`, `BookmarkStore.resolve(id:)`, `SkillIndex.apply(report:)`, and query methods returning immutable view snapshots.

- [ ] **Step 1: Write in-memory index reconciliation tests**

```swift
func testUnavailableRootRetainsRecords() throws {
    let index = try TestIndex.inMemory()
    try index.seed(skillPath: "/tmp/project/.agents/skills/demo", rootID: "project")
    try index.apply(.unavailable(rootID: "project", reason: "bookmark stale"))
    XCTAssertEqual(try index.skills().first?.availability, .unavailable)
}

func testAccessibleMissingPathRemovesRecord() throws {
    let index = try TestIndex.inMemory()
    try index.seed(skillPath: "/tmp/project/.agents/skills/demo", rootID: "project")
    try index.apply(.available(rootID: "project", installations: []))
    XCTAssertTrue(try index.skills().isEmpty)
}
```

- [ ] **Step 2: Implement SwiftData records without full document content**

Create `@Model` records for path, resolved target, name, local description, enriched description and provenance, custom description, digest, modification date, availability, source binding, Agent IDs, root ID, and parse diagnostics. Do not add a property for full `SKILL.md` text.

Run: `swift test --filter SkillIndexTests`

Expected: reconciliation tests pass using an in-memory `ModelContainer`.

- [ ] **Step 3: Write bookmark round-trip and stale-bookmark tests**

Inject a `BookmarkDataCreating` adapter so tests use deterministic bytes rather than requiring a real sandbox extension. Verify that resolving stale data refreshes the stored bookmark and that every successful `startAccessingSecurityScopedResource()` has a paired stop closure.

- [ ] **Step 4: Implement `BookmarkStore` and verify tests**

Use `.withSecurityScope` bookmark creation and `.withSecurityScope` resolution. Return an `AccessLease` whose `close()` is idempotent. Persist root kind as `home`, `project`, `system`, or `custom`; never infer broader roots from a child URL.

Run: `swift test --filter BookmarkStoreTests && swift test --filter SkillIndexTests`

Expected: PASS.

- [ ] **Step 5: Commit persistence and permission adapters**

```bash
git add Sources/SkillSelectorCore/Permissions Sources/SkillSelectorCore/Persistence Tests/SkillSelectorCoreTests/BookmarkStoreTests.swift Tests/SkillSelectorCoreTests/SkillIndexTests.swift
git commit -m "feat: persist authorized roots and Skill index"
```

### Task 5: Orchestrate Environment Checks and Refreshes

**Files:**
- Create: `Sources/SkillSelectorCore/Scanning/IndexRefresher.swift`
- Create: `Sources/SkillSelector/AppModel.swift`
- Create: `Sources/SkillSelector/AuthorizationViews.swift`
- Modify: `Sources/SkillSelector/SkillSelectorApp.swift`
- Test: `Tests/SkillSelectorCoreTests/IndexRefresherTests.swift`

**Interfaces:**
- Consumes: registry, bookmarks, scanner, index.
- Produces: `IndexRefresher.refresh(_:) async -> RefreshSummary` and `AppModel.checkEnvironment()`.

- [ ] **Step 1: Test allowlisted home expansion**

Given an authorized home URL and the 12-Agent registry, assert that `IndexRefresher` creates candidates only from declared global roots. Include an unrelated `~/Documents/private/SKILL.md` fixture and assert it is never enumerated.

- [ ] **Step 2: Implement refresh orchestration**

Resolve each bookmark, expand `~` relative to the authorized home, scan standard roots that exist, recursively scan registered project patterns inside authorized projects, apply one reconciliation transaction, and return counts for added, changed, unavailable, and removed installations.

Run: `swift test --filter IndexRefresherTests`

Expected: PASS with no access outside fixture roots.

- [ ] **Step 3: Add the main-actor app model**

```swift
@MainActor
@Observable
final class AppModel {
    private let refresher: IndexRefresher
    var refreshState: RefreshState = .idle
    var selection: SkillSelection?

    func checkEnvironment() async {
        refreshState = .running
        do { refreshState = .finished(try await refresher.refresh(.startup)) }
        catch { refreshState = .failed(String(describing: error)) }
    }
}
```

Inject dependencies from `SkillSelectorApp` instead of constructing them inside views.

- [ ] **Step 4: Add home, project, system, and custom directory panels**

Use `NSOpenPanel` configured for single directory selection. The home authorization copy must state that only known Agent paths are accessed. Project and system authorizations create their exact root records. Start automatic refresh after authorization and on subsequent launches.

Run: `swift test && swift build`

Expected: core tests pass and authorization views compile.

- [ ] **Step 5: Commit refresh orchestration**

```bash
git add Sources/SkillSelectorCore/Scanning/IndexRefresher.swift Sources/SkillSelector/AppModel.swift Sources/SkillSelector/AuthorizationViews.swift Sources/SkillSelector/SkillSelectorApp.swift Tests/SkillSelectorCoreTests/IndexRefresherTests.swift
git commit -m "feat: authorize and refresh Skill environments"
```

### Task 6: Build the Localized Three-Column Browser

**Files:**
- Modify: `Package.swift`
- Create: `Sources/SkillSelector/Browser/BrowserSidebar.swift`
- Create: `Sources/SkillSelector/Browser/SkillListView.swift`
- Create: `Sources/SkillSelector/Browser/SkillDetailView.swift`
- Create: `Sources/SkillSelector/Browser/SkillRow.swift`
- Create: `Sources/SkillSelector/Resources/en.lproj/Localizable.strings`
- Create: `Sources/SkillSelector/Resources/zh-Hans.lproj/Localizable.strings`
- Modify: `Sources/SkillSelector/RootView.swift`
- Test: `Tests/SkillSelectorCoreTests/SkillQueryTests.swift`

**Interfaces:**
- Consumes: immutable index snapshots and `AppModel` commands.
- Produces: sidebar filters for all/global/projects/Agents and list filtering/sorting/search.

- [ ] **Step 1: Test multi-Agent filtering without duplicate rows**

Create three snapshots where one is shared by Cursor and Gemini. Assert all-skills returns three rows, Cursor returns the shared row once, and Gemini returns the shared row once. Test global/project scope and case-insensitive name/description search.

- [ ] **Step 2: Implement query projection and run tests**

Keep filtering in a pure `SkillQuery.apply(to:)` function so SwiftUI does not duplicate business rules.

Run: `swift test --filter SkillQueryTests`

Expected: PASS.

- [ ] **Step 3: Implement stable native navigation**

Use `NavigationSplitView` with sidebar width 190...260, list width 280...380, and detail minimum width 420. Add toolbar refresh, search field, filter menu, sort menu, and settings command. Empty states provide the two authorization actions without a separate landing page.

- [ ] **Step 4: Add complete English and Simplified Chinese strings**

Add `.process("Resources")` to the `SkillSelector` executable target in `Package.swift`. Localize every user-visible label, confirmation, error, status, and accessibility label. Keep path strings, Agent names, frontmatter keys, and command output untranslated. Verify with:

Run: `swift build`

Expected: no missing-resource warnings.

- [ ] **Step 5: Commit the browser**

```bash
git add Sources/SkillSelector/Browser Sources/SkillSelector/Resources Sources/SkillSelector/RootView.swift Tests/SkillSelectorCoreTests/SkillQueryTests.swift
git commit -m "feat: add localized Skill browser"
```

### Task 7: Render Documents and Manage Description Provenance

**Files:**
- Create: `Sources/SkillSelectorCore/Domain/DescriptionResolver.swift`
- Create: `Sources/SkillSelector/Browser/MarkdownDocumentView.swift`
- Create: `Sources/SkillSelector/Browser/DescriptionEditor.swift`
- Modify: `Sources/SkillSelector/Browser/SkillDetailView.swift`
- Test: `Tests/SkillSelectorCoreTests/DescriptionResolverTests.swift`

**Interfaces:**
- Produces: `DescriptionResolver.resolve(_:) -> EffectiveDescription` with provenance.

- [ ] **Step 1: Test the exact description priority**

```swift
func testDescriptionPriority() {
    let all = DescriptionCandidates(custom: "Custom", local: "Local", remote: "Remote", fallback: "Fallback")
    XCTAssertEqual(DescriptionResolver.resolve(all), .init(text: "Custom", source: .custom))
    XCTAssertEqual(DescriptionResolver.resolve(all.removingCustom).source, .local)
    XCTAssertEqual(DescriptionResolver.resolve(all.onlyRemoteAndFallback).source, .remote)
    XCTAssertEqual(DescriptionResolver.resolve(all.onlyFallback).source, .fallback)
}
```

- [ ] **Step 2: Implement the resolver and verify tests**

Run: `swift test --filter DescriptionResolverTests`

Expected: PASS for custom, local, remote, fallback, and empty states.

- [ ] **Step 3: Implement read-only Markdown loading**

Load `SKILL.md` from the authorized path only when detail is visible. Render supported Markdown through `AttributedString(markdown:)` inside a selectable `Text`; show source text when parsing fails. Cap rendering input at a documented size and offer external open for larger files without persisting content.

- [ ] **Step 4: Add customization, reset, Finder, and external-editor actions**

Persist only the custom description. “Restore default” clears that field and immediately recomputes provenance. Use `NSWorkspace.activateFileViewerSelecting` and `NSWorkspace.open` for external actions.

Run: `swift test && swift build`

Expected: all tests pass and detail actions compile.

- [ ] **Step 5: Commit document viewing**

```bash
git add Sources/SkillSelectorCore/Domain/DescriptionResolver.swift Sources/SkillSelector/Browser Tests/SkillSelectorCoreTests/DescriptionResolverTests.swift
git commit -m "feat: show Skill documents and description provenance"
```

### Task 8: Implement Confirmed File Operations

**Files:**
- Create: `Sources/SkillSelectorCore/Operations/SkillFileOperator.swift`
- Create: `Sources/SkillSelectorCore/Operations/FileOperationPlan.swift`
- Create: `Sources/SkillSelector/FileOperations/OperationConfirmationView.swift`
- Test: `Tests/SkillSelectorCoreTests/SkillFileOperatorTests.swift`

**Interfaces:**
- Produces: `plan(_:) throws -> FileOperationPlan` and `execute(_:) async throws -> FileOperationResult`.
- Invariant: execute accepts only a previously generated plan whose authorized-root snapshot is unchanged.

- [ ] **Step 1: Test authorization, conflicts, Trash, and links**

Cover rejected unregistered destinations, keep-both naming, replace requiring a second confirmation token, move preserving record identity, copy inheriting source metadata, relative links within one project, absolute links across roots, and deleting a link without touching its target.

- [ ] **Step 2: Implement planning as a side-effect-free operation**

`FileOperationPlan` must disclose operation kind, source, destination, conflict resolution, resolved link target, affected indexed links, and whether replacement moves an existing target to Trash. Reject traversal outside `AuthorizedRoot` using standardized and resolved URLs.

Run: `swift test --filter SkillFileOperatorTests`

Expected: planning tests pass before any filesystem mutation assertions.

- [ ] **Step 3: Implement execution with `FileManager`**

Use copy/move/link filesystem methods and `trashItem(at:resultingItemURL:)`. Never recursively merge. Stage replacement beside the destination, validate it, trash the old target, then rename the staged directory. Refresh only affected roots after success.

- [ ] **Step 4: Build the confirmation sheet and verify integration tests**

The sheet shows source and target paths, conflict choice, symlink target, and every affected alias. Replacement requires a distinct confirmation action.

Run: `swift test --filter SkillFileOperatorTests && swift build`

Expected: PASS.

- [ ] **Step 5: Commit file operations**

```bash
git add Sources/SkillSelectorCore/Operations Sources/SkillSelector/FileOperations Tests/SkillSelectorCoreTests/SkillFileOperatorTests.swift
git commit -m "feat: add safe Skill file operations"
```

### Task 9: Run External Tools Without a Shell

**Files:**
- Create: `Sources/SkillSelectorCore/Commands/ExternalCommandRunner.swift`
- Create: `Sources/SkillSelectorCore/Commands/ToolLocator.swift`
- Create: `Sources/SkillSelectorCore/Commands/CommandApproval.swift`
- Test: `Tests/SkillSelectorCoreTests/ExternalCommandRunnerTests.swift`

**Interfaces:**
- Produces: `ExternalCommandRunner.run(_:) async throws -> CommandResult` and `ToolLocator.locate(_:)`.

- [ ] **Step 1: Test direct argument handling and output bounds**

Use a fixture executable path with arguments containing spaces, semicolons, dollar signs, and backticks; assert they arrive as literal arguments. Assert timeout termination, maximum stdout/stderr bytes, environment allowlisting, and cancellation.

- [ ] **Step 2: Implement the runner with `Process`**

Pass `executableURL` and `arguments` directly. Set a minimal environment containing locale, HOME when authorized, and an explicit PATH. Capture stdout/stderr concurrently to avoid pipe deadlock. Reject output beyond the configured bound and return exit status without interpreting stderr as code.

Run: `swift test --filter ExternalCommandRunnerTests`

Expected: PASS with no shell expansion.

- [ ] **Step 3: Implement tool detection and binding**

Check `/opt/homebrew/bin`, `/usr/local/bin`, and system paths for `gh` and `npm`; validate selected executables by resolving bookmarks and running fixed version commands. Store executable bookmarks, not credentials. Report unavailable, available, unauthenticated, and invalid states.

- [ ] **Step 4: Implement exact-command approvals**

Hash executable path plus ordered arguments for MCP package-runner commands. Persist user approval for that hash only. A changed executable, argument, or MCP configuration produces a different hash and returns `approvalRequired`.

Run: `swift test && swift build`

Expected: all command tests pass.

- [ ] **Step 5: Commit command infrastructure**

```bash
git add Sources/SkillSelectorCore/Commands Tests/SkillSelectorCoreTests/ExternalCommandRunnerTests.swift
git commit -m "feat: run approved local tools safely"
```

### Task 10: Extract Trusted Metadata with gh and npm

**Files:**
- Create: `Sources/SkillSelectorCore/Enrichment/MetadataProvider.swift`
- Create: `Sources/SkillSelectorCore/Enrichment/GitHubMetadataProvider.swift`
- Create: `Sources/SkillSelectorCore/Enrichment/NPMMetadataProvider.swift`
- Create: `Sources/SkillSelector/Enrichment/CandidateSourceView.swift`
- Test: `Tests/SkillSelectorCoreTests/GitHubMetadataProviderTests.swift`
- Test: `Tests/SkillSelectorCoreTests/NPMMetadataProviderTests.swift`

**Interfaces:**
- Produces: `MetadataProvider.candidates(for:) async throws -> [MetadataCandidate]`.

- [ ] **Step 1: Write fixture-driven provider tests**

Stub `CommandRunning` and assert the GitHub provider emits fixed `gh search code`, `gh api`, and download arguments limited to the local Skill name and `SKILL.md`. Assert npm emits only `search --json` and `view --json`; package names beginning with `-` are rejected or separated after `--`.

- [ ] **Step 2: Implement deterministic source extraction**

Parse JSON using `JSONDecoder`. Extract description in this order: remote `SKILL.md`, official manifest/package description, README first descriptive paragraph. Preserve exact source text and URL. Do not synthesize or concatenate a new description.

Run: `swift test --filter GitHubMetadataProviderTests && swift test --filter NPMMetadataProviderTests`

Expected: PASS for valid, empty, malformed, rate-limited, and unauthenticated results.

- [ ] **Step 3: Add candidate review UI**

Show repository/package, Skill subdirectory, extracted text, evidence URL, and provider. Applying a candidate stores remote metadata; binding it as an update source is a separate explicit checkbox and confirmation.

- [ ] **Step 4: Wire manual and optional missing-only enrichment**

Default to manual single/batch enrichment. The setting for post-refresh enrichment processes only records with no custom, local, or remote description and defaults false. Never send local paths or full Skill content.

Run: `swift test && swift build`

Expected: all tests pass and enrichment UI compiles.

- [ ] **Step 5: Commit gh/npm enrichment**

```bash
git add Sources/SkillSelectorCore/Enrichment Sources/SkillSelector/Enrichment Tests/SkillSelectorCoreTests/GitHubMetadataProviderTests.swift Tests/SkillSelectorCoreTests/NPMMetadataProviderTests.swift
git commit -m "feat: enrich Skills with trusted gh and npm metadata"
```

### Task 11: Discover and Invoke Approved MCP Tools

**Files:**
- Create: `Sources/SkillSelectorCore/Enrichment/MCP/MCPTypes.swift`
- Create: `Sources/SkillSelectorCore/Enrichment/MCP/MCPConfigDiscovery.swift`
- Create: `Sources/SkillSelectorCore/Enrichment/MCP/StdioMCPClient.swift`
- Create: `Sources/SkillSelectorCore/Enrichment/MCP/HTTPMCPClient.swift`
- Create: `Sources/SkillSelector/MCP/MCPSettingsView.swift`
- Test: `Tests/SkillSelectorCoreTests/MCPClientTests.swift`

**Interfaces:**
- Produces: `MCPConfigDiscovery.discover(in:)`, `MCPClient.listTools()`, and `MCPClient.call(tool:arguments:)`.

- [ ] **Step 1: Test config discovery without execution**

Provide Claude, Codex, and generic MCP config fixtures. Assert discovery returns disabled candidates and never calls `CommandRunning`. Include stdio, Streamable HTTP, legacy SSE, and package-runner examples; assert legacy SSE is unsupported and package runners require exact-command approval.

- [ ] **Step 2: Implement JSON-RPC framing and lifecycle tests**

Test initialize, initialized notification, tools/list, tools/call, request IDs, timeouts, bounded response size, server errors, cancellation, and stdio process termination. For HTTP, test `Mcp-Session-Id` handling and JSON responses using injected `URLProtocol`.

- [ ] **Step 3: Implement stdio and Streamable HTTP clients**

The stdio client launches only an enabled, approved command and stops after the enrichment operation. The HTTP client uses an ephemeral `URLSession` and accepts only `http` or `https` endpoints the user enabled. Neither client evaluates returned text or commands.

Run: `swift test --filter MCPClientTests`

Expected: PASS for both transports and every rejection case.

- [ ] **Step 4: Add MCP settings and metadata mapping**

List discovered Servers, exact transport/command, available tools, read-only annotation, and enabled state. Tools without an explicit read-only annotation require per-tool confirmation. Map selected tool results into `MetadataCandidate` only after structured validation.

Run: `swift test && swift build`

Expected: all tests pass.

- [ ] **Step 5: Commit MCP support**

```bash
git add Sources/SkillSelectorCore/Enrichment/MCP Sources/SkillSelector/MCP Tests/SkillSelectorCoreTests/MCPClientTests.swift
git commit -m "feat: add approved MCP metadata providers"
```

### Task 12: Bind Sources and Update One Skill Package Atomically

**Files:**
- Create: `Sources/SkillSelectorCore/Updates/SkillSource.swift`
- Create: `Sources/SkillSelectorCore/Updates/PackageDigest.swift`
- Create: `Sources/SkillSelectorCore/Updates/PackageValidator.swift`
- Create: `Sources/SkillSelectorCore/Updates/SkillUpdater.swift`
- Create: `Sources/SkillSelector/Updates/UpdateReviewView.swift`
- Test: `Tests/SkillSelectorCoreTests/SkillUpdaterTests.swift`

**Interfaces:**
- Produces: `SkillUpdater.check(_:) async throws -> UpdateProposal` and `SkillUpdater.apply(_:) async throws -> UpdateResult`.

- [ ] **Step 1: Test provenance and normalized digest rules**

Cover embedded source metadata, containing Git remote plus relative path, remembered binding, and user-confirmed candidate. Assert a name-only candidate cannot create `SkillSource`. Digest files in sorted relative-path order with their bytes, excluding `.git`, Finder metadata, and app index files; include executable bits and symlink destinations.

- [ ] **Step 2: Test hostile and invalid downloaded packages**

Reject missing or malformed `SKILL.md`, mismatched required name, archive `../` traversal, absolute archive paths, symlinks escaping the package, device nodes, and excessive file count/bytes. Accept a nested repository subdirectory that is a complete Skill.

- [ ] **Step 3: Implement source check and proposal generation**

For GitHub, invoke approved `gh` commands to resolve the selected branch/tag/commit and download the exact subtree into a temporary directory. For non-GitHub, accept only an explicit direct package URL. Validate, digest, and compute added/changed/deleted relative paths. A tag or commit source is pinned; a branch source compares remote digest to indexed digest.

Run: `swift test --filter SkillUpdaterTests`

Expected: proposal tests pass without mutating installed fixtures.

- [ ] **Step 4: Implement confirmed replacement and link disclosure**

Before apply, recompute the local digest; if it differs from the proposal baseline, return `localChangesRequireConfirmation`. Resolve symlink targets and include all indexed aliases. After confirmation, stage beside the target, move the old directory to Trash, rename the stage, retain app-owned custom metadata, and refresh the root.

- [ ] **Step 5: Add update review UI and run integration tests**

Show source, ref, content digest, file-level summary, local-change warning, actual symlink target, and affected aliases. Require explicit confirmation after any warning.

Run: `swift test --filter SkillUpdaterTests && swift build`

Expected: PASS for update, cancellation, local changes, rollback on failed staging, and linked installations.

- [ ] **Step 6: Commit updating**

```bash
git add Sources/SkillSelectorCore/Updates Sources/SkillSelector/Updates Tests/SkillSelectorCoreTests/SkillUpdaterTests.swift
git commit -m "feat: update individual Skill packages safely"
```

### Task 13: Add Settings and Redacted Diagnostics

**Files:**
- Create: `Sources/SkillSelector/Settings/SettingsView.swift`
- Create: `Sources/SkillSelectorCore/Diagnostics/Redactor.swift`
- Create: `Sources/SkillSelectorCore/Diagnostics/DiagnosticExporter.swift`
- Test: `Tests/SkillSelectorCoreTests/RedactorTests.swift`

**Interfaces:**
- Produces: deterministic redaction and a user-initiated diagnostic archive containing no full Skill content or credentials.

- [ ] **Step 1: Write redaction tests**

Cover home paths, project paths, bearer/token-shaped environment values, command arguments containing secrets, remote response bodies, and ordinary status messages. Assert redaction is stable and does not remove Agent names or non-sensitive error codes.

- [ ] **Step 2: Implement logging and export**

Use `Logger` categories for scanning, persistence, operations, commands, enrichment, and updates. Apply redaction before interpolation. Export app version, macOS version, registry IDs, root availability without full paths, tool versions, and recent app-owned diagnostics only after a save panel confirmation.

Run: `swift test --filter RedactorTests`

Expected: PASS with no fixture secret in output.

- [ ] **Step 3: Build settings views**

Include startup refresh, optional missing-only enrichment defaulting off, authorized roots with revoke/re-authorize, custom Agent definitions, detected gh/npm state, MCP approvals, and diagnostic export. Revoking a root closes access and marks records unavailable instead of deleting metadata.

- [ ] **Step 4: Verify the complete debug application**

Run: `swift test && swift build`

Expected: all tests pass and build completes without warnings.

- [ ] **Step 5: Commit settings and diagnostics**

```bash
git add Sources/SkillSelector/Settings Sources/SkillSelectorCore/Diagnostics Tests/SkillSelectorCoreTests/RedactorTests.swift
git commit -m "feat: add private settings and diagnostics"
```

### Task 14: Package an Ad-Hoc Signed Universal 2 DMG

**Files:**
- Create: `Packaging/Info.plist`
- Create: `Packaging/SkillSelector.entitlements`
- Create: `Scripts/package-dmg.sh`
- Create: `LICENSE`
- Create: `README.md`
- Create: `docs/releasing.md`
- Test: `Tests/Packaging/package-smoke.sh`

**Interfaces:**
- Produces: `dist/SkillSelector.app` and `dist/SkillSelector.dmg`; the GitHub Release asset name includes the version.

- [ ] **Step 1: Add bundle metadata and sandbox entitlements**

Set bundle identifier `io.github.skillselector.SkillSelector`, minimum system `14.0`, high-resolution capability, English and Simplified Chinese localizations, and version values supplied by the packaging script. Entitlements must include App Sandbox, user-selected read/write files, and outbound network client access.

- [ ] **Step 2: Write the packaging smoke test first**

```bash
#!/bin/zsh
set -euo pipefail
APP="dist/SkillSelector.app"
test -x "$APP/Contents/MacOS/SkillSelector"
lipo -verify_arch arm64 x86_64 "$APP/Contents/MacOS/SkillSelector"
codesign --verify --deep --strict "$APP"
codesign -d --entitlements :- "$APP" 2>&1 | grep -q 'com.apple.security.app-sandbox'
plutil -lint "$APP/Contents/Info.plist"
test -f dist/SkillSelector.dmg
```

Run: `zsh Tests/Packaging/package-smoke.sh`

Expected: FAIL because no app bundle exists.

- [ ] **Step 3: Implement deterministic packaging**

`Scripts/package-dmg.sh` must build release binaries separately for `arm64` and `x86_64`, combine with `lipo`, assemble the `.app`, copy SwiftPM resource bundles, write version keys, run `codesign --force --deep --sign - --entitlements Packaging/SkillSelector.entitlements`, and create a compressed DMG with `hdiutil`. It must use `set -euo pipefail`, accept a version argument, and recreate only `dist/` and architecture-specific scratch directories.

- [ ] **Step 4: Add license and user-facing release documentation**

Add the unmodified Apache License 2.0 text. README must describe the product boundary, supported Agents, macOS 14 requirement, privacy model, build/test commands, and the exact Gatekeeper procedure for an unnotarized GitHub Release. `docs/releasing.md` must document versioning, tests, packaging, checksum generation, and GitHub Release upload without implying notarization.

- [ ] **Step 5: Build and verify both architectures**

Run: `zsh Scripts/package-dmg.sh 0.1.0 && zsh Tests/Packaging/package-smoke.sh`

Expected: Universal 2 verification, ad-hoc signature verification, sandbox entitlement check, plist lint, and DMG existence all pass.

- [ ] **Step 6: Commit packaging**

```bash
git add Packaging Scripts Tests/Packaging LICENSE README.md docs/releasing.md
git commit -m "build: package ad-hoc signed Universal 2 DMG"
```

### Task 15: Execute End-to-End Acceptance and Security Regression Tests

**Files:**
- Create: `Tests/SkillSelectorCoreTests/AcceptanceTests.swift`
- Create: `docs/test-plan.md`
- Modify: `README.md`

**Interfaces:**
- Consumes: every prior public interface.
- Produces: release evidence for the confirmed product specification.

- [ ] **Step 1: Add a temporary-home acceptance fixture**

Build a fixture with shared global roots, two nested projects, malformed frontmatter, copied Skills, links, unavailable roots, a fake gh executable, a fake npm executable, and fake stdio/HTTP MCP Servers. Keep every path under the test temporary directory.

- [ ] **Step 2: Encode the confirmed acceptance flows**

Test automatic allowlisted discovery, multi-Agent deduplication, project recursion and skips, startup/manual refresh, description precedence, unavailable retention, every file conflict choice, Trash behavior through an injected adapter, link updates, candidate confirmation, read-only command allowlists, MCP approvals, hostile package rejection, local-change warning, and atomic update success.

Run: `swift test --filter AcceptanceTests`

Expected: PASS with no real home-directory, network, Trash, or external-tool access.

- [ ] **Step 3: Perform manual sandbox checks with a disposable home fixture**

Launch the packaged app, authorize only the fixture directory, and verify it cannot browse or write outside that selection. Exercise home check, project add, detail reading, custom description, copy/move/link/trash, fake enrichment, and update review in both localizations. Record exact steps and observed results in `docs/test-plan.md`.

- [ ] **Step 4: Run the complete release gate**

```bash
swift test
swift build
zsh Scripts/package-dmg.sh 0.1.0
zsh Tests/Packaging/package-smoke.sh
git status --short
```

Expected: tests and builds pass, packaging checks pass, and Git status contains only the intended acceptance documentation changes.

- [ ] **Step 5: Commit acceptance evidence**

```bash
git add Tests/SkillSelectorCoreTests/AcceptanceTests.swift docs/test-plan.md README.md
git commit -m "test: verify SkillSelector MVP workflows"
```

## Plan Self-Review

- Product coverage: every section of `docs/product-spec.md` maps to at least one task above.
- Safety coverage: sandbox authorization, path traversal, symlink escape, command injection, untrusted JSON-RPC, output bounds, local modification, Trash, and rollback behavior have explicit tests.
- Type consistency: registry feeds scanner; scanner feeds index; immutable index snapshots feed UI; providers emit `MetadataCandidate`; confirmed candidates create `SkillSource`; updater emits and applies `UpdateProposal`.
- Scope control: no model client, installer, marketplace, editor, watcher, private repository authentication, telemetry, Developer ID, notarization, or third-party package is introduced.
- Repository hygiene: local Agent directories, `需求.md`, build output, research output, app bundles, and DMGs remain ignored.
