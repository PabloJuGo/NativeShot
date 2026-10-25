import AppKit
import AVFoundation
import Carbon.HIToolbox
import NativeShotKit

/// Webcam capture shared by the floating bubble. All AVCaptureSession calls stay on one serial queue.
final class CameraSession: @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "app.nativeshot.webcam")

    static func devices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external], mediaType: .video, position: .unspecified).devices
    }

    func use(deviceID: String?) {
        queue.async { [self] in
            session.beginConfiguration()
            session.inputs.forEach(session.removeInput)
            let device = Self.devices().first { $0.uniqueID == deviceID } ?? AVCaptureDevice.default(for: .video)
            if let device, let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) { session.addInput(input) }
            session.commitConfiguration()
            if !session.isRunning { session.startRunning() }
        }
    }

    func stop() {
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
            session.inputs.forEach(session.removeInput)
        }
    }
}

/// Floating camera preview. It is a regular window of this app, so the recorder lets it through the
/// own-app exclusion with `exceptingWindows` and it lands in the video.
@MainActor
final class WebcamBubble: NSPanel {
    private let camera = CameraSession()
    private let preview: AVCaptureVideoPreviewLayer
    private var circular: Bool
    private let host = BubbleView()

    init(on screen: NSScreen) {
        circular = UserDefaults.standard.string(forKey: RecorderPrefs.webcamShape) != "rect"
        preview = AVCaptureVideoPreviewLayer(session: camera.session)
        let d = UserDefaults.standard
        let side = CGFloat(min(max(d.integer(forKey: RecorderPrefs.webcamSize), 96), 480))
        super.init(contentRect: NSRect(x: 0, y: 0, width: side, height: side),
                   styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        minSize = NSSize(width: 96, height: 96)
        preview.videoGravity = .resizeAspectFill
        if let c = preview.connection, c.isVideoMirroringSupported {
            c.automaticallyAdjustsVideoMirroring = false
            c.isVideoMirrored = true // selfie view
        }
        host.wantsLayer = true
        host.layer?.addSublayer(preview)
        host.layer?.masksToBounds = true
        host.bubble = self
        contentView = host
        applyShape()
        let f = screen.visibleFrame, corner = d.string(forKey: RecorderPrefs.webcamCorner) ?? "bottomLeft"
        let x = corner.hasSuffix("Right") ? f.maxX - frame.width - 24 : f.minX + 24
        let y = corner.hasPrefix("top") ? f.maxY - frame.height - 24 : f.minY + 24
        setFrameOrigin(NSPoint(x: x, y: y))
        camera.use(deviceID: UserDefaults.standard.string(forKey: RecorderPrefs.webcamDevice))
    }

    override var canBecomeKey: Bool { false }

    func shutdown() { camera.stop(); orderOut(nil) }

    fileprivate func applyShape() {
        let side = max(frame.width, minSize.width)
        aspectRatio = circular ? NSSize(width: 1, height: 1) : NSSize(width: 16, height: 9)
        let size = circular ? NSSize(width: side, height: side) : NSSize(width: side, height: side * 9 / 16)
        setFrame(NSRect(origin: frame.origin, size: size), display: true)
        host.needsLayout = true
    }

    fileprivate func layoutPreview() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        preview.frame = host.bounds
        host.layer?.cornerRadius = circular ? min(host.bounds.width, host.bounds.height) / 2 : 12
        CATransaction.commit()
    }

    fileprivate func contextMenu() -> NSMenu {
        let m = NSMenu()
        let current = UserDefaults.standard.string(forKey: RecorderPrefs.webcamDevice)
        for d in CameraSession.devices() {
            let i = NSMenuItem(title: d.localizedName, action: #selector(pickDevice(_:)), keyEquivalent: "")
            i.representedObject = d.uniqueID
            i.state = d.uniqueID == current ? .on : .off
            i.target = self
            m.addItem(i)
        }
        m.addItem(.separator())
        let shape = NSMenuItem(title: circular ? String(localized: "Forma rectangular") : String(localized: "Forma circular"),
                               action: #selector(toggleShape), keyEquivalent: "")
        shape.target = self
        m.addItem(shape)
        return m
    }

    @objc private func pickDevice(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String else { return }
        UserDefaults.standard.set(id, forKey: RecorderPrefs.webcamDevice)
        camera.use(deviceID: id)
    }

    @objc private func toggleShape() {
        circular.toggle()
        UserDefaults.standard.set(circular ? "circle" : "rect", forKey: RecorderPrefs.webcamShape)
        applyShape()
    }
}

private final class BubbleView: NSView {
    weak var bubble: WebcamBubble?
    override func layout() { super.layout(); bubble?.layoutPreview() }
    override func menu(for event: NSEvent) -> NSMenu? { bubble?.contextMenu() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
}

/// Click rings, the shortcut pill and the camera bubble for one session. Everything here is a window of this
/// app that never takes the mouse; `windowIDs` is what the stream filter must let through.
@MainActor
final class RecorderOverlays {
    private(set) var bubble: WebcamBubble?
    private var ringPanels: [(panel: NSPanel, screen: NSScreen)] = []
    private var keyPanel: NSPanel?
    private var keyPill = NSView()
    private var keyLabel = NSTextField(labelWithString: "")
    private var keyHide: Task<Void, Never>?
    private var monitors: [Any] = []

    /// `onClick` gets the Quartz-global location and the event's uptime (same clock as the stream timestamps).
    /// `onMove` receives pointer positions the same way (the caller throttles).
    init(webcam: Bool, rings: Bool, keys: Bool, collectClicks: Bool, onClick: @escaping @MainActor (CGPoint, TimeInterval) -> Void,
         onMove: @escaping @MainActor (CGPoint, TimeInterval) -> Void) {
        let main = NSScreen.main ?? NSScreen.screens[0]
        if webcam { bubble = WebcamBubble(on: main) }
        if rings { for s in NSScreen.screens { ringPanels.append((Self.makeOverlayPanel(frame: s.frame), s)) } }
        if keys { makeKeyPanel(on: main) }
        if collectClicks || rings {
            // Mouse events need no Accessibility or Input Monitoring grant (only key events do).
            let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                let kind = event.type, t = event.timestamp
                MainActor.assumeIsolated {
                    let cocoa = NSEvent.mouseLocation
                    if rings { self?.ring(at: cocoa, right: kind == .rightMouseDown) }
                    if collectClicks, let h = NSScreen.screens.first?.frame.height {
                        onClick(CGPoint(x: cocoa.x, y: h - cocoa.y), t)
                    }
                }
            }
            if let m { monitors.append(m) }
        }
        if collectClicks {
            let m = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]) { event in
                let t = event.timestamp
                MainActor.assumeIsolated {
                    let cocoa = NSEvent.mouseLocation
                    if let h = NSScreen.screens.first?.frame.height { onMove(CGPoint(x: cocoa.x, y: h - cocoa.y), t) }
                }
            }
            if let m { monitors.append(m) }
        }
        if keys {
            let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard !event.isARepeat, !IsSecureEventInputEnabled() else { return }
                // Only shortcut chords survive KeyChord; the label is shown and dropped, never stored.
                let f = event.modifierFlags
                var mods: KeyModifiers = []
                if f.contains(.command) { mods.insert(.command) }
                if f.contains(.control) { mods.insert(.control) }
                if f.contains(.option) { mods.insert(.option) }
                if f.contains(.shift) { mods.insert(.shift) }
                guard let label = KeyChord.label(keyCode: event.keyCode, character: event.charactersIgnoringModifiers, modifiers: mods) else { return }
                MainActor.assumeIsolated { self?.flash(label) }
            }
            if let m { monitors.append(m) }
        }
    }

    var windowIDs: [CGWindowID] {
        ([bubble] as [NSWindow?] + ringPanels.map { $0.panel } + [keyPanel]).compactMap { $0 }.map { CGWindowID($0.windowNumber) }
    }

    func setBubbleVisible(_ on: Bool) {
        if on { bubble?.orderFrontRegardless() } else { bubble?.orderOut(nil) }
    }

    func show() {
        bubble?.orderFrontRegardless()
        ringPanels.forEach { $0.panel.orderFrontRegardless() }
        keyPanel?.orderFrontRegardless()
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        keyHide?.cancel()
        bubble?.shutdown(); bubble = nil
        ringPanels.forEach { $0.panel.orderOut(nil) }; ringPanels = []
        keyPanel?.orderOut(nil); keyPanel = nil
    }

    // MARK: Drawing

    private static func makeOverlayPanel(frame: NSRect) -> NSPanel {
        let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .screenSaver
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        p.contentView = NSView(frame: NSRect(origin: .zero, size: frame.size))
        p.contentView?.wantsLayer = true
        p.setFrame(frame, display: false)
        return p
    }

    private func ring(at cocoa: NSPoint, right: Bool) {
        guard let (panel, screen) = ringPanels.first(where: { $0.screen.frame.contains(cocoa) }),
              let layer = panel.contentView?.layer else { return }
        let d: CGFloat = 44
        let shape = CAShapeLayer()
        shape.path = CGPath(ellipseIn: CGRect(x: -d / 2, y: -d / 2, width: d, height: d), transform: nil)
        let color = (right ? NSColor.systemOrange : NSColor.systemYellow).cgColor
        shape.strokeColor = color
        shape.fillColor = color.copy(alpha: 0.25)
        shape.lineWidth = 3
        shape.position = CGPoint(x: cocoa.x - screen.frame.minX, y: cocoa.y - screen.frame.minY)
        layer.addSublayer(shape)
        let scale = CABasicAnimation(keyPath: "transform.scale"); scale.fromValue = 0.4; scale.toValue = 1.3
        let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 1; fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = 0.45
        CATransaction.begin()
        CATransaction.setCompletionBlock { shape.removeFromSuperlayer() }
        shape.add(group, forKey: "click")
        shape.opacity = 0
        CATransaction.commit()
    }

    private func makeKeyPanel(on screen: NSScreen) {
        let size = NSSize(width: 420, height: 72)
        let f = screen.visibleFrame
        let p = Self.makeOverlayPanel(frame: NSRect(x: f.midX - size.width / 2, y: f.minY + 72, width: size.width, height: size.height))
        keyPill = NSView(frame: NSRect(x: 0, y: 0, width: size.width, height: size.height))
        keyPill.wantsLayer = true
        keyPill.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.75).cgColor
        keyPill.layer?.cornerRadius = 16
        keyPill.isHidden = true
        keyLabel.font = .monospacedSystemFont(ofSize: 30, weight: .medium)
        keyLabel.textColor = .white
        keyLabel.alignment = .center
        keyLabel.frame = NSRect(x: 8, y: (size.height - 40) / 2, width: size.width - 16, height: 40)
        keyPill.addSubview(keyLabel)
        p.contentView?.addSubview(keyPill)
        keyPanel = p
    }

    private func flash(_ label: String) {
        keyLabel.stringValue = label
        keyPill.isHidden = false
        keyHide?.cancel()
        keyHide = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.4))
            if !Task.isCancelled { self?.keyPill.isHidden = true }
        }
    }
}

/// Informed consent for the shortcut overlay (Input Monitoring). Nothing is requested until the user agrees.
@MainActor
enum KeyOverlayConsent {
    static var granted: Bool { CGPreflightListenEventAccess() }

    /// Returns true when the user accepts; also triggers the system prompt.
    static func ask() -> Bool {
        let a = NSAlert()
        a.messageText = String(localized: "¿Mostrar atajos de teclado en la grabación?")
        a.informativeText = String(localized: "Para ver las teclas pulsadas macOS pedirá el permiso «Monitorización de entrada». NativeShot solo muestra combinaciones con ⌘, ⌃ o ⌥ (por ejemplo ⌘C), nunca texto suelto, no muestra nada en campos de contraseña y no guarda ningún historial de teclas. Sin el permiso, la grabación continúa sin este overlay.")
        a.addButton(withTitle: String(localized: "Activar"))
        a.addButton(withTitle: String(localized: "Cancelar"))
        guard a.runModal() == .alertFirstButtonReturn else { return false }
        if !granted { _ = CGRequestListenEventAccess() }
        return true
    }
}
