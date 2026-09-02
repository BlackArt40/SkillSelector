import AppKit

/// Bag owning the root browser's local NSEvent monitors: click-outside
/// ends search-field editing, and two-finger horizontal swipes drive
/// history navigation. Installed on view-appear, torn down on disappear.
/// Extracted from RootView so input-monitor changes land here.
@MainActor
final class RootEventMonitors {
    private var tokens: [Any] = []

    /// Installs both monitors; a no-op when already installed (a view can
    /// re-appear without a fresh disappear on some transitions).
    func install(onSwipeBack: @escaping () -> Void, onSwipeForward: @escaping () -> Void) {
        guard tokens.isEmpty else { return }

        // Clicking anywhere outside a focused search field ends its
        // editing (caret gone, keyboard detached) — AppKit used to do this
        // for the toolbar field via its own monitors; one window-level
        // monitor now covers every in-column field.
        let endEditing: (NSEvent) -> NSEvent = { event in
            guard let window = event.window,
                  let editor = window.firstResponder as? NSTextView else { return event }
            let editorFrame = editor.convert(editor.bounds, to: nil)
            if !editorFrame.contains(event.locationInWindow) {
                window.makeFirstResponder(nil)
            }
            return event
        }
        if let token = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown], handler: endEditing) {
            tokens.append(token)
        }

        // Two-finger horizontal swipe navigation, mirroring Safari / Mail:
        // swipe right (deltaX > 0) steps back, swipe left steps forward.
        // The `.swipe` event only fires when the system "swipe between
        // pages" gesture is enabled, so it never collides with normal
        // scrolling — the list column has no horizontal scroll to fight.
        let navigate: (NSEvent) -> NSEvent = { event in
            if event.deltaX > 0.5 {
                onSwipeBack()
            } else if event.deltaX < -0.5 {
                onSwipeForward()
            }
            return event
        }
        if let token = NSEvent.addLocalMonitorForEvents(matching: [.swipe], handler: navigate) {
            tokens.append(token)
        }
    }

    /// Tears the monitors down; safe to call when nothing is installed.
    func removeAll() {
        for token in tokens {
            NSEvent.removeMonitor(token)
        }
        tokens = []
    }
}
