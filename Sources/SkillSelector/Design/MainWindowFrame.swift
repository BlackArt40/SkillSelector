import AppKit
import SwiftUI

/// Restores (or seeds) the main window's frame across launches.
///
/// NSWindow's built-in frame autosave is unusable under SwiftUI's WindowGroup:
/// the AppKit bridge assigns the window its own autosave name, never persists
/// resizes under ours, and `setFrameUsingName("MainWindow")` therefore always
/// finds nothing and resets to the seed size (found by the macOS 12 real-device
/// smoke). This representable owns the whole cycle explicitly instead: restore
/// once when the view attaches, save on live-resize end, window move, and
/// window close — all under one fixed key with a self-consistent format.
struct MainWindowFrame: NSViewRepresentable {
    static let autosaveKey = "SkillSelector.mainWindowFrame"

    func makeNSView(context: Context) -> NSView {
        MainFrameView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Self-contained frame persistence: attaches observers exactly once per
/// window and cleans them up when the view leaves the hierarchy.
private final class MainFrameView: NSView {
    private var observers: [NSObjectProtocol] = []

    override func viewDidMoveToWindow {
        super.viewDidMoveToWindow()
        guard window != nil else {
            removeObservers()
            return
        }
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        for name in [NSWindow.didEndLiveResizeNotification, NSWindow.didMoveNotification, NSWindow.willCloseNotification] {
            observers.append(center.addObserver(
                forName: name,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.saveFrame()
            })
        }
        restoreOrSeed()
    }

    private func removeObservers() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
    }

    deinit {
        removeObservers()
    }

    private func restoreOrSeed() {
        guard let window else { return }
        let saved = UserDefaults.standard.string(forKey: MainWindowFrame.autosaveKey)
            .map { NSRectFromString($0) }
        if let saved, saved.width >= 400, saved.height >= 300 {
            window.setFrame(saved, display: false)
        } else {
            window.setFrame(NSRect(x: 0, y: 0, width: 1440, height: 900), display: false)
            window.center()
        }
    }

    private func saveFrame() {
        guard let window, isVisible else { return }
        let frame = window.frame
        UserDefaults.standard.set(
            "\(frame.origin.x) \(frame.origin.y) \(frame.size.width) \(frame.size.height)",
            forKey: MainWindowFrame.autosaveKey
        )
    }
}
