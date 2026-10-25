import AppKit

/// Image pinned above normal windows (PIN-001..003). Drag to move, pinch or ⌘+/⌘- to zoom,
/// context menu for opacity, arrows to nudge, Esc or ⌘W to close. A pin can be locked (clicks pass through
/// it); the way out is always the menu bar item «Desbloquear imágenes fijadas», because a locked pin cannot be clicked.
@MainActor
final class PinController {
    private var pins: [PinPanel] = []

    func pin(_ image: CGImage, near point: NSPoint? = nil) {
        let panel = PinPanel(image: image) { [weak self] p in self?.remember(p); self?.pins.removeAll { $0 === p } }
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main!
        let f = screen.visibleFrame
        var size = panel.frame.size
        let fit = min(f.width * 0.6 / size.width, f.height * 0.6 / size.height, 1)
        size = NSSize(width: size.width * fit, height: size.height * fit)
        // PIN-002: new pins start where the last one on this display was left.
        let c = Self.saved(for: screen).map { NSPoint(x: f.minX + $0.x * f.width, y: f.minY + $0.y * f.height) } ?? NSPoint(x: f.midX, y: f.midY)
        var origin = NSPoint(x: c.x - size.width / 2 + CGFloat(pins.count * 24), y: c.y - size.height / 2 - CGFloat(pins.count * 24))
        origin.x = min(max(origin.x, f.minX), max(f.minX, f.maxX - size.width))
        origin.y = min(max(origin.y, f.minY), max(f.minY, f.maxY - size.height))
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        pins.append(panel)
        panel.makeKeyAndOrderFront(nil)
    }

    func setLocked(_ on: Bool) { pins.forEach { $0.locked = on } }

    // MARK: Position per display

    private static let positionsKey = "pinPositions"

    private static func id(of screen: NSScreen) -> String? {
        guard let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let u = CGDisplayCreateUUIDFromDisplayID(n)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, u) as String
    }

    /// Centre of the pin as a fraction of the display's visible frame.
    private static func saved(for screen: NSScreen) -> NSPoint? {
        guard let id = id(of: screen),
              let v = (UserDefaults.standard.dictionary(forKey: positionsKey) as? [String: [Double]])?[id], v.count == 2 else { return nil }
        return NSPoint(x: v[0], y: v[1])
    }

    private func remember(_ p: PinPanel) {
        let mid = NSPoint(x: p.frame.midX, y: p.frame.midY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mid) }), let id = Self.id(of: screen) else { return }
        let f = screen.visibleFrame
        var all = (UserDefaults.standard.dictionary(forKey: Self.positionsKey) as? [String: [Double]]) ?? [:]
        all[id] = [(mid.x - f.minX) / f.width, (mid.y - f.minY) / f.height]
        UserDefaults.standard.set(all, forKey: Self.positionsKey)
    }

    func closeAll() { pins.forEach { $0.close() } }
    var count: Int { pins.count }
}

final class PinPanel: NSPanel {
    private let aspect: CGFloat
    private let onClose: (PinPanel) -> Void

    @MainActor
    init(image: CGImage, onClose: @escaping (PinPanel) -> Void) {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let size = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        aspect = size.width / max(size.height, 1)
        self.onClose = onClose
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel, .resizable],
                   backing: .buffered, defer: false)
        level = .floating
        isMovableByWindowBackground = true
        hasShadow = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentAspectRatio = size
        let view = NSImageView(image: NSImage(cgImage: image, size: size))
        view.imageScaling = .scaleProportionallyUpOrDown
        view.setAccessibilityLabel(String(localized: "Imagen fijada"))
        contentView = view
        view.menu = makeMenu()
        // The context menu is pointer-only; VoiceOver gets the same actions from the rotor.
        view.setAccessibilityCustomActions(
            [100, 50].map { pct in
                NSAccessibilityCustomAction(name: String(localized: "Opacidad \(pct) %")) { [weak self] in self?.alphaValue = CGFloat(pct) / 100; return true }
            } + [NSAccessibilityCustomAction(name: String(localized: "Bloquear (los clics la atraviesan)")) { [weak self] in self?.locked = true; return true },
               NSAccessibilityCustomAction(name: String(localized: "Cerrar")) { [weak self] in self?.close(); return true }])
    }

    override var canBecomeKey: Bool { true }

    @MainActor
    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        for pct in [100, 75, 50, 25] {
            let item = NSMenuItem(title: String(localized: "Opacidad \(pct) %"), action: #selector(setOpacity(_:)), keyEquivalent: "")
            item.tag = pct
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let lock = NSMenuItem(title: String(localized: "Bloquear (los clics la atraviesan)"), action: #selector(lockPin), keyEquivalent: "")
        lock.target = self
        menu.addItem(lock)
        let close = NSMenuItem(title: String(localized: "Cerrar"), action: #selector(performClose(_:)), keyEquivalent: "w")
        close.target = self
        menu.addItem(close)
        return menu
    }

    /// Click-through. Once locked the pin ignores the pointer, so the exit lives in the menu bar (and the closePins shortcut).
    var locked = false {
        didSet {
            ignoresMouseEvents = locked
            if locked { Toast.show(String(localized: "Imagen bloqueada. Desbloquéala desde el menú de NativeShot."), symbol: "lock") }
        }
    }

    @objc private func lockPin() { locked = true }

    @objc private func setOpacity(_ sender: NSMenuItem) { alphaValue = CGFloat(sender.tag) / 100 }

    override func performClose(_ sender: Any?) { close() }

    override func close() {
        super.close()
        onClose(self)
    }

    // ⌘ combinations arrive as key equivalents and never reach keyDown.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command) else { return super.performKeyEquivalent(with: event) }
        switch event.charactersIgnoringModifiers {
        case "w": close()
        case "=", "+": zoom(by: 1.1)
        case "-": zoom(by: 1 / 1.1)
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }

    override func keyDown(with event: NSEvent) {
        // Arrows nudge the pin (⇧ for 1 pt), so it can be placed without the pointer.
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 1 : 10
        switch event.keyCode {
        case 53: close()
        case 123: nudge(-step, 0)
        case 124: nudge(step, 0)
        case 125: nudge(0, -step)
        case 126: nudge(0, step)
        default: super.keyDown(with: event)
        }
    }

    private func nudge(_ dx: CGFloat, _ dy: CGFloat) { setFrameOrigin(NSPoint(x: frame.origin.x + dx, y: frame.origin.y + dy)) }

    override func magnify(with event: NSEvent) { zoom(by: 1 + event.magnification) }

    private func zoom(by factor: CGFloat) {
        let f = frame
        let w = min(max(f.width * factor, 60), 4000)
        let h = w / aspect
        setFrame(NSRect(x: f.midX - w / 2, y: f.midY - h / 2, width: w, height: h), display: true)
    }
}
