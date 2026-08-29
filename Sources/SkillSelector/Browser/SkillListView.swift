import SkillSelectorCore
import SwiftUI

/// The middle `.list-col` column: a 46 pt header with title and count, and
/// the scrollable list of `.skill-row`s (400 pt wide in the design).
struct SkillListView: View {
    /// Primary selection (last clicked row); drives the detail pane.
    let selection: SkillSelection?
    @Binding var searchText: String
    @Binding var sort: SkillQuery.Sort
    /// Drives the in-column search field's focus (⌘F and the search
    /// session history live in RootView).
    @FocusState.Binding var searchFocused: Bool

    let title: String
    let skills: [SkillSnapshot]
    let allSkillCount: Int
    let hasAuthorization: Bool
    let hasActiveFilters: Bool
    let refreshState: RefreshState
    let agentNamesByID: [String: String]
    let onClearFilters: () -> Void
    let onImportProject: () -> Void
    let onImportHome: () -> Void
    var onRevealInFinder: ((SkillSnapshot) -> Void)?
    var onOpenInEditor: ((SkillSnapshot) -> Void)?
    /// Plain click and keyboard navigation: single selection.
    var onPrimarySelect: ((String) -> Void)?
    /// Arrow-key selection moves without recording navigation history.
    var onArrowSelect: ((String) -> Void)?

    @State private var sortHovering = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle()
                .fill(AppTheme.borderSoft)
                .frame(height: 1)
            if !skills.isEmpty || hasActiveFilters {
                searchBar
            }
            content
        }
        .background(AppTheme.background)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle(title)
    }

    /// In-column search field — same design as the marketplace's, bound
    /// to RootView's query text (name, description, or indexed body).
    private var searchBar: some View {
        ListSearchBar(placeholderKey: "Search Names Or Descriptions", text: $searchText)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(verbatim: title)
                .font(AppTheme.display(17, weight: .semibold))
                .foregroundStyle(AppTheme.foreground)
                .lineLimit(1)
            Text(verbatim: String.localizedStringWithFormat(
                L10n.string("Skill List Count"), skills.count
            ))
            .font(AppTheme.body(12))
            .foregroundStyle(AppTheme.muted)
            Spacer(minLength: 8)
            sortMenu
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .frame(height: 46)
        .background(AppTheme.background)
    }

    /// `.sortBtn` (design tool button): 30×30 with a border-soft hover
    /// fill. The menu lists the three orders directly — no intermediate
    /// submenu — with a checkmark on the active one.
    private var sortMenu: some View {
        Menu {
            sortOption(L10n.string("Default Order"), value: .default)
            sortOption(L10n.string("Name"), value: .name)
            sortOption(L10n.string("Path"), value: .path)
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 14))
                .foregroundStyle(AppTheme.foregroundSecondary)
                .frame(width: 30, height: 30)
                .background {
                    if sortHovering {
                        RoundedRectangle(cornerRadius: 7)
                            .fill(AppTheme.borderSoft)
                    }
                }
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .onHover { hovering in
            sortHovering = hovering
        }
        .help(L10n.string("Sort Skills"))
        .accessibilityLabel(L10n.string("Sort Skills"))
    }

    private func sortOption(_ title: String, value: SkillQuery.Sort) -> some View {
        Button {
            sort = value
        } label: {
            HStack {
                Text(verbatim: title)
                Spacer(minLength: 12)
                if sort == value {
                    Image(systemName: "checkmark")
                        .fontWeight(.semibold)
                }
            }
        }
        .accessibilityAddTraits(sort == value ? .isSelected : [])
    }

    @ViewBuilder
    private var content: some View {
        if case .failed(let message) = refreshState {
            listEmpty(
                title: L10n.string("Refresh Failed"),
                message: message,
                actionTitle: nil,
                action: nil
            )
        } else if skills.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(skills) { skill in
                        SkillRow(
                            skill: skill,
                            agentNamesByID: agentNamesByID,
                            isActive: selection?.path == skill.path,
                            onSelect: { onPrimarySelect?(skill.path) },
                            onRevealInFinder: onRevealInFinder,
                            onOpenInEditor: onOpenInEditor
                        )
                        .padding(.horizontal, 8)
                    }
                }
                .padding(.vertical, 8)
            }
            .onKeyPress(keys: [.downArrow]) { _ in moveSelection(1) }
            .onKeyPress(keys: [.upArrow]) { _ in moveSelection(-1) }
        }
    }

    /// Moves the selection within the visible list; with nothing selected,
    /// Arrow Down picks the first row and Arrow Up the last. History is not
    /// recorded for keyboard moves — only explicit clicks open a detail.
    private func moveSelection(_ delta: Int) -> KeyPress.Result {
        guard !skills.isEmpty else { return .ignored }
        let current = selection.flatMap { selected in
            skills.firstIndex { $0.path == selected.path }
        }
        let next: Int
        if let current {
            next = min(max(current + delta, 0), skills.count - 1)
        } else {
            next = delta > 0 ? 0 : skills.count - 1
        }
        (onArrowSelect ?? onPrimarySelect)?(skills[next].path)
        return .handled
    }

    @ViewBuilder
    private var emptyState: some View {
        if hasActiveFilters {
            listEmpty(
                title: L10n.string("No Matching Skills"),
                message: L10n.string("No Matching Skills Description"),
                actionTitle: L10n.string("Clear Search"),
                action: onClearFilters
            )
        } else if !hasAuthorization {
            listEmpty(
                title: L10n.string("No Skills in Scope"),
                message: L10n.string("No Skills in Scope Description"),
                actionTitle: nil,
                action: nil
            )
            .overlay(alignment: .bottom) {
                importButtons
                    .padding(.bottom, 32)
            }
        } else if allSkillCount == 0 {
            listEmpty(
                title: L10n.string("No Skills in Scope"),
                message: L10n.string("No Skills in Scope Description"),
                actionTitle: nil,
                action: nil
            )
            .overlay(alignment: .bottom) {
                importButtons
                    .padding(.bottom, 32)
            }
        } else {
            listEmpty(
                title: L10n.string("No Skills in Scope"),
                message: L10n.string("No Skills in Scope Description"),
                actionTitle: L10n.string("Clear Search"),
                action: onClearFilters
            )
        }
    }

    private var importButtons: some View {
        VStack(spacing: 10) {
            textButton(L10n.string("Import Project Directory"), action: onImportProject)
            textButton(L10n.string("Import System Directory"), action: onImportHome)
        }
    }

    private func textButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(verbatim: title)
                .font(AppTheme.body(13, weight: .medium))
                .foregroundStyle(AppTheme.accent)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(HoverTextButtonStyle())
        .accessibilityLabel(title)
    }

    /// `.list-empty` centered state with the design's typography.
    private func listEmpty(
        title: String,
        message: String,
        actionTitle: String?,
        action: (() -> Void)?
    ) -> some View {
        VStack(spacing: 8) {
            Spacer(minLength: 48)
            Text(verbatim: title)
                .font(AppTheme.display(17, weight: .semibold))
                .foregroundStyle(AppTheme.foreground)
                .lineLimit(1)
            Text(verbatim: message)
                .font(AppTheme.body(13))
                .foregroundStyle(AppTheme.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)
            if let actionTitle, let action {
                textButton(actionTitle, action: action)
                    .padding(.top, 8)
            }
            Spacer(minLength: 48)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// `.text-btn:hover` — faint accent fill.
private struct HoverTextButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                if isHovering && !configuration.isPressed {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(AppTheme.accentTintFaint)
                }
            }
            .onHover { hovering in
                isHovering = hovering
            }
    }
}
