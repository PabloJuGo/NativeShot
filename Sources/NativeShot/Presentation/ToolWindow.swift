import AppKit
import SwiftUI

/// Standard titled window with its own content, one per call (OCR result, export manager). Kept alive
/// until closed. Titled windows are fine with a plain NSHostingView; only borderless panels need `fixed`.
@MainActor
enum ToolWindow {
    private static var open: [ObjectIdentifier: NSWindow] = [:]

    @discardableResult
    static func show<V: View>(title: String, size: NSSize, resizable: Bool = true, @ViewBuilder content: () -> V) -> NSWindow {
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if resizable { style.insert(.resizable) }
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        w.title = title
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: content())
        w.center()
        let id = ObjectIdentifier(w)
        open[id] = w
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            MainActor.assumeIsolated { open[id] = nil }
        }
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
        return w
    }
}
