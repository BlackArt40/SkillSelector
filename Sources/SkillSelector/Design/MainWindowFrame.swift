import AppKit
import SwiftUI

/// Restores (or seeds) the main window's frame: replaces the macOS 13-only
/// scene-level default sizing with an autosave name available everywhere.
struct MainWindowFrame: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            if !window.setFrameUsingName("MainWindow") {
                window.setFrame(NSRect(x: 0, y: 0, width: 1440, height: 900), display: false)
                window.center()
            }
            window.setFrameAutosaveName("MainWindow")
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
