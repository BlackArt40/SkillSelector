# Skill List Controls Top Alignment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep the status filter and sort controls at the top of the Skill list column when the result is empty, matching their position when rows are present.

**Architecture:** Preserve the existing `SkillListView` hierarchy and make its root `VStack` consume the full navigation-column size with top alignment. Use a focused source-contract test for the declarative SwiftUI modifier because the project has no UI snapshot dependency and this one-line layout invariant should not introduce a production-only abstraction.

**Tech Stack:** Swift 6, SwiftUI, XCTest, macOS 14, Swift Package Manager

## Global Constraints

- The control row remains 42 points high with its current horizontal padding, segmented control, sort menu, and divider.
- The existing `ContentUnavailableView` remains centered within the content region below the divider.
- Preserve all filter, sorting, search, selection, empty-state, localization, accessibility, and refresh behavior.
- Do not change control styling, labels, dimensions, or populated row layout.
- Use Apple frameworks only; add no package dependency.

---

### Task 1: Fill and top-align the Skill list column

**Files:**
- Create: `Tests/SkillSelectorCoreTests/SkillListLayoutTests.swift`
- Modify: `Sources/SkillSelector/Browser/SkillListView.swift:17-25`

**Interfaces:**
- Consumes: the existing `SkillListView.body` root `VStack` and the test target's existing dependency on the `SkillSelector` executable target.
- Produces: a root layout that requests all available width and height using `Alignment.top`; no public API changes.

- [ ] **Step 1: Write the failing layout contract test**

Create `Tests/SkillSelectorCoreTests/SkillListLayoutTests.swift`:

```swift
import Foundation
import XCTest

final class SkillListLayoutTests: XCTestCase {
    func testSkillListRootFillsColumnAndPinsControlsToTop() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/SkillSelector/Browser/SkillListView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(
            source.contains(".frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)"),
            "SkillListView must fill the navigation column so its controls stay pinned to the top"
        )
    }
}
```

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
swift test --filter SkillListLayoutTests/testSkillListRootFillsColumnAndPinsControlsToTop
```

Expected: FAIL at `XCTAssertTrue` because `SkillListView` does not yet contain the full-size, top-aligned frame modifier.

- [ ] **Step 3: Add the minimal root layout modifier**

In `SkillListView.body`, keep the existing hierarchy and append the frame modifier directly after the root `VStack`:

```swift
        VStack(spacing: 0) {
            controls
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle(L10n.string("Skills"))
```

- [ ] **Step 4: Run the focused test and verify GREEN**

Run:

```bash
swift test --filter SkillListLayoutTests/testSkillListRootFillsColumnAndPinsControlsToTop
```

Expected: PASS, 1 test with 0 failures.

- [ ] **Step 5: Run full automated verification**

Run:

```bash
swift test
swift build
git diff --check
```

Expected: all 242 tests pass, build exits 0, and `git diff --check` prints no errors.

- [ ] **Step 6: Verify the empty-state layout visually**

Launch the app at a middle-column width between 280 and 380 points. Select a status filter that produces no matches and confirm:

- the segmented status control and sort menu remain at the same top position as the populated state;
- the divider remains directly below the 42-point control row;
- the empty-state message stays centered in the remaining region below the divider;
- changing back to a populated filter does not shift the controls.

- [ ] **Step 7: Commit the implementation**

```bash
git add Tests/SkillSelectorCoreTests/SkillListLayoutTests.swift Sources/SkillSelector/Browser/SkillListView.swift
git commit -m "fix: pin skill list controls to top"
```

