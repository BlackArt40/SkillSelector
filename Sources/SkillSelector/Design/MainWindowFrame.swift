import AppKit
import SwiftUI

/// Restores (or seeds) the main window's frame across launches.
///
/// NSWindow's built-in frame autosave is unusable under SwiftUI's WindowGroup:
/// the AppKit bridge assigns the window its own autosave name and never
/// persists resizes under ours. Hosting the persistence through an NSView in
/// `.background` also proved unreliable — the representable's view never
/// reliably joined the window's responder chain on macOS 12 (the macOS 12
/// real-device smoke caught both failures). So this helper owns the cycle
/// globally instead: one `MainWindowFrameCoordinator` observes every window
/// the app opens, restores the saved frame onto the first main window, and
/// saves on resize/move/close. `MainWindowFrame` is just the mount point that
/// activates the coordinator from the view tree.
struct MainWindowFrame: ViewModifier {
    func body(content: Content) -> some View {
        content.onAppear {
            MainWindowFrameCoordinator.shared.activate()
        }
    }
}

extension View {
    /// Activates main-window frame persistence (see `MainWindowFrame`).
    func mainWindowFramePersistence() -> some View {
        modifier(MainWindowFrame())
    }
}

/// Owns frame save/restore for the app's main window. Activated once.
@MainActor
final class MainWindowFrameCoordinator {
    static let autosaveKey = "SkillSelector.mainWindowFrame"
    static let shared = MainWindowFrameCoordinator()

    private var observers: [NSObjectProtocol] = []
    private var restoredWindowID: CGWindowID?

    private init() {}

    func activate() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        // Observe app-wide (object: nil): the main window is whichever
        // WindowGroup window exists when the first restore lands.
        for name in [NSWindow.didEndLiveResizeNotification, NSWindow.didMoveNotification, NSWindow.willCloseNotification, NSWindow.didBecomeMainNotification] {
            observers.append(center.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let window = notification.object as? NSWindow else { return }
                    if name == NSWindow.didBecomeMainNotification {
                        self?.restoreIfNeeded(on: window)
                    } else {
                        self?.saveFrame(of: window)
                    }
                }
            })
        }
    }

    private func restoreIfNeeded(on window: NSWindow) {
        guard restoredWindowID == nil else { return }
        restoredWindowID = window.windowNumber
        let saved = UserDefaults.standard.string(forKey: Self.autosaveKey)
            .map { NSRectFromString($0) }
        if let saved, saved.width >= 400, saved.height >= 300 {
            window.setFrame(saved, display: false)
        } else {
            window.setFrame(NSRect(x: 0, y: 0, width: 1440, height: 900), display: false)
            window.center()
        }
    }

    private func saveFrame(of window: NSWindow) {
        // One tracked window: skip the Settings singleton (its own autosave)
        // by remembering which window we restored onto.
        guard let id = restoredWindowID, window.windowNumber == id else { return }
        let frame = window.frame
        UserDefaults.standard.set(
            "\(frame.origin.x) \(frame.origin.y) \(frame.size.width) \(frame.size.height)",
            forKey: Self.autosaveKey
        )
    }
}
