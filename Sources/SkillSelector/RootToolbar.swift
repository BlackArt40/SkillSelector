import SkillSelectorCore
import SwiftUI

/// The root window's toolbar buttons, extracted from RootView so toolbar
/// changes land here instead of the root layout file. State (badge count,
/// popover presentation, theme preference) stays in RootView and arrives
/// as bindings/values.
///
/// Redesign: the topbar actions are `.tool-btn` text buttons — 30 px tall,
/// muted surface, hairline border, hard offset shadow, lifting 1 px on
/// hover and sinking 1 px on press.

/// Shared `.tool-btn` treatment: 30 px tall text button on a muted surface
/// with a 1 px border and the hard offset shadow. Button labels are `Text`s
/// carrying the -0.05 em tracking themselves — View-level `.kerning` is
/// macOS 13.3+ and the deployment target is macOS 12.
private struct ToolButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AppTheme.body(12, weight: .bold))
            .foregroundStyle(AppTheme.foreground)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(AppTheme.surfaceMuted)
            .overlay(Rectangle().stroke(AppTheme.border, lineWidth: 1))
            .contentShape(Rectangle())
            .pressLiftMotion(isPressed: configuration.isPressed)
    }
}

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
            HStack(spacing: 6) {
                if isRunning {
                    ProgressView()
                        .controlSize(.mini)
                }
                Text(L10n.string("Toolbar Refresh"))
                    .kerning(-0.6)
            }
        }
        .buttonStyle(ToolButtonStyle())
        .disabled(isRunning)
        .help(L10n.string("Refresh Now"))
        .accessibilityLabel(L10n.string("Refresh Now"))
    }
}

/// The toolbar's history entry point. The popover itself is hosted by
/// RootView's main content — a popover anchored inside a ToolbarItem does
/// not present reliably on macOS 12 (binding flips, nothing renders), so
/// both entry points (this button and the refresh banner) share the one
/// presentation in the main view hierarchy.
struct RootHistoryButton: View {
    @Binding var unreadChangeCount: Int
    @Binding var isShowingRefreshHistory: Bool

    var body: some View {
        Button {
            unreadChangeCount = 0
            isShowingRefreshHistory = true
        } label: {
            HStack(spacing: 6) {
                Text(L10n.string("Toolbar History"))
                    .kerning(-0.6)
                if unreadChangeCount > 0 {
                    Text(verbatim: "\(min(unreadChangeCount, 99))")
                        .font(AppTheme.body(10, weight: .bold))
                        .kerning(-0.5)
                        .foregroundStyle(AppTheme.primaryButtonForeground)
                        .padding(.horizontal, 4)
                        .frame(minWidth: 16, minHeight: 16)
                        .background(AppTheme.primaryButtonBackground)
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(ToolButtonStyle())
        .help(L10n.string("Change History"))
        .accessibilityLabel(
            unreadChangeCount > 0
                ? L10n.string("Change History") + " \(unreadChangeCount)"
                : L10n.string("Change History")
        )
    }
}

/// Theme flip as a `.tool-btn` text button: the label names the mode you
/// would switch to ("Dark" in light mode, "Light" in dark), matching the
/// HTML prototype's topbar. Presentation only — the flip itself is shared
/// with the ⌘⌥T menu item via RootView.
struct RootThemeToggleButton: View {
    let isDark: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            Text(L10n.string(isDark ? "Toolbar Light" : "Toolbar Dark"))
                .kerning(-0.6)
        }
        .buttonStyle(ToolButtonStyle())
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

/// Settings entry point in the window toolbar (top-right), a `.tool-btn`
/// text button like the other toolbar actions.
struct RootSettingsButton: View {
    var body: some View {
        Button {
            NotificationCenter.default.post(name: .openSettingsWindow, object: nil)
        } label: {
            Text(L10n.string("Toolbar Settings"))
                .kerning(-0.6)
        }
        .buttonStyle(ToolButtonStyle())
        .help(L10n.string("Open Settings"))
        .accessibilityLabel(L10n.string("Open Settings"))
    }
}
