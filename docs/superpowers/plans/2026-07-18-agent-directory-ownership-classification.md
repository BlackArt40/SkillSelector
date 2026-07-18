# Agent Directory Ownership Classification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Classify indexed Skills by the canonical owner of their physical directory while keeping `.agents` directories discoverable, ownerless, and scoped only as home-global or project Skills.

**Architecture:** Add normalized root declarations to `AgentRegistry`; every declaration has an entry filename and zero or one owning Agent ID. Home scanning, project scanning, and file-operation destination validation consume those declarations instead of treating every compatible path in `AgentDefinition` as an association. Existing indexed associations converge on the new model during an accessible refresh.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, XCTest, macOS 14, Swift Package Manager

## Global Constraints

- Agent filters represent directory ownership, not runtime compatibility.
- Each bundled Agent owns only the global roots and project patterns listed in the approved ownership table.
- Global `~/.agents/skills` and `~/.agents/skills-{modeSlug}` are ownerless shared declarations.
- Project `.agents/skills` and `.agents/skills-{modeSlug}` are ownerless shared declarations.
- A missing or empty owned directory does not make its Agent appear in the sidebar.
- A recognized entry file with parse diagnostics still counts as a detected Skill and makes its canonical owner appear.
- Bundled owned and shared declarations take precedence over overlapping custom Agent declarations.
- Shared destinations remain valid for copy, move, and link operations and produce no Agent association.
- Preserve authorization, unavailable-root retention, path identity, confirmation, conflict, Trash, rollback, localization, and accessibility behavior.
- Use Apple frameworks only and keep the macOS 14 minimum deployment target.

---

### Task 1: Model canonical owned and shared declarations

**Files:**
- Modify: `Sources/SkillSelectorCore/Registry/AgentRegistry.swift`
- Modify: `Sources/SkillSelectorCore/Registry/BuiltInAgentRegistry.swift`
- Modify: `Sources/SkillSelector/AppModel.swift:40-105,988-998`
- Test: `Tests/SkillSelectorCoreTests/AgentRegistryTests.swift`

**Interfaces:**
- Produces: `SkillRootDeclaration`, `AgentRegistry.globalDeclarations`, and `AgentRegistry.projectDeclarations`.
- Produces: `AgentRegistry` initializers that retain bundled/shared declarations while custom definitions are merged.
- Consumed by Tasks 2 and 3 for scanning and registered-destination validation.

- [ ] **Step 1: Replace compatibility-path expectations with failing ownership tests**

Update the built-in registry tests to require exact owned roots plus ownerless shared declarations:

```swift
func testBuiltInRegistrySeparatesOwnedAndSharedDeclarations() throws {
    let expectedOwned: [String: (Set<String>, Set<String>)] = [
        "claude-code": (["~/.claude/skills"], [".claude/skills"]),
        "codex": (["~/.codex/skills"], [".codex/skills"]),
        "qoder": (["~/.qoder/skills"], [".qoder/skills"]),
        "codebuddy": (["~/.codebuddy/skills"], [".codebuddy/skills"]),
        "opencode": (["~/.config/opencode/skills", "~/.opencode/skills"], [".opencode/skills"]),
        "cursor": (["~/.cursor/skills"], [".cursor/skills"]),
        "kilo-code": (["~/.kilo/skills"], [".kilo/skills"]),
        "cline": (["~/.cline/skills"], [".cline/skills", ".clinerules/skills"]),
        "roo-code": (["~/.roo/skills", "~/.roo/skills-{modeSlug}"], [".roo/skills", ".roo/skills-{modeSlug}"]),
        "windsurf": (["~/.codeium/windsurf/skills", "/Library/Application Support/Windsurf/skills"], [".windsurf/skills"]),
        "gemini-cli": (["~/.gemini/skills"], [".gemini/skills"]),
        "github-copilot": (["~/.copilot/skills"], [".github/skills"]),
    ]
    let registry = BuiltInAgentRegistry.make()
    let definitions = Dictionary(uniqueKeysWithValues: registry.definitions.map { ($0.id, $0) })

    XCTAssertEqual(Set(definitions.keys), Set(expectedOwned.keys))
    for (id, expected) in expectedOwned {
        let definition = try XCTUnwrap(definitions[id])
        XCTAssertEqual(Set(definition.globalRoots), expected.0, id)
        XCTAssertEqual(Set(definition.projectPatterns), expected.1, id)
    }
    XCTAssertEqual(
        Set(registry.globalDeclarations.filter { $0.agentID == nil }.map(\.value)),
        ["~/.agents/skills", "~/.agents/skills-{modeSlug}"]
    )
    XCTAssertEqual(
        Set(registry.projectDeclarations.filter { $0.agentID == nil }.map(\.value)),
        [".agents/skills", ".agents/skills-{modeSlug}"]
    )
}

func testBundledDeclarationsWinOverCustomOverlap() {
    let base = AgentDefinition(
        id: "codex",
        displayName: "Codex",
        globalRoots: ["~/.codex/skills"],
        projectPatterns: [".codex/skills"]
    )
    let custom = AgentDefinition.custom(
        displayName: "Overlap",
        globalRoots: ["~/.codex/skills", "~/.agents/skills", "~/.mine/skills"],
        projectPatterns: [".codex/skills", ".agents/skills", ".mine/skills"]
    )
    let registry = AgentRegistry(
        definitions: [base],
        customDefinitions: [custom],
        sharedGlobalRoots: ["~/.agents/skills"],
        sharedProjectPatterns: [".agents/skills"]
    )

    XCTAssertEqual(registry.globalDeclarations.first { $0.value == "~/.codex/skills" }?.agentID, "codex")
    XCTAssertNil(registry.globalDeclarations.first { $0.value == "~/.agents/skills" }?.agentID)
    XCTAssertEqual(registry.globalDeclarations.first { $0.value == "~/.mine/skills" }?.agentID, custom.id)
}
```

- [ ] **Step 2: Run registry tests and verify RED**

Run:

```bash
swift test --filter AgentRegistryTests
```

Expected: compilation fails because `globalDeclarations`, `projectDeclarations`, and the shared-root initializer arguments do not exist; old compatibility path assertions also fail once replaced.

- [ ] **Step 3: Add normalized declaration types and precedence**

In `AgentRegistry.swift`, add the declaration value and preserve bundled/custom provenance:

```swift
public struct SkillRootDeclaration: Hashable, Sendable {
    public let value: String
    public let entryFilename: String
    public let agentID: String?

    public init(value: String, entryFilename: String = "SKILL.md", agentID: String?) {
        self.value = value
        self.entryFilename = entryFilename
        self.agentID = agentID
    }
}

public struct AgentRegistry: Sendable {
    public private(set) var definitions: [AgentDefinition]
    public let sharedGlobalRoots: [String]
    public let sharedProjectPatterns: [String]

    private let bundledDefinitions: [AgentDefinition]
    private var customDefinitions: [AgentDefinition]

    public init(
        definitions: [AgentDefinition],
        customDefinitions: [AgentDefinition] = [],
        sharedGlobalRoots: [String] = [],
        sharedProjectPatterns: [String] = []
    ) {
        bundledDefinitions = definitions
        self.customDefinitions = []
        self.definitions = definitions
        self.sharedGlobalRoots = Array(Set(sharedGlobalRoots)).sorted()
        self.sharedProjectPatterns = Array(Set(sharedProjectPatterns)).sorted()
        merge(customDefinitions: customDefinitions)
    }

    public var globalDeclarations: [SkillRootDeclaration] {
        declarations(
            shared: sharedGlobalRoots,
            bundled: bundledDefinitions.flatMap { definition in
                definition.globalRoots.map {
                    SkillRootDeclaration(value: $0, entryFilename: definition.entryFilename, agentID: definition.id)
                }
            },
            custom: customDefinitions.flatMap { definition in
                definition.globalRoots.map {
                    SkillRootDeclaration(value: $0, entryFilename: definition.entryFilename, agentID: definition.id)
                }
            }
        )
    }

    public var projectDeclarations: [SkillRootDeclaration] {
        declarations(
            shared: sharedProjectPatterns,
            bundled: bundledDefinitions.flatMap { definition in
                definition.projectPatterns.map {
                    SkillRootDeclaration(value: $0, entryFilename: definition.entryFilename, agentID: definition.id)
                }
            },
            custom: customDefinitions.flatMap { definition in
                definition.projectPatterns.map {
                    SkillRootDeclaration(value: $0, entryFilename: definition.entryFilename, agentID: definition.id)
                }
            }
        )
    }

    private func declarations(
        shared: [String],
        bundled: [SkillRootDeclaration],
        custom: [SkillRootDeclaration]
    ) -> [SkillRootDeclaration] {
        var claimed = Set<String>()
        var result = [SkillRootDeclaration]()
        for declaration in shared.map({ SkillRootDeclaration(value: $0, agentID: nil) })
            + bundled + custom {
            let key = "\(declaration.value)\u{1f}\(declaration.entryFilename)"
            if claimed.insert(key).inserted { result.append(declaration) }
        }
        return result.sorted {
            $0.value == $1.value ? $0.entryFilename < $1.entryFilename : $0.value < $1.value
        }
    }
}
```

Use these implementations for lookup and custom merging so public definitions remain compatible while declaration precedence stays stable:

```swift
public func definition(id: String) -> AgentDefinition? {
    definitions.first { $0.id == id }
}

public func matchingGlobalRoot(_ root: String) -> [AgentDefinition] {
    let ownerIDs = Set(globalDeclarations.filter { $0.value == root }.compactMap(\.agentID))
    return definitions.filter { ownerIDs.contains($0.id) }
}

public mutating func merge(customDefinitions newDefinitions: [AgentDefinition]) {
    for definition in newDefinitions {
        if let index = customDefinitions.firstIndex(where: { $0.id == definition.id }) {
            customDefinitions[index] = definition
        } else {
            customDefinitions.append(definition)
        }
    }
    definitions = bundledDefinitions
    for definition in customDefinitions {
        if let index = definitions.firstIndex(where: { $0.id == definition.id }) {
            definitions[index] = definition
        } else {
            definitions.append(definition)
        }
    }
}
```

- [ ] **Step 4: Replace the bundled compatibility map with canonical ownership**

In `BuiltInAgentRegistry.make()`, use the exact ownership table from Step 1 and construct the registry with:

```swift
return AgentRegistry(
    definitions: definitions,
    sharedGlobalRoots: ["~/.agents/skills", "~/.agents/skills-{modeSlug}"],
    sharedProjectPatterns: [".agents/skills", ".agents/skills-{modeSlug}"]
)
```

Do not keep `.agents`, `.claude`, or `.codex` compatibility paths under another Agent's definition.

- [ ] **Step 5: Preserve the complete bundled registry when custom Agents reload**

In `AppModel`, replace `builtInAgentDefinitions` with the complete registry:

```swift
private let builtInRegistry: AgentRegistry
```

Initialize and reload with copies so shared declarations survive:

```swift
builtInRegistry = registry

private func reloadAgentDefinitions() throws {
    customAgentDefinitions = try customAgentStore.definitions()
    var effectiveRegistry = builtInRegistry
    effectiveRegistry.merge(customDefinitions: customAgentDefinitions)
    registry = effectiveRegistry
    agentDefinitions = registry.definitions
    refresher.updateRegistry(registry)
}
```

- [ ] **Step 6: Run registry tests and verify GREEN**

Run:

```bash
swift test --filter AgentRegistryTests
swift test --filter AppModelTests
```

Expected: both suites pass with 0 failures; custom persistence behavior remains unchanged.

- [ ] **Step 7: Commit the registry model**

```bash
git add Sources/SkillSelectorCore/Registry/AgentRegistry.swift Sources/SkillSelectorCore/Registry/BuiltInAgentRegistry.swift Sources/SkillSelector/AppModel.swift Tests/SkillSelectorCoreTests/AgentRegistryTests.swift
git commit -m "refactor: separate skill directory ownership"
```

---

### Task 2: Scan ownerless shared and canonical Agent directories

**Files:**
- Modify: `Sources/SkillSelectorCore/Scanning/IndexRefresher.swift:190-285`
- Modify: `Sources/SkillSelectorCore/Scanning/SkillScanner.swift:60-280,470-515`
- Test: `Tests/SkillSelectorCoreTests/IndexRefresherTests.swift`
- Test: `Tests/SkillSelectorCoreTests/SkillScannerTests.swift`

**Interfaces:**
- Consumes: `AgentRegistry.globalDeclarations` and `AgentRegistry.projectDeclarations` from Task 1.
- Produces: `ScannedSkill.agentIDsByRoot` containing one canonical owner or an empty set for each matched root.
- Leaves `ScanRoot.project(registry:)`, `SkillInstallation` identity, and SwiftData schema unchanged.

- [ ] **Step 1: Add failing home ownership and reconciliation tests**

Add an IndexRefresher fixture containing Codex, Claude, and shared Skills, then assert exact ownership:

```swift
func testHomeRefreshUsesCanonicalOwnersAndLeavesSharedAgentsEmpty() async throws {
    let fixture = try RefreshFixture()
    try fixture.writeSkill(at: ".codex/skills/codex-only", name: "codex-only")
    try fixture.writeSkill(at: ".claude/skills/claude-only", name: "claude-only")
    try fixture.writeSkill(at: ".agents/skills/shared", name: "shared")
    let container = try fixture.makeContainer()
    let bookmarks = BookmarkStore(container: container, adapter: FixtureBookmarkAdapter())
    _ = try bookmarks.save(url: fixture.home, kind: .home)
    let index = SkillIndex(container: container)
    let refresher = IndexRefresher(
        registry: BuiltInAgentRegistry.make(),
        bookmarks: bookmarks,
        index: index
    )

    _ = try await refresher.refresh(.startup)
    let skills = Dictionary(uniqueKeysWithValues: try index.skills().map { ($0.name, $0) })

    XCTAssertEqual(skills["codex-only"]?.agentIDs, ["codex"])
    XCTAssertEqual(skills["claude-only"]?.agentIDs, ["claude-code"])
    XCTAssertEqual(skills["shared"]?.agentIDs, [])
    XCTAssertEqual(skills["shared"]?.rootIDs.count, 1)
}
```

Seed a legacy association for the home root, refresh the same accessible path, and assert the stale IDs are replaced by the empty shared set:

```swift
func testAccessibleRefreshRemovesLegacyCompatibilityAssociations() async throws {
    let fixture = try RefreshFixture()
    try fixture.writeSkill(at: ".agents/skills/shared", name: "shared")
    let container = try fixture.makeContainer()
    let bookmarks = BookmarkStore(container: container, adapter: FixtureBookmarkAdapter())
    let homeRoot = try bookmarks.save(url: fixture.home, kind: .home)
    let index = SkillIndex(container: container)
    let sharedURL = fixture.home.appending(path: ".agents/skills/shared")
    try index.apply(report: ScanReport(
        installations: [
            ScannedSkill(
                installation: SkillInstallation(path: sharedURL),
                document: ParsedSkillDocument(name: "shared"),
                agentIDsByRoot: [homeRoot.id: ["cursor", "gemini-cli"]],
                entryFilename: "SKILL.md"
            ),
        ],
        roots: [
            ScannedRoot(id: homeRoot.id, url: fixture.home, availability: .available),
        ]
    ))
    let refresher = IndexRefresher(
        registry: BuiltInAgentRegistry.make(),
        bookmarks: bookmarks,
        index: index
    )

    _ = try await refresher.refresh(.manual)
    let refreshed = try XCTUnwrap(index.skills().first { $0.name == "shared" })

    XCTAssertEqual(refreshed.agentIDs, [])
    XCTAssertEqual(refreshed.rootIDs, [homeRoot.id])
}
```

- [ ] **Step 2: Add failing project ownership tests**

Replace `testSharedRootProducesOneInstallationWithManyAgents` with project-directory ownership coverage:

```swift
func testProjectTraversalUsesFolderOwnerAndLeavesSharedPatternsOwnerless() async throws {
    let fixture = try ScanFixture()
    try fixture.writeSkill(at: ".codex/skills/codex-only", name: "codex-only")
    try fixture.writeSkill(at: ".claude/skills/claude-only", name: "claude-only")
    try fixture.writeSkill(at: ".agents/skills/shared", name: "shared")
    try fixture.writeSkill(at: ".agents/skills-code/shared-mode", name: "shared-mode")

    let report = await SkillScanner().scan([fixture.projectRoot])
    let skills = Dictionary(uniqueKeysWithValues: report.installations.map {
        ($0.document.name ?? "", $0)
    })

    XCTAssertEqual(skills["codex-only"]?.agentIDs, ["codex"])
    XCTAssertEqual(skills["claude-only"]?.agentIDs, ["claude-code"])
    XCTAssertEqual(skills["shared"]?.agentIDs, [])
    XCTAssertEqual(skills["shared-mode"]?.agentIDs, [])
}
```

- [ ] **Step 3: Run focused scan tests and verify RED**

Run:

```bash
swift test --filter IndexRefresherTests/testHomeRefreshUsesCanonicalOwnersAndLeavesSharedAgentsEmpty
swift test --filter SkillScannerTests/testProjectTraversalUsesFolderOwnerAndLeavesSharedPatternsOwnerless
```

Expected: ownership assertions fail because home/project scanning still derives IDs from all matching Agent definitions and does not consume shared declarations.

- [ ] **Step 4: Make home and exact-root plans consume global declarations**

In `IndexRefresher.homeRoots`, iterate `registry.globalDeclarations`. Always create the candidate, and insert an owner only when present:

```swift
for declaration in registry.globalDeclarations {
    for url in try expandedHomeURLs(declaration.value, relativeTo: root.url) {
        let key = "\(url.path)\u{1f}\(declaration.entryFilename)"
        var candidate = candidates[key, default: (url, [], declaration.entryFilename)]
        if let agentID = declaration.agentID { candidate.agents.insert(agentID) }
        candidates[key] = candidate
    }
}
```

Preserve the current probe, unavailable disposition, and template-expansion guards. In `exactRoots`, group matching `globalDeclarations` by entry filename and compact non-nil owner IDs; keep `system`/`custom` fallback only when no declaration matches.

- [ ] **Step 5: Make project matching consume project declarations**

In `SkillScanner`, validate `registry.projectDeclarations` and match `declaration.value` instead of `definition.projectPatterns`. Build each match with zero or one owner:

```swift
private func matchingEntries(
    in skillDirectoryComponents: [String],
    declarations: [SkillRootDeclaration]
) -> [(agentIDs: Set<String>, entryFilename: String)] {
    let parentComponents = Array(skillDirectoryComponents.dropLast())
    let matches = declarations.compactMap { declaration -> (Set<String>, String)? in
        let components = declaration.value.split(separator: "/").map(String.init)
        guard pathSuffix(parentComponents, matches: components) else { return nil }
        return (declaration.agentID.map { Set([$0]) } ?? [], declaration.entryFilename)
    }
    return Dictionary(grouping: matches, by: { $0.1 }).map { entryFilename, values in
        (values.reduce(into: Set<String>()) { $0.formUnion($1.0) }, entryFilename)
    }.sorted { lhs, rhs in
        if lhs.entryFilename == "SKILL.md" { return true }
        if rhs.entryFilename == "SKILL.md" { return false }
        return lhs.entryFilename < rhs.entryFilename
    }
}
```

Rename `validatedDefinitions` to `validatedDeclarations` and include the optional owner only in diagnostics. Keep traversal, symlink authorization, package stopping, parsing, and digest behavior unchanged.

- [ ] **Step 6: Run scan, reconciliation, and index suites**

Run:

```bash
swift test --filter SkillScannerTests
swift test --filter IndexRefresherTests
swift test --filter SkillIndexTests
```

Expected: all three suites pass with 0 failures, including legacy association replacement.

- [ ] **Step 7: Commit discovery ownership**

```bash
git add Sources/SkillSelectorCore/Scanning/IndexRefresher.swift Sources/SkillSelectorCore/Scanning/SkillScanner.swift Tests/SkillSelectorCoreTests/IndexRefresherTests.swift Tests/SkillSelectorCoreTests/SkillScannerTests.swift
git commit -m "fix: classify skills by owning directory"
```

---

### Task 3: Preserve shared ownership in file operations

**Files:**
- Modify: `Sources/SkillSelectorCore/Operations/SkillFileOperator.swift:500-560,710-725`
- Test: `Tests/SkillSelectorCoreTests/SkillFileOperatorTests.swift`

**Interfaces:**
- Consumes: registry declarations from Task 1.
- Produces: `DestinationPlan.agentIDs == []` for shared destinations and one canonical ID for owned destinations.
- Produces: registry fingerprints that change when shared declarations change.

- [ ] **Step 1: Update the fixture and add failing shared-destination tests**

Construct the test registry with Codex-owned and ownerless shared declarations:

```swift
registry = AgentRegistry(
    definitions: [
        AgentDefinition(
            id: "codex",
            displayName: "Codex",
            globalRoots: ["~/.codex/skills"],
            projectPatterns: [".codex/skills"]
        ),
    ],
    sharedGlobalRoots: ["~/.agents/skills"],
    sharedProjectPatterns: [".agents/skills"]
)
```

Add:

```swift
func testSharedDestinationIsRegisteredWithoutAgentAssociation() throws {
    let source = try makeSkill(in: destinationRoot, name: "owned")
    let plan = try makeOperator().plan(
        request(.copy, source: source, destination: sourceRoot)
    )

    XCTAssertEqual(plan.destinationURL, sourceRoot.appending(path: "owned").standardizedFileURL)
    XCTAssertEqual(plan.destinationAgentIDs, [])
    XCTAssertEqual(plan.entryFilename, "SKILL.md")
}
```

Extend the registry-change test by creating a plan, removing `sharedGlobalRoots` in the provider registry, and asserting `.registryChanged` during execution.

- [ ] **Step 2: Run focused file-operation tests and verify RED**

Run:

```bash
swift test --filter SkillFileOperatorTests/testSharedDestinationIsRegisteredWithoutAgentAssociation
swift test --filter SkillFileOperatorTests/testExecutionRejectsSourceAndAuthorizationAndRegistryChanges
```

Expected: the shared destination is rejected or receives an Agent ID, and shared-only registry changes do not alter the fingerprint.

- [ ] **Step 3: Validate destinations through normalized declarations**

In `validateRegisteredRoot`, select declarations instead of definitions:

```swift
let declarations: [SkillRootDeclaration]
switch authorized.kind {
case .home:
    declarations = registry.globalDeclarations.filter {
        matchesHomeRoot(candidate, declaration: $0.value, home: authorized.url)
    }
case .project:
    declarations = registry.projectDeclarations.filter {
        pathSuffix(candidate, relativeTo: authorized.url, matches: $0.value)
    }
case .system, .custom:
    declarations = registry.globalDeclarations.filter {
        guard $0.value.hasPrefix("/") else { return false }
        return URL(fileURLWithPath: $0.value).standardizedFileURL.path == candidate.path
    }
}
```

Filter by requested entry filename as before, then return:

```swift
agentIDs: Array(Set(selected.compactMap(\.agentID))).sorted(),
entryFilename: selected.first?.entryFilename ?? entryFilename
```

Keep the exact `system`/`custom` fallback for authorized roots with no matching declaration.

- [ ] **Step 4: Include normalized declarations in the registry fingerprint**

Append deterministic global and project declaration records to `registryFingerprint`:

```swift
let declarations = registry.globalDeclarations.map {
    "global\u{1f}\($0.value)\u{1f}\($0.entryFilename)\u{1f}\($0.agentID ?? "")"
} + registry.projectDeclarations.map {
    "project\u{1f}\($0.value)\u{1f}\($0.entryFilename)\u{1f}\($0.agentID ?? "")"
}
return (definitionRecords + declarations).sorted().joined(separator: "\u{1e}")
```

- [ ] **Step 5: Run the full file-operation suite and verify GREEN**

Run:

```bash
swift test --filter SkillFileOperatorTests
```

Expected: all file-operation tests pass with 0 failures; shared targets remain authorized and ownerless.

- [ ] **Step 6: Commit file-operation ownership**

```bash
git add Sources/SkillSelectorCore/Operations/SkillFileOperator.swift Tests/SkillSelectorCoreTests/SkillFileOperatorTests.swift
git commit -m "fix: keep shared skill destinations ownerless"
```

---

### Task 4: Verify sidebar visibility and update product documentation

**Files:**
- Modify: `Sources/SkillSelector/Browser/BrowserSidebar.swift:35-54`
- Create: `Tests/SkillSelectorCoreTests/BrowserSidebarTests.swift`
- Modify: `Tests/SkillSelectorCoreTests/SkillQueryTests.swift:25-75`
- Modify: `docs/product-spec.md:26-50`
- Modify: `docs/research/agent-skill-support.md:1-8`

**Interfaces:**
- Consumes: canonical `SkillSnapshot.agentIDs` produced by Task 2.
- Produces: `BrowserSidebar.visibleAgentDefinitions(definitions:detectedAgentIDs:)` for deterministic sidebar visibility testing.
- Does not change `BrowserDestination`, `SkillQuery`, sidebar copy, or icons.

- [ ] **Step 1: Add failing sidebar visibility tests**

Extract the intended behavior through a test-visible static function:

```swift
import XCTest
@testable import SkillSelector
import SkillSelectorCore

final class BrowserSidebarTests: XCTestCase {
    func testSidebarShowsOnlyAgentsWithOwnedSkillAssociations() {
        let definitions = BuiltInAgentRegistry.make().definitions

        XCTAssertTrue(BrowserSidebar.visibleAgentDefinitions(
            definitions: definitions,
            detectedAgentIDs: []
        ).isEmpty)
        XCTAssertEqual(BrowserSidebar.visibleAgentDefinitions(
            definitions: definitions,
            detectedAgentIDs: ["codex"]
        ).map(\.id), ["codex"])
        XCTAssertTrue(BrowserSidebar.visibleAgentDefinitions(
            definitions: definitions,
            detectedAgentIDs: ["shared"]
        ).isEmpty)
    }
}
```

Update query fixtures so `.agents/skills/shared` has an empty Agent ID set and assert it appears under `.global` but in neither Codex nor Claude queries.

- [ ] **Step 2: Run sidebar/query tests and verify RED**

Run:

```bash
swift test --filter BrowserSidebarTests
swift test --filter SkillQueryTests
```

Expected: compilation fails because `visibleAgentDefinitions` does not exist; old shared multi-Agent query expectations fail after replacement.

- [ ] **Step 3: Extract deterministic sidebar filtering**

In `BrowserSidebar`, replace the private filtering body with:

```swift
static func visibleAgentDefinitions(
    definitions: [AgentDefinition],
    detectedAgentIDs: Set<String>
) -> [AgentDefinition] {
    definitions
        .filter { detectedAgentIDs.contains($0.id) && $0.id != "system" && $0.id != "custom" }
        .sorted {
            let lhsName = $0.displayName.lowercased()
            let rhsName = $1.displayName.lowercased()
            return lhsName == rhsName ? $0.id < $1.id : lhsName < rhsName
        }
}

private var agents: [AgentDefinition] {
    Self.visibleAgentDefinitions(
        definitions: definitions,
        detectedAgentIDs: detectedAgentIDs
    )
}
```

Do not infer visibility from directory existence. The scanner remains the source of detected IDs, so missing and empty directories stay hidden while diagnostic Skill records remain visible.

- [ ] **Step 4: Update ownership language in product and research docs**

Replace the product-spec statement that shared `.agents/skills` receives multiple labels with:

```markdown
An absolute installation path identifies a Skill record. Agent filters represent the canonical owner of the containing Agent-specific directory, not every tool that can consume it. Shared `.agents/skills` content has no Agent association: home-level shared content appears under Global Skills, while project-level shared content appears only under that project. Copies at different paths remain separate records.
```

Add this note near the top of the research document:

```markdown
> Compatibility paths document what each tool can read. SkillSelector sidebar classification is based on canonical directory ownership; compatibility entries do not create additional Agent associations.
```

- [ ] **Step 5: Run focused and full automated verification**

Run:

```bash
swift test --filter BrowserSidebarTests
swift test --filter SkillQueryTests
swift test
swift build
git diff --check
```

Expected: focused suites and the full suite pass with 0 failures, the build exits 0, and `git diff --check` prints no errors.

- [ ] **Step 6: Package and smoke-test the application**

Run:

```bash
zsh Scripts/package-dmg.sh 0.1.0
zsh Tests/Packaging/package-smoke.sh 0.1.0
```

Expected: Universal 2 packaging succeeds; signing, App Sandbox entitlement, localization launch probe, and both DMGs verify successfully.

- [ ] **Step 7: Manually verify the approved sidebar behavior**

Using temporary home/project fixtures or a non-production test profile, verify:

- shared-only `.agents/skills` content appears in Global Skills without creating any Agent row;
- Codex shows only `.codex/skills` content;
- Claude Code shows only `.claude/skills` content;
- an Agent with a missing or empty owned directory is absent;
- a recognized Skill with parse diagnostics still makes its canonical owner visible.

- [ ] **Step 8: Commit sidebar and documentation updates**

```bash
git add Sources/SkillSelector/Browser/BrowserSidebar.swift Tests/SkillSelectorCoreTests/BrowserSidebarTests.swift Tests/SkillSelectorCoreTests/SkillQueryTests.swift docs/product-spec.md docs/research/agent-skill-support.md
git commit -m "feat: show agents by owned skill folders"
```
