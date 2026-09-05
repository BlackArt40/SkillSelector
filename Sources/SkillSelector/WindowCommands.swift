import Foundation
import SwiftUI

// MARK: - Menu command notifications

extension Notification.Name {
    /// Posted by the Go menu's Back item (⌘[); RootView applies the restore.
    static let performGoBack = Notification.Name("SkillSelector.performGoBack")
    /// Posted by the Go menu's Forward item (⌘]); RootView applies the restore.
    static let performGoForward = Notification.Name("SkillSelector.performGoForward")
    /// Posted by the Find item (⌘F); RootView focuses its search field.
    static let focusSearchField = Notification.Name("SkillSelector.focusSearchField")
    /// Posted by the File menu's Refresh item (⌘R); RootView runs a scan.
    static let performRefresh = Notification.Name("SkillSelector.performRefresh")
    /// Posted by the File menu's Reveal item (⌘↩); RootView reveals the
    /// selected Skill in Finder.
    static let performRevealSelection = Notification.Name("SkillSelector.performRevealSelection")
    /// Posted by the File menu's Open item (⌘O); RootView opens the selected
    /// Skill in the default editor.
    static let performOpenSelection = Notification.Name("SkillSelector.performOpenSelection")
    /// Posted by the View menu's Appearance item (⌘⌥T); RootView flips the
    /// light/dark mode.
    static let performToggleAppearance = Notification.Name("SkillSelector.performToggleAppearance")
    /// Posted when the toolbar search field gained keyboard focus by being
    /// clicked (AppKit path); RootView syncs its FocusState.
    static let searchFocusStarted = Notification.Name("SkillSelector.searchFocusStarted")
    /// Posted when an outside click resigned the toolbar search field;
    /// RootView clears its FocusState (ends the search session, per AC-15).
    static let searchFocusDismissed = Notification.Name("SkillSelector.searchFocusDismissed")
}

/// The app's menu bar commands. Back/forward use the standard ⌘[ / ⌘] and
/// search focus is ⌘F — registered as real menu items (so they are
/// discoverable in the menu bar) instead of invisible focus buttons inside
/// the view. The browser window owns the resulting navigation state, so the
/// items dispatch through notifications and RootView applies them — the same
/// routing the re-authorization banner already uses to open a Settings tab.
struct WindowCommands: Commands {
    var body: some Commands {
        // Single-window app: the navigation history model is app-wide, so
        // the standard New Window (⌘N) item is removed. WindowGroup still
        // provides the launch window without multi-window semantics.
        CommandGroup(replacing: .newItem) {}

        CommandMenu(L10n.string("Go")) {
            Button(L10n.string("Go Back")) {
                NotificationCenter.default.post(name: .performGoBack, object: nil)
            }
            .keyboardShortcut("[", modifiers: .command)

            Button(L10n.string("Go Forward")) {
                NotificationCenter.default.post(name: .performGoForward, object: nil)
            }
            .keyboardShortcut("]", modifiers: .command)
        }

        // Replaces the default appSettings item: the SwiftUI Settings scene
        // is gone (it requires macOS 13), so ⌘, asks RootView to show the
        // plain AppKit settings window instead (SettingsWindowController).
        CommandGroup(replacing: .appSettings) {
            Button(L10n.string("Settings")) {
                NotificationCenter.default.post(name: .openSettingsWindow, object: nil)
            }
            .keyboardShortcut(KeyEquivalent(","), modifiers: .command)
        }

        // ⌘F focuses the search field. The default Edit menu has no Find
        // group, so the item lands at the end of the text-editing section.
        CommandGroup(after: .textEditing) {
            Button(L10n.string("Search Skills")) {
                NotificationCenter.default.post(name: .focusSearchField, object: nil)
            }
            .keyboardShortcut("f", modifiers: .command)
        }

        // The File menu carries the only two file-touching actions plus
        // refresh: ⌘R rescans, ⌘↩ reveals the selected Skill's directory in
        // Finder, and ⌘O opens its SKILL.md in the default editor.
        CommandGroup(after: .saveItem) {
            Divider()
            Button(L10n.string("Refresh Now")) {
                NotificationCenter.default.post(name: .performRefresh, object: nil)
            }
            .keyboardShortcut("r", modifiers: .command)
            Divider()
            Button(L10n.string("Reveal Skill Document in Finder")) {
                NotificationCenter.default.post(name: .performRevealSelection, object: nil)
            }
            .keyboardShortcut(.return, modifiers: .command)
            Button(L10n.string("Open in Default Editor")) {
                NotificationCenter.default.post(name: .performOpenSelection, object: nil)
            }
            .keyboardShortcut("o", modifiers: .command)
        }

        // View menu: ⌘⌥T flips the appearance like the toolbar toggle.
        CommandGroup(after: .toolbar) {
            Button(L10n.string("Toggle Appearance")) {
                NotificationCenter.default.post(name: .performToggleAppearance, object: nil)
            }
            .keyboardShortcut("t", modifiers: [.command, .option])
        }
    }
}
/// Routes menu-bar command notifications (⌘F / ⌘[ / ⌘] / ⌘R / ⌘↩ / ⌘O /
/// ⌘⌥T) into RootView's handlers. Bundled as one modifier so the root
/// view's body chain stays type-checkable. Lives beside the command
/// senders above — menu item and handler change for the same reason.
struct WindowCommandHandling: ViewModifier {
    let onGoBack: () -> Void
    let onGoForward: () -> Void
    let onFocusSearch: () -> Void
    let onRefresh: () -> Void
    let onRevealSelection: () -> Void
    let onOpenSelection: () -> Void
    let onToggleAppearance: () -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .performGoBack)) { _ in onGoBack() }
            .onReceive(NotificationCenter.default.publisher(for: .performGoForward)) { _ in onGoForward() }
            .onReceive(NotificationCenter.default.publisher(for: .focusSearchField)) { _ in onFocusSearch() }
            .onReceive(NotificationCenter.default.publisher(for: .performRefresh)) { _ in onRefresh() }
            .onReceive(NotificationCenter.default.publisher(for: .performRevealSelection)) { _ in onRevealSelection() }
            .onReceive(NotificationCenter.default.publisher(for: .performOpenSelection)) { _ in onOpenSelection() }
            .onReceive(NotificationCenter.default.publisher(for: .performToggleAppearance)) { _ in onToggleAppearance() }
    }
}
