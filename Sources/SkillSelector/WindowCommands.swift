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
    /// Posted by the View menu's column-focus items (⌘1 / ⌘2 / ⌘3);
    /// RootView routes keyboard focus to the sidebar / list / detail.
    static let performFocusSidebar = Notification.Name("SkillSelector.performFocusSidebar")
    static let performFocusList = Notification.Name("SkillSelector.performFocusList")
    static let performFocusDetail = Notification.Name("SkillSelector.performFocusDetail")
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

        // View menu: ⌘⌥T flips the appearance like the toolbar toggle;
        // ⌘1/⌘2/⌘3 route keyboard focus to the three columns.
        CommandGroup(after: .toolbar) {
            Button(L10n.string("Toggle Appearance")) {
                NotificationCenter.default.post(name: .performToggleAppearance, object: nil)
            }
            .keyboardShortcut("t", modifiers: [.command, .option])
            Divider()
            Button(L10n.string("Focus Sidebar")) {
                NotificationCenter.default.post(name: .performFocusSidebar, object: nil)
            }
            .keyboardShortcut("1", modifiers: .command)
            Button(L10n.string("Focus List")) {
                NotificationCenter.default.post(name: .performFocusList, object: nil)
            }
            .keyboardShortcut("2", modifiers: .command)
            Button(L10n.string("Focus Detail")) {
                NotificationCenter.default.post(name: .performFocusDetail, object: nil)
            }
            .keyboardShortcut("3", modifiers: .command)
        }
    }
}