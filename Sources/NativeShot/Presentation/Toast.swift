import AppKit
import SwiftUI

/// Short non-modal status message near the bottom of the active screen, announced to VoiceOver.
@MainActor
enum Toast {
    private static var panel: NSPanel?
    private static var hideTask: Task<Void, Never>?

    static func show(_ message: String, symbol: String) {
        panel?.orderOut(nil)
        let host = NSHostingView.fixed(
            Label(message, systemImage: symbol)
                .font(.callout.weight(.medium))
                .padding(.horizontal, 14).padding(.vertical, 9)
                .panelBackground(Capsule())
                .padding(1))
        let size = host.fittingSize
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        p.contentView = host
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let f = screen?.visibleFrame {
            p.setFrameOrigin(NSPoint(x: f.midX - p.frame.width / 2, y: f.minY + 48))
        }
        p.orderFrontRegardless()
        panel = p
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(2.2))
            if !Task.isCancelled { p.orderOut(nil) }
        }
    }
}

/// Cancellable capture countdown (CAP-007). Throws CancellationError on Esc.
@MainActor
enum Countdown {
    static func run(seconds: Int) async throws {
        guard seconds > 0 else { return }
        let panel = CountdownPanel()
        defer { panel.orderOut(nil) }
        panel.present()
        for remaining in stride(from: seconds, to: 0, by: -1) {
            panel.set(remaining)
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                 userInfo: [.announcement: String(remaining)])
            try await Task.sleep(for: .seconds(1))
            if panel.cancelled { throw CancellationError() }
        }
    }
}

final class CountdownPanel: NSPanel {
    private(set) var cancelled = false
    private let label = NSTextField(labelWithString: "")

    @MainActor
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 120, height: 120), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let bg = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 120, height: 120))
        bg.material = .hudWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 24
        if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            bg.state = .inactive
            bg.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            bg.layer?.borderWidth = 1
            bg.layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.6).cgColor
        }
        label.font = .monospacedDigitSystemFont(ofSize: 56, weight: .semibold)
        label.alignment = .center
        label.frame = NSRect(x: 0, y: 26, width: 120, height: 68)
        bg.addSubview(label)
        contentView = bg
        setAccessibilityHelp(String(localized: "Pulsa Escape para cancelar"))
    }

    override var canBecomeKey: Bool { true }

    @MainActor
    func present() {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let f = screen?.frame { setFrameOrigin(NSPoint(x: f.midX - 60, y: f.midY - 60)) }
        makeKeyAndOrderFront(nil)
    }

    @MainActor
    func set(_ n: Int) { label.stringValue = String(n) }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { cancelled = true; orderOut(nil) } else { super.keyDown(with: event) }
    }
}
