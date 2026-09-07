import AppKit
import SwiftUI

/// The Settings window: a single AppKit window hosting the SwiftUI pane.
/// SwiftUI's `Settings` scene requires macOS 13; a plain NSWindow is
/// identical on every supported system and keeps the app fork-free.
@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()

    private var window: NSWindow?
    private var hostingModel: AppModel?

    private init() {}

    func show(model: AppModel) {
        hostingModel = model
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let content = SettingsView()
            .environmentObject(model)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.string("Settings")
        window.contentView = NSHostingView(rootView: content)
        window.center()
        window.setFrameAutosaveName("SettingsWindow")
        window.isReleasedWhenClosed = false
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

extension Notification.Name {
    /// Posted when something asks for the Settings window (toolbar gear,
    /// ⌘, menu item, re-authorization banner). RootView shows the window
    /// via `SettingsWindowController` and forwards any `SettingsTab`
    /// payload carried as `object` to the panes inside it.
    static let openSettingsWindow = Notification.Name("SkillSelectorOpenSettingsWindow")
}
