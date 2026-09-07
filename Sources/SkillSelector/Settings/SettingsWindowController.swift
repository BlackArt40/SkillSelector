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

    /// Presents a file panel as a sheet on the settings window. Covers both
    /// panel types since NSOpenPanel inherits NSSavePanel's sheet API. (The
    /// old "panels never present from this window" defect was the sandbox
    /// missing user-selected.read-write, not the window.)
    func presentAsSheet(_ panel: NSSavePanel, completion: @escaping (URL?) -> Void) {
        guard let window else {
            completion(panel.runModal() == .OK ? panel.url : nil)
            return
        }
        // One runloop turn: export-after-view fires while the diagnostics
        // viewer sheet is still detaching from this window, and attaching
        // the panel in the same turn can drop it.
        DispatchQueue.main.async {
            panel.beginSheetModal(for: window) { response in
                completion(response == .OK ? panel.url : nil)
            }
        }
    }
}

extension Notification.Name {
    /// Posted when something asks for the Settings window (toolbar gear,
    /// ⌘, menu item, re-authorization banner). RootView shows the window
    /// via `SettingsWindowController` and forwards any `SettingsTab`
    /// payload carried as `object` to the panes inside it.
    static let openSettingsWindow = Notification.Name("SkillSelectorOpenSettingsWindow")
}
