import AppKit
import SwiftUI

/// UI-12 host: one standard resizable window, reused between openings.
@MainActor
final class LibraryWindowController {
    static let shared = LibraryWindowController()
    private var window: NSWindow?

    func show(app: AppController) {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 600),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = String(localized: "Biblioteca")
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: LibraryView(model: LibraryModel(library: app.library, app: app)))
            w.setFrameAutosaveName("NativeShotLibrary")
            if !w.setFrameUsingName("NativeShotLibrary") { w.center() }
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
