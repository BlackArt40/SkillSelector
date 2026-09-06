import AppKit
import OSLog
import SwiftUI

/// The Settings window: a single AppKit window hosting the SwiftUI pane.
/// SwiftUI's `Settings` scene requires macOS 13; a plain NSWindow is
/// identical on every supported system and keeps the app fork-free.
@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()

    private static let log = Logger(subsystem: "com.SkillSelector", category: "SettingsWindow")

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

    /// Presents a file panel as a sheet on the settings window. Panels must
    /// not `runModal()` from this window: on macOS 12 the modal panel never
    /// surfaces (no window, no error — the acceptance run's export defect),
    /// while sheets present reliably. Covers both panel types since
    /// NSOpenPanel inherits NSSavePanel's sheet API.
    func presentAsSheet(_ panel: NSSavePanel, completion: @escaping (URL?) -> Void) {
        Self.log.info("presentAsSheet: hasWindow=\(self.window != nil, privacy: .public)")
        guard let window else {
            // Settings window not up (nothing hosts the sheet): fall back
            // to the modal loop rather than dropping the request.
            Self.log.info("presentAsSheet: runModal fallback")
            completion(panel.runModal() == .OK ? panel.url : nil)
            return
        }
        // Defer out of SwiftUI's button-action call frame: presenting a
        // file panel synchronously inside the action never surfaces it on
        // macOS 12 (the D1 defect), while a deferred sheet presents.
        DispatchQueue.main.async {
            Self.log.info("presentAsSheet: beginSheetModal (deferred)")
            panel.beginSheetModal(for: window) { response in
                Self.log.info("presentAsSheet: completed \(response.rawValue, privacy: .public)")
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
