import SkillSelectorCore
import SwiftUI

/// The root window's toolbar buttons, extracted from RootView so toolbar
/// changes land here instead of the root layout file. State (badge count,
/// popover presentation, theme preference) stays in RootView and arrives
/// as bindings/values.

/// Explicit refresh: rescans every authorized root now. While a refresh
/// runs the button shows progress and ignores clicks (the in-flight task
/// is awaited either way).
struct RootRefreshButton: View {
    let isRunning: Bool
    let onRefresh: () -> Void

    var body: some View {
        Button {
            onRefresh()
        } label: {
            if isRunning {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 30, height: 30)
            } else {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 14))
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
        }
        .buttonStyle(.borderless)
        .disabled(isRunning)
        .help(L10n.string("Refresh Now"))
        .accessibilityLabel(L10n.string("Refresh Now"))
    }
}

/// Recent refresh changes, anchored to the history button. Opening the
/// popover clears the badge (spec §4: zeroed once viewed).
struct RootHistoryButton: View {
    @Binding var unreadChangeCount: Int
    @Binding var isShowingRefreshHistory: Bool
    let history: [RefreshChangeEntry]

    var body: some View {
        Button {
            unreadChangeCount = 0
            isShowingRefreshHistory = true
        } label: {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 14))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
                .overlay(alignment: .topTrailing) {
                    if unreadChangeCount > 0 {
                        Text(verbatim: "\(min(unreadChangeCount, 99))")
                            .font(AppTheme.body(9, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(AppTheme.danger, in: Capsule())
                            .offset(x: 4, y: -4)
                            .accessibilityHidden(true)
                    }
                }
        }
        .buttonStyle(.borderless)
        .help(L10n.string("Change History"))
        .accessibilityLabel(
            unreadChangeCount > 0
                ? L10n.string("Change History") + " \(unreadChangeCount)"
                : L10n.string("Change History")
        )
        .popover(isPresented: $isShowingRefreshHistory, arrowEdge: .bottom) {
            RefreshHistoryPopover(history: history)
        }
    }
}

/// `.themeBtn`: moon in light mode, sun in dark mode; toggles between the
/// two like the HTML prototype's `ss.theme` flip. Presentation only — the
/// flip itself is shared with the ⌘⌥T menu item via RootView.
struct RootThemeToggleButton: View {
    let isDark: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            Image(systemName: isDark ? "sun.max" : "moon")
                .font(.system(size: 14))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(
            isDark
                ? L10n.string("Switch to Light Mode")
                : L10n.string("Switch to Dark Mode")
        )
        .accessibilityLabel(
            isDark
                ? L10n.string("Switch to Light Mode")
                : L10n.string("Switch to Dark Mode")
        )
    }
}

/// Settings entry point in the window toolbar (top-right), replacing the
/// old sidebar footer link. Icon-only, matching the other toolbar actions.
struct RootSettingsButton: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button {
            openSettings()
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 14))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(L10n.string("Open Settings"))
        .accessibilityLabel(L10n.string("Open Settings"))
    }
}
