import AppKit
import SwiftUI

struct SettingsWindowTitle: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> NSView {
        let view = WindowTitleView()
        view.title = title
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? WindowTitleView else { return }
        view.title = title
    }
}

private final class WindowTitleView: NSView {
    var title = "" {
        didSet { window?.title = title }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.title = title
    }
}
