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

        // ⌘F focuses the search field. The default Edit menu has no Find
        // group, so the item lands at the end of the text-editing section.
        CommandGroup(after: .textEditing) {
            Button(L10n.string("Search Skills")) {
                NotificationCenter.default.post(name: .focusSearchField, object: nil)
            }
            .keyboardShortcut("f", modifiers: .command)
        }
    }
}