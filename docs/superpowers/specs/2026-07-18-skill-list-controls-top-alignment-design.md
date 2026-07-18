# Skill List Controls Top Alignment Design

## Goal

Keep the status segmented control and sort menu at the top of the Skill list column in every content state. In particular, an empty or filtered result must match the populated-list header position shown in the approved reference screenshot.

## Current Cause

`SkillListView` uses an outer `VStack` whose empty-state content does not require the available column height. The navigation split-view column can therefore center the complete list view vertically, moving the controls and divider away from the top. A populated `List` expands naturally and masks the issue.

## Chosen Layout

The existing outer list container will fill the available width and height and align itself to the top. The control row remains 42 points high with its current horizontal padding, segmented control, sort menu, and divider. The content region receives the remaining height.

When no Skills match, the existing `ContentUnavailableView` remains centered within the content region below the divider. When Skills exist, the current inset `List` behavior remains unchanged.

## Alternatives Considered

- A top `safeAreaInset` would also pin the controls, but would add overlay/inset behavior that the current list does not need.
- Moving the controls into the window toolbar would change their ownership, spacing, and relationship to the list column, departing from the approved reference.

## Scope

- Change only the Skill list column layout needed to fill its parent and top-align the existing controls.
- Preserve all filter, sorting, search, selection, empty-state, localization, accessibility, and refresh behavior.
- Do not change control styling, labels, dimensions, or the populated row layout.

## Verification

- Add a focused layout regression seam that proves the Skill list root requests all available vertical space with top alignment.
- Run the focused test first and confirm it fails before the production layout change, then passes afterward.
- Run the full Swift test suite and build.
- Launch or render the application in an empty filtered state and confirm the controls align with the populated-list reference at supported column widths.

