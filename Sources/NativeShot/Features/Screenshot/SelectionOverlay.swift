import AppKit
import NativeShotKit

/// What the user picked on screen. Rects are Quartz global coordinates (points).
enum SelectionResult {
    case region(CGRect, display: CGDirectDisplayID)
    case window(CGWindowID, frame: CGRect)
    case display(CGDirectDisplayID)
}

struct SelectedRegion {
    let rect: CGRect
    let display: CGDirectDisplayID
}

/// Full-screen selection overlay, one borderless panel per display (CAP-001/002/003/004).
/// Non-activating so cancelling leaves the previously active app focused.
@MainActor
final class SelectionOverlay {
    enum Mode: Equatable { case region, window, display }

    private var panels: [OverlayPanel] = []
    private var modeBar: ModeBarPanel?
    private(set) var mode: Mode
    private let purpose: CaptureMode
    /// Freeze, loupe and multi-region belong to still captures only (not scroll, OCR or recording).
    let screenshot: Bool
    private var completion: ((SelectionResult?) -> Void)?
    private var windows: [WindowCandidate] = []

    // Region editing (CAP-001/006/011), all in Quartz global points.
    private var editor = RegionEditor()
    private var editorDisplay: CGDirectDisplayID?
    private var startedWithCommand = false
    /// ⌘ adds regions only once pressed after the overlay opened: the default shortcuts (⌃⌥⌘N) leave it held.
    var commandArmed = !NSEvent.modifierFlags.contains(.command)
    /// Regions set aside with ⌘ before the active one; the result delivered to `begin` is the last region.
    private(set) var confirmed: [SelectedRegion] = []
    /// Regions picked before the one in the result, in selection order (CAP-011).
    private(set) var extraRegions: [SelectedRegion] = []
    var activeRegion: SelectedRegion? {
        guard let r = editor.rect, let d = editorDisplay else { return nil }
        return SelectedRegion(rect: r, display: d)
    }

    // Freeze frame and loupe (CAP-009/010): one full-display snapshot per screen, taken with the overlay hidden.
    private var snapshots: [CGDirectDisplayID: CGImage] = [:]
    private var snapshotting = false
    private(set) var frozen = false

    private var defaults: UserDefaults { .standard }
    var adjusts: Bool { defaults.bool(forKey: Prefs.adjustRegion) }
    var freezeWanted: Bool { screenshot && defaults.bool(forKey: Prefs.freezeScreen) }
    var loupeWanted: Bool { screenshot && defaults.bool(forKey: Prefs.showLoupe) }
    var aspect: AspectPreset { AspectPreset(rawValue: defaults.string(forKey: Prefs.aspectPreset) ?? "") ?? .free }

    init(mode: Mode, purpose: CaptureMode = .region, screenshot: Bool = false) {
        self.mode = mode
        self.purpose = purpose
        self.screenshot = screenshot
    }

    func snapshot(of display: CGDirectDisplayID) -> CGImage? { snapshots[display] }

    /// Snapshots the confirmed capture must be cut from when the screen was frozen.
    var frozenSnapshots: [CGDirectDisplayID: CGImage] { frozen ? snapshots : [:] }

    func begin(completion: @escaping (SelectionResult?) -> Void) {
        self.completion = completion
        windows = WindowCandidate.onScreen()
        if freezeWanted {
            // The overlay appears only once the frozen picture exists, so it never ends up inside it.
            Task {
                await takeSnapshots()
                if self.completion != nil { show() }
            }
        } else {
            show()
            if loupeWanted { Task { await takeSnapshots() } }
        }
    }

    private func show() {
        for screen in NSScreen.screens {
            let panel = OverlayPanel(screen: screen, overlay: self)
            panels.append(panel)
            panel.orderFrontRegardless()
        }
        // Key focus goes to the panel under the pointer so Esc/Space work immediately.
        let mouse = NSEvent.mouseLocation
        (panels.first { $0.frame.contains(mouse) } ?? panels.first)?.makeKey()
        if purpose != .textRecognition {
            let bar = ModeBarPanel(overlay: self)
            bar.show(on: NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main!)
            modeBar = bar
        }
        refresh()
        Signposts.end("shortcut-to-overlay")
    }

    private func takeSnapshots() async {
        guard !snapshotting else { return }
        snapshotting = true
        defer { snapshotting = false }
        for screen in NSScreen.screens where snapshots[screen.displayID] == nil {
            // skippingNotch: false keeps the picture the same geometry as the display it is drawn over.
            if let img = try? await ScreenCaptureAdapter.capture(display: screen.displayID, rect: nil, showsCursor: false, skippingNotch: false) {
                snapshots[screen.displayID] = img
            }
        }
        frozen = freezeWanted && !snapshots.isEmpty
        refresh()
    }

    /// The mode bar's menu changed a preference that affects what is drawn or captured.
    func optionsChanged() {
        if freezeWanted || loupeWanted, snapshots.isEmpty { Task { await takeSnapshots() } }
        frozen = freezeWanted && !snapshots.isEmpty
        refresh()
    }

    func setMode(_ m: Mode) {
        mode = m
        modeBar?.update(mode: m)
        refresh()
    }

    /// CAP-004: scroll, OCR and recording are flows of their own; close the selector and delegate to them.
    func switchTo(_ action: ShortcutAction) {
        finish(nil)
        AppController.shared.perform(action)
    }

    func refresh() {
        panels.forEach { $0.selectionView.needsDisplay = true }
        let scale = activeRegion.flatMap { r in NSScreen.screens.first { $0.displayID == r.display }?.backingScaleFactor } ?? 1
        modeBar?.update(selection: editor.rect?.size, scale: scale)
    }

    /// Topmost window under a Quartz global point.
    func window(at quartzPoint: CGPoint) -> WindowCandidate? {
        windows.first { $0.frame.contains(quartzPoint) }
    }

    // MARK: Region editing

    func pointerDown(_ q: CGPoint, display: CGDirectDisplayID, command: Bool, clickCount: Int) {
        if clickCount >= 2, let r = editor.rect, r.contains(q) { confirm(); return }
        startedWithCommand = command && commandArmed && screenshot
        if startedWithCommand, let active = activeRegion, active.rect.width >= 2, active.rect.height >= 2 {
            confirmed.append(active)
            editor.set(nil)
        }
        if editorDisplay != display { editor.set(nil); editorDisplay = display }
        editor.begin(at: q, tolerance: 8, bounds: CGDisplayBounds(display), forceCreate: startedWithCommand)
        refresh()
    }

    func pointerDragged(_ q: CGPoint, shift: Bool) {
        guard let d = editorDisplay else { return }
        // Shift = square; otherwise the preset chosen in the mode bar (CAP-006).
        editor.update(to: q, ratio: shift ? 1 : aspect.ratio, bounds: CGDisplayBounds(d))
        refresh()
    }

    func pointerUp() {
        editor.end()
        guard editor.rect != nil else { refresh(); return }
        // Like the system tool, release confirms — unless the user wants to adjust or is collecting regions.
        if adjusts || startedWithCommand || !confirmed.isEmpty { announceSelection(); refresh() } else { confirm() }
    }

    /// Moves the active region with the arrow keys (the keyboard route for what the mouse does).
    func nudge(dx: CGFloat, dy: CGFloat) {
        guard let r = editor.rect, let d = editorDisplay else { return }
        let b = CGDisplayBounds(d)
        let o = CGPoint(x: min(max(r.minX + dx, b.minX), b.maxX - r.width), y: min(max(r.minY + dy, b.minY), b.maxY - r.height))
        editor.set(CGRect(origin: o, size: r.size))
        refresh()
    }

    /// CAP-006: exact size typed in the mode bar. `pixels` converts with the display's backing scale.
    func applySize(_ size: CGSize, pixels: Bool) {
        guard let r = editor.rect, let d = editorDisplay else { return }
        let scale = pixels ? (NSScreen.screens.first { $0.displayID == d }?.backingScaleFactor ?? 1) : 1
        guard let n = RegionEditor.resized(r, toSize: CGSize(width: size.width / scale, height: size.height / scale), bounds: CGDisplayBounds(d)) else { return }
        editor.set(n)
        refresh()
        announceSelection()
        // The mode bar had key focus for typing; give it back so Return/Esc act on the selection again.
        panels.first { $0.selectionView.screenDisplayID == d }?.makeKey()
    }

    /// Backspace: drops the last region set aside with ⌘, or the active one if none.
    func removeLast() {
        if editor.rect != nil { editor.set(nil) } else { _ = confirmed.popLast() }
        refresh()
    }

    private func announceSelection() {
        guard let r = editor.rect else { return }
        let text = String(localized: "Región de \(Int(r.width)) por \(Int(r.height)) puntos")
        panels.forEach { $0.selectionView.setAccessibilityValue(text) }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.low.rawValue])
    }

    /// Return / double-click: hand over the active region (and any set aside with ⌘).
    func confirm() {
        var regions = confirmed
        if let a = activeRegion { regions.append(a) }
        regions = regions.filter { $0.rect.width >= 2 && $0.rect.height >= 2 }
        guard let last = regions.last else { return }
        extraRegions = Array(regions.dropLast())
        finish(.region(last.rect, display: last.display))
    }

    func finish(_ result: SelectionResult?) {
        guard let completion else { return }
        self.completion = nil
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
        modeBar?.orderOut(nil)
        modeBar = nil
        completion(result)
    }
}

final class OverlayPanel: NSPanel {
    let selectionView: SelectionView

    @MainActor
    init(screen: NSScreen, overlay: SelectionOverlay) {
        selectionView = SelectionView(screen: screen, overlay: overlay)
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        contentView = selectionView
        setAccessibilityLabel(String(localized: "Selección de captura"))
    }

    override var canBecomeKey: Bool { true }
}

final class SelectionView: NSView {
    private weak var overlay: SelectionOverlay?
    private let screenRef: NSScreen
    private var hover: NSPoint?
    private var tracking: NSTrackingArea?

    var screenDisplayID: CGDirectDisplayID { screenRef.displayID }

    @MainActor
    init(screen: NSScreen, overlay: SelectionOverlay) {
        self.screenRef = screen
        self.overlay = overlay
        super.init(frame: NSRect(origin: .zero, size: screen.frame.size))
        // Highlight the window under the pointer right away, not only after the first mouse move.
        let m = NSEvent.mouseLocation
        if screen.frame.contains(m) { hover = NSPoint(x: m.x - screen.frame.minX, y: m.y - screen.frame.minY) }
        setAccessibilityRole(.layoutArea)
        setAccessibilityHelp(String(localized: "Arrastra para seleccionar; arrastra los puntos para ajustar y Retorno confirma. Mantén ⌘ para añadir otra región y Mayúsculas para un cuadrado. Espacio alterna ventana. R, W y D eligen región, ventana o pantalla. Escape cancela."))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect, .mouseEnteredAndExited], owner: self)
        addTrackingArea(t)
        tracking = t
        super.updateTrackingAreas()
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    // MARK: Coordinates

    private func quartz(_ p: NSPoint) -> CGPoint {
        let global = NSPoint(x: p.x + screenRef.frame.minX, y: p.y + screenRef.frame.minY)
        return CGPoint(x: global.x, y: NSScreen.primaryHeight - global.y)
    }

    private func localRect(fromQuartz r: CGRect) -> NSRect {
        let appKit = DisplayGeometry.flip(r, primaryHeight: NSScreen.primaryHeight)
        return appKit.offsetBy(dx: -screenRef.frame.minX, dy: -screenRef.frame.minY)
    }

    // MARK: Events

    override func mouseMoved(with event: NSEvent) {
        hover = convert(event.locationInWindow, from: nil)
        MainActor.assumeIsolated { overlay?.refresh() }
    }

    override func mouseExited(with event: NSEvent) {
        hover = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        let p = convert(event.locationInWindow, from: nil)
        hover = p
        MainActor.assumeIsolated {
            guard let overlay else { return }
            switch overlay.mode {
            case .region:
                overlay.pointerDown(quartz(p), display: screenRef.displayID, command: event.modifierFlags.contains(.command), clickCount: event.clickCount)
            case .window:
                if let w = overlay.window(at: quartz(p)) { overlay.finish(.window(w.id, frame: w.frame)) }
            case .display:
                overlay.finish(.display(screenRef.displayID))
            }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        hover = p
        MainActor.assumeIsolated {
            guard overlay?.mode == .region else { return }
            overlay?.pointerDragged(quartz(p), shift: event.modifierFlags.contains(.shift))
        }
    }

    override func flagsChanged(with event: NSEvent) {
        if !event.modifierFlags.contains(.command) { MainActor.assumeIsolated { overlay?.commandArmed = true } }
        super.flagsChanged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        MainActor.assumeIsolated { if overlay?.mode == .region { overlay?.pointerUp() } }
    }

    override func keyDown(with event: NSEvent) {
        MainActor.assumeIsolated {
            guard let overlay else { return }
            let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            switch event.keyCode {
            case 53: overlay.finish(nil) // Esc
            case 49: overlay.setMode(overlay.mode == .window ? .region : .window) // Space
            case 36, 76: // Return confirms the adjusted region, or the display in display mode
                if overlay.mode == .display { overlay.finish(.display(screenRef.displayID)) } else if overlay.mode == .region { overlay.confirm() }
            case 51: if overlay.mode == .region { overlay.removeLast() } // Delete
            case 123: overlay.nudge(dx: -step, dy: 0)
            case 124: overlay.nudge(dx: step, dy: 0)
            case 125: overlay.nudge(dx: 0, dy: step)
            case 126: overlay.nudge(dx: 0, dy: -step)
            default:
                // The mode bar cannot take key focus, so modes also get plain letter keys.
                switch event.charactersIgnoringModifiers?.lowercased() {
                case "r": overlay.setMode(.region)
                case "w": overlay.setMode(.window)
                case "d": overlay.setMode(.display)
                default: super.keyDown(with: event)
                }
            }
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let (mode, frozenImage, regions, active, loupe) = MainActor.assumeIsolated {
            guard let o = overlay else { return (Mode.region, CGImage?.none, [SelectedRegion](), SelectedRegion?.none, false) }
            let id = screenRef.displayID
            return (o.mode, o.frozen ? o.snapshot(of: id) : nil, o.confirmed.filter { $0.display == id }, o.activeRegion.flatMap { $0.display == id ? $0 : nil }, o.loupeWanted)
        }
        if let img = frozenImage, let ctx = NSGraphicsContext.current?.cgContext { ctx.draw(img, in: bounds) }

        let dim = NSColor.black.withAlphaComponent(NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 0.5 : 0.3)
        dim.setFill()
        bounds.fill()

        switch mode {
        case .region:
            for (i, r) in regions.enumerated() { drawRegion(localRect(fromQuartz: r.rect), index: i + 1, active: false) }
            if let a = active, a.rect.width >= 1, a.rect.height >= 1 {
                drawRegion(localRect(fromQuartz: a.rect), index: regions.isEmpty ? nil : regions.count + 1, active: true)
            } else if regions.isEmpty, let h = hover {
                drawCrosshair(at: h)
            }
        case .window:
            if let h = hover, let w = MainActor.assumeIsolated({ overlay?.window(at: quartz(h)) }) { drawHighlight(localRect(fromQuartz: w.frame)) }
        case .display:
            if hover != nil, hover.map(bounds.contains) == true {
                // CAP-019: preview of what the full-display capture will keep when the notch is excluded.
                let inset = UserDefaults.standard.bool(forKey: Prefs.excludeNotch) ? screenRef.safeAreaInsets.top : 0
                drawHighlight(NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - inset))
            }
        }

        if mode == .region, loupe, let h = hover, let img = MainActor.assumeIsolated({ overlay?.snapshot(of: screenRef.displayID) }) { drawLoupe(at: h, image: img) }
        if frozenImage != nil { drawLabel(String(localized: "Pantalla congelada · no es contenido en vivo"), at: NSPoint(x: 16, y: bounds.height - 44)) }
    }

    private typealias Mode = SelectionOverlay.Mode

    private func drawHighlight(_ r: NSRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.25).setFill()
        r.fill(using: .sourceOver)
        let border = NSBezierPath(rect: r.insetBy(dx: 1.5, dy: 1.5))
        border.lineWidth = 3
        NSColor.controlAccentColor.setStroke()
        border.stroke()
    }

    private func drawRegion(_ r: NSRect, index: Int?, active: Bool) {
        // Cut the selection out of the dimmed layer; the frozen picture (if any) shows through undimmed.
        if let ctx = NSGraphicsContext.current?.cgContext, let img = MainActor.assumeIsolated({ overlay?.frozen == true ? overlay?.snapshot(of: screenRef.displayID) : nil }) {
            ctx.saveGState(); ctx.clip(to: r); ctx.draw(img, in: bounds); ctx.restoreGState()
        } else {
            NSColor.clear.setFill()
            r.fill(using: .copy)
        }
        let border = NSBezierPath(rect: r.insetBy(dx: -0.5, dy: -0.5))
        border.lineWidth = 1
        (active ? NSColor.white : NSColor.white.withAlphaComponent(0.7)).setStroke()
        border.stroke()
        drawSizeLabel(for: r, index: index)
        if active { drawHandles(for: r) }
    }

    private func drawHandles(for r: NSRect) {
        // The editor works y-down; this view is y-up, so mirror the handle positions rather than the geometry.
        let flipped = CGRect(x: r.minX, y: -r.maxY, width: r.width, height: r.height)
        for h in RegionHandle.allCases {
            let p = h.point(in: flipped)
            let box = NSRect(x: p.x - 4, y: -p.y - 4, width: 8, height: 8)
            let path = NSBezierPath(roundedRect: box, xRadius: 2, yRadius: 2)
            NSColor.white.setFill(); path.fill()
            NSColor.black.withAlphaComponent(0.6).setStroke(); path.lineWidth = 1; path.stroke()
        }
    }

    private func drawCrosshair(at p: NSPoint) {
        NSColor.white.withAlphaComponent(0.6).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1
        path.move(to: NSPoint(x: 0, y: p.y.rounded() + 0.5)); path.line(to: NSPoint(x: bounds.width, y: p.y.rounded() + 0.5))
        path.move(to: NSPoint(x: p.x.rounded() + 0.5, y: 0)); path.line(to: NSPoint(x: p.x.rounded() + 0.5, y: bounds.height))
        path.stroke()
        let q = quartz(p)
        drawLabel("\(Int(q.x)), \(Int(q.y))", at: NSPoint(x: p.x + 12, y: p.y - 28))
    }

    /// CAP-009: pixel-perfect magnifier next to the pointer, from the snapshot (never from the live screen, so it cannot capture itself).
    private func drawLoupe(at p: NSPoint, image: CGImage) {
        let side = 15, cell: CGFloat = 8, size = CGFloat(side) * cell
        let k = CGFloat(image.width) / bounds.width
        let px = Int(p.x * k), py = Int((bounds.height - p.y) * k)
        let src = Loupe.sourceRect(centerX: px, y: py, side: side, imageWidth: image.width, imageHeight: image.height)
        guard let crop = image.cropping(to: src), let ctx = NSGraphicsContext.current?.cgContext else { return }
        var box = NSRect(x: p.x + 24, y: p.y - 24 - size - 26, width: size, height: size)
        if box.maxX > bounds.maxX - 8 { box.origin.x = p.x - 24 - size }
        if box.minY < 8 { box.origin.y = p.y + 24 + 26 }
        let shape = NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8)
        ctx.saveGState()
        shape.addClip()
        ctx.interpolationQuality = .none
        ctx.draw(crop, in: box)
        ctx.restoreGState()
        NSColor.white.setStroke(); shape.lineWidth = 2; shape.stroke()
        let cx = CGFloat(px - Int(src.minX)), cy = CGFloat(Int(src.maxY) - 1 - py) // centre cell, y-up
        let centre = NSBezierPath(rect: NSRect(x: box.minX + cx * cell, y: box.minY + cy * cell, width: cell, height: cell))
        NSColor.black.setStroke(); centre.lineWidth = 1.5; centre.stroke()
        let q = quartz(p)
        var label = "\(Int(q.x)), \(Int(q.y))"
        if let c = pixel(of: crop, x: px - Int(src.minX), y: py - Int(src.minY)) { label += "  " + Loupe.hex(r: c.r, g: c.g, b: c.b) }
        drawLabel(label, at: NSPoint(x: box.minX, y: box.minY - 26))
    }

    /// sRGB value of one pixel (x, y from the top-left) of `image`.
    private func pixel(of image: CGImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8)? {
        var rgba = [UInt8](repeating: 0, count: 4)
        let ok = rgba.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
            return true
        }
        return ok ? (rgba[0], rgba[1], rgba[2]) : nil
    }

    private func drawSizeLabel(for r: NSRect, index: Int?) {
        let scale = screenRef.backingScaleFactor
        let px = DisplayGeometry.pixelSize(of: r, scale: scale)
        let y = r.minY - 28 < 4 ? r.maxY + 6 : r.minY - 28
        drawLabel((index.map { "\($0) · " } ?? "") + "\(px.width) × \(px.height)", at: NSPoint(x: r.minX, y: y))
    }

    private func drawLabel(_ text: String, at origin: NSPoint) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let s = NSAttributedString(string: text, attributes: attrs)
        let size = s.size()
        let box = NSRect(x: origin.x, y: origin.y, width: size.width + 12, height: size.height + 6)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).fill()
        s.draw(at: NSPoint(x: box.minX + 6, y: box.minY + 3))
    }
}
