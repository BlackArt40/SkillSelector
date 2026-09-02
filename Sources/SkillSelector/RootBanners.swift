import SkillSelectorCore
import SwiftUI

/// Top-of-window banners for the root browser, extracted from RootView so
/// banner changes land here. Presentation only — state and action routing
/// stay in RootView.

/// Refresh-completed banner: one line per change class. Dismissible; it
/// reappears on the next refresh that changes something.
struct RootRefreshCompleteBanner: View {
    let summary: RefreshSummary
    let onViewChanges: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        Banner(
            tone: .success,
            icon: "checkmark.circle.fill",
            text: String.localizedStringWithFormat(
                L10n.string("Refresh Complete Banner"),
                summary.added, summary.changed, summary.removed
            ),
            actionTitle: L10n.string("View Changes"),
            action: onViewChanges,
            onDismiss: onDismiss
        )
    }
}

/// Shown while any authorized root's bookmark no longer resolves. With a
/// single broken root the button goes straight to the authorization panel
/// (pre-selected to the lost directory) so one click in the panel restores
/// access; with several, it opens the Settings directories pane to manage
/// them together. Sandboxed apps cannot silently re-acquire a broken
/// bookmark — macOS requires the user to re-pick the directory in the open
/// panel, so RootView routes the action.
struct RootAuthorizationBanner: View {
    let onReauthorize: () -> Void

    var body: some View {
        Banner(
            tone: .warning,
            icon: "exclamationmark.triangle.fill",
            text: L10n.string("Authorization Lost Banner"),
            actionTitle: L10n.string("Re-authorize…"),
            action: onReauthorize,
            actionHelp: L10n.string("Re-authorize Directory")
        )
    }
}
