import AppKit
import SwiftUI
import AVFoundation
import NativeShotKit

enum RecorderPrefs {
    static let fps = "recorder.fps"
    static let systemAudio = "recorder.systemAudio"
    static let microphone = "recorder.microphone"
    static let cursor = "recorder.cursor"
    static let webcam = "recorder.webcam"
    static let webcamDevice = "recorder.webcamDevice"
    static let webcamShape = "recorder.webcamShape"
    static let clicks = "recorder.clicks"
    /// Opt-in: off until the user accepts the consent explanation (KeyOverlayConsent).
    static let keys = "recorder.keys"
    static let countdown = "recorder.countdown"
    static let codec = "recorder.codec"
    static let quality = "recorder.quality"
    static let micChannels = "recorder.micChannels"
    static let micDevice = "recorder.micDevice"
    static let webcamSize = "recorder.webcamSize"
    static let webcamCorner = "recorder.webcamCorner"

    static func register() {
        UserDefaults.standard.register(defaults: [fps: 30, systemAudio: true, microphone: false, cursor: true,
                                                  webcam: false, webcamShape: "circle", clicks: true, keys: false, countdown: 3,
                                                  codec: "h264", quality: "standard", micChannels: 1, webcamSize: 180, webcamCorner: "bottomLeft"])
    }
}

/// Owns one recording session at a time: UI-09 panel, UI-10 bar and the state machine.
@MainActor
final class RecorderController: ObservableObject {
    private let library: Library
    private var machine = RecorderStateMachine()
    private var engine: RecorderEngine?
    private var selection: SelectionOverlay?
    private var panel: NSPanel?
    private var bar: NSPanel?
    private var results: [RecordingResultPanel] = []
    private var timer: Timer?
    private var sessionID = UUID()
    private var segmentStart: Date?
    private var accumulated: TimeInterval = 0
    private var overlays: RecorderOverlays?
    private var clickLog: [RecordingEvents.Click] = []
    private var cursorLog: [RecordingEvents.Click] = []
    private var lastCursorAt = -1.0
    private var logsClicks = false
    private var eventRect = CGRect.zero
    private var storageTicks = 0
    private var videoBitrate = 0

    @Published private(set) var phase: RecorderPhase = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var level: Float = 0
    @Published private(set) var webcamVisible = true
    @Published private(set) var source: SelectionResult = .display(CGMainDisplayID())
    /// UI-10: free space on the recording volume and the state derived from it; `failure` is set when the session is ending because of an error.
    @Published private(set) var freeBytes: Int64?
    @Published private(set) var storage = StorageLevel.normal
    @Published private(set) var failure: String?

    init(library: Library) { self.library = library }

    #if NATIVESHOT_QA
    func qaCancel() { cancelSession() } // confirmCancel() would block the self-test on its modal alert
    func qaSet(source: SelectionResult) { self.source = source }
    var qaOverlayWindowIDs: [CGWindowID] { overlays?.windowIDs ?? [] }
    #endif

    var isBusy: Bool { machine.isBusy }

    // MARK: Entry points

    /// Menu/shortcut action: open the recorder, or stop the session when one is already running.
    func toggle() {
        switch machine.phase {
        case .recording, .paused: stop()
        case .idle, .ready, .cancelled, .recoverableFailure, .fatalFailure: showPanel()
        default: break
        }
    }

    func showPanel() {
        guard !machine.isBusy else { return }
        RecorderPrefs.register()
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 10),
                            styleMask: [.titled, .closable, .nonactivatingPanel, .utilityWindow], backing: .buffered, defer: false)
            p.title = String(localized: "Grabar pantalla")
            p.level = .floating
            p.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: RecorderPanelView(controller: self))
            p.contentView = host
            p.setContentSize(host.fittingSize)
            panel = p
        }
        panel?.center()
        NSApp.activate()
        panel?.makeKeyAndOrderFront(nil)
    }

    // MARK: Source selection (reuses the screenshot overlay)

    func chooseSource(_ mode: SelectionOverlay.Mode) {
        guard !machine.isBusy, selection == nil else { return }
        if mode == .display, let id = NSScreen.main?.displayID { source = .display(id); return }
        panel?.orderOut(nil)
        let overlay = SelectionOverlay(mode: mode)
        selection = overlay
        overlay.begin { [weak self] result in
            guard let self else { return }
            self.selection = nil
            if let result { self.source = result }
            self.showPanel()
        }
    }

    var sourceDescription: String {
        switch source {
        case .display: String(localized: "Pantalla completa")
        case .window(let id, _): WindowCandidate.onScreen().first { $0.id == id }?.owner ?? String(localized: "Ventana")
        case .region(let r, _): "\(Int(r.width))×\(Int(r.height))"
        }
    }

    // MARK: Session

    func start() {
        guard machine.handle(.start) else { return }
        panel?.orderOut(nil)
        sessionID = UUID()
        Task { await run() }
    }

    private func run() async {
        let d = UserDefaults.standard
        var options = RecorderOptions(fps: [15, 24, 60].contains(d.integer(forKey: RecorderPrefs.fps)) ? d.integer(forKey: RecorderPrefs.fps) : 30,
                                      systemAudio: d.bool(forKey: RecorderPrefs.systemAudio),
                                      microphone: d.bool(forKey: RecorderPrefs.microphone),
                                      showsCursor: d.bool(forKey: RecorderPrefs.cursor),
                                      codec: VideoCodec(rawValue: d.string(forKey: RecorderPrefs.codec) ?? "") ?? .h264,
                                      quality: RecordingQuality(rawValue: d.string(forKey: RecorderPrefs.quality) ?? "") ?? .standard,
                                      microphoneChannels: d.integer(forKey: RecorderPrefs.micChannels) == 2 ? 2 : 1,
                                      microphoneDeviceID: d.string(forKey: RecorderPrefs.micDevice).flatMap { $0.isEmpty ? nil : $0 })
        sync()
        guard ScreenCaptureAdapter.hasPermission else {
            ScreenCaptureAdapter.requestPermission()
            ScreenCaptureAdapter.openPrivacySettings()
            return fail(String(localized: "Falta el permiso de grabación de pantalla."), recoverable: true)
        }
        if options.microphone, await !Self.microphoneGranted() {
            // A denied microphone never blocks the recording.
            options.microphone = false
            Toast.show(String(localized: "Sin acceso al micrófono: se grabará sin él"), symbol: "mic.slash")
        }
        var webcam = d.bool(forKey: RecorderPrefs.webcam)
        if webcam, await !Self.cameraGranted() {
            webcam = false
            Toast.show(String(localized: "Sin acceso a la cámara: se grabará sin webcam"), symbol: "video.slash")
        } else if webcam, CameraSession.devices().isEmpty {
            webcam = false
            Toast.show(String(localized: "No hay ninguna cámara disponible"), symbol: "video.slash")
        }
        var keys = d.bool(forKey: RecorderPrefs.keys)
        if keys, !KeyOverlayConsent.granted {
            keys = false
            Toast.show(String(localized: "Sin permiso de monitorización de entrada: se grabará sin teclas"), symbol: "keyboard")
        }
        logsClicks = d.bool(forKey: RecorderPrefs.clicks)
        clickLog = []
        cursorLog = []
        lastCursorAt = -1
        failure = nil
        eventRect = Self.quartzRect(of: source)
        // A single-window stream can't carry extra windows, so the visible overlays only exist for display/region.
        var onScreenOverlays = true
        if case .window = source {
            onScreenOverlays = false
            if webcam || keys { Toast.show(String(localized: "La webcam y las teclas solo se ven al grabar pantalla o región"), symbol: "info.circle") }
        }
        machine.handle(.authorized); sync()

        let url = recoveryDir.appendingPathComponent("recording.mp4")
        let ov = RecorderOverlays(webcam: webcam && onScreenOverlays, rings: logsClicks && onScreenOverlays,
                                  keys: keys && onScreenOverlays, collectClicks: logsClicks, onClick: { [weak self] point, uptime in
            self?.logClick(at: point, uptime: uptime)
        }, onMove: { [weak self] point, uptime in self?.logMove(at: point, uptime: uptime) })
        overlays = ov
        ov.show()
        webcamVisible = true
        try? await Task.sleep(for: .milliseconds(150)) // let the window server list the new windows before the stream filter asks for them
        do {
            engine = try await RecorderEngine.make(source: source, options: options, url: url, includingWindows: ov.windowIDs)
        } catch {
            return fail(error.localizedDescription, recoverable: true)
        }
        engine?.onFailure = { [weak self] reason in Task { @MainActor in self?.sourceLost(reason) } }
        engine?.onLevel = { [weak self] peak in Task { @MainActor in self?.level = peak } }
        videoBitrate = engine?.writer.videoBitrate ?? 0
        machine.handle(.configured); sync()

        do {
            let secs = d.integer(forKey: RecorderPrefs.countdown)
            try await Countdown.run(seconds: [0, 3, 5, 10].contains(secs) ? secs : 3)
            guard machine.phase == .countdown else { return }
            try await engine?.start()
        } catch is CancellationError {
            return cancelSession()
        } catch {
            return fail(error.localizedDescription, recoverable: true)
        }
        guard machine.handle(.countdownElapsed) else { return cancelSession() }
        elapsed = 0; accumulated = 0; segmentStart = Date()
        storageTicks = 0
        sync()
        showBar()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private static func cameraGranted() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .video)
        default: false
        }
    }

    /// Recorded area in Quartz global points, the space click locations are converted to.
    private static func quartzRect(of source: SelectionResult) -> CGRect {
        switch source {
        case .display(let id): CGDisplayBounds(id)
        case .region(let r, _): r
        case .window(_, let frame): frame // shortcut: window position frozen at start, so clicks after moving it map wrong; track the window if the editor needs it
        }
    }

    private func logClick(at point: CGPoint, uptime: TimeInterval) {
        guard let w = engine?.writer, let t = w.movieTime(forHostTime: CMTime(seconds: uptime, preferredTimescale: 1_000_000)),
              let n = RecordingEvents.normalize(point, in: eventRect) else { return }
        clickLog.append(.init(t: t.seconds, x: n.x, y: n.y))
    }

    /// Pointer track for the editor's cursor-follow: ~15 Hz, positions only, inside the recorded area.
    private func logMove(at point: CGPoint, uptime: TimeInterval) {
        guard uptime - lastCursorAt >= 0.066, cursorLog.count < RecordingEvents.maxCursorSamples,
              let w = engine?.writer, let t = w.movieTime(forHostTime: CMTime(seconds: uptime, preferredTimescale: 1_000_000)),
              let n = RecordingEvents.normalize(point, in: eventRect) else { return }
        lastCursorAt = uptime
        cursorLog.append(.init(t: t.seconds, x: n.x, y: n.y))
    }

    func toggleWebcam() {
        webcamVisible.toggle()
        overlays?.setBubbleVisible(webcamVisible)
    }

    var libraryRoot: URL { library.root }

    var hasWebcam: Bool { overlays?.bubble != nil }

    /// On launch: sessions left in recovery/ mean the app died mid-recording. Recover or discard, never silently.
    func offerRecovery() async {
        let fm = FileManager.default
        let sessions = ((try? fm.contentsOfDirectory(at: library.root.appendingPathComponent("recovery"), includingPropertiesForKeys: nil)) ?? [])
            .filter { fm.fileExists(atPath: $0.appendingPathComponent("recording.mp4").path) }
        guard !sessions.isEmpty, !machine.isBusy else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Se encontraron grabaciones interrumpidas")
        alert.informativeText = String(localized: "NativeShot se cerró durante \(sessions.count) grabación(es). Puedes recuperar lo grabado hasta ese momento o descartarlo.")
        alert.addButton(withTitle: String(localized: "Recuperar"))
        alert.addButton(withTitle: String(localized: "Descartar"))
        alert.addButton(withTitle: String(localized: "Más tarde"))
        NSApp.activate()
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            var failed = 0
            for dir in sessions {
                let file = dir.appendingPathComponent("recording.mp4")
                // Unreadable files stay in recovery/ untouched instead of being deleted.
                guard let info = await MovieProbe.info(of: file),
                      (try? await library.addVideo(id: UUID(uuidString: dir.lastPathComponent) ?? UUID(), from: file, info: info)) != nil
                else { failed += 1; continue }
                try? fm.removeItem(at: dir)
            }
            Toast.show(failed == 0 ? String(localized: "Grabaciones recuperadas") : String(localized: "\(failed) grabación(es) no se pudieron recuperar"),
                       symbol: failed == 0 ? "checkmark.circle" : "exclamationmark.triangle")
        case .alertSecondButtonReturn:
            sessions.forEach { try? fm.removeItem(at: $0) }
        default: break
        }
    }

    private static func microphoneGranted() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        default: false
        }
    }

    func togglePause() {
        if machine.phase == .recording, machine.handle(.pause) {
            accumulated += Date().timeIntervalSince(segmentStart ?? Date()); segmentStart = nil
            engine?.pause()
        } else if machine.phase == .paused, machine.handle(.resume) {
            segmentStart = Date()
            engine?.resume()
        }
        tick(); sync()
    }

    /// Double clicks are harmless: only the first `.stop` is accepted by the state machine.
    func stop() {
        guard machine.handle(.stop) else { return }
        accumulated += segmentStart.map { Date().timeIntervalSince($0) } ?? 0; segmentStart = nil
        timer?.invalidate(); timer = nil
        sync()
        Task { await finalize() }
    }

    private func finalize() async {
        guard let engine else { return }
        do {
            let info = try await engine.stop()
            let dest = try await library.addVideo(id: sessionID, from: engine.writer.url, info: info)
            try? FileManager.default.removeItem(at: recoveryDir)
            if logsClicks {
                try? RecordingEvents(clicks: clickLog.sorted { $0.t < $1.t }, cursor: cursorLog.isEmpty ? nil : cursorLog.sorted { $0.t < $1.t })
                    .write(toFolder: dest.deletingLastPathComponent())
            }
            machine.handle(.finalized)
            let panel = RecordingResultPanel(url: dest, id: sessionID, info: info, library: library) { [weak self] p in
                self?.results.removeAll { $0 === p }
            }
            results.append(panel)
            panel.present()
        } catch {
            // The partial file stays in recovery/ (fragmented MP4, playable) for manual rescue.
            machine.handle(.fail(error.localizedDescription, recoverable: false))
            Toast.show(error.localizedDescription, symbol: "exclamationmark.triangle")
        }
        teardown()
    }

    /// UI-10: cancelling discards everything, so it asks first.
    func confirmCancel() {
        guard machine.phase == .recording || machine.phase == .paused else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "¿Cancelar la grabación?")
        alert.informativeText = String(localized: "Se descartará lo grabado hasta ahora.")
        alert.addButton(withTitle: String(localized: "Seguir grabando"))
        alert.addButton(withTitle: String(localized: "Descartar"))
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        cancelSession()
    }

    private func cancelSession() {
        guard machine.handle(.cancel) else { return }
        let e = engine
        Task {
            await e?.cancel()
            try? FileManager.default.removeItem(at: recoveryDir)
            teardown()
        }
    }

    /// Source disappeared. Never stay in `recording` without a source; keep what was captured.
    private func sourceLost(_ reason: String) {
        switch machine.phase {
        case .recording, .paused:
            if engine?.writer.hasWrittenFrames == true {
                failure = reason
                Toast.show(String(localized: "Se perdió la fuente; se guarda lo grabado"), symbol: "exclamationmark.triangle")
                stop()
            } else {
                fail(reason, recoverable: true)
            }
        case .countdown, .configuring: fail(reason, recoverable: true)
        default: break
        }
    }

    private func fail(_ reason: String, recoverable: Bool) {
        guard machine.handle(.fail(reason, recoverable: recoverable)) else { return }
        Toast.show(reason, symbol: "exclamationmark.triangle")
        let e = engine
        Task {
            await e?.cancel()
            try? FileManager.default.removeItem(at: recoveryDir)
            teardown()
        }
    }

    private func teardown() {
        timer?.invalidate(); timer = nil
        bar?.orderOut(nil); bar = nil
        overlays?.stop(); overlays = nil
        clickLog = []; cursorLog = []
        engine = nil
        level = 0
        failure = nil
        storage = .normal; freeBytes = nil
        machine.handle(.reset)
        sync()
    }

    // MARK: Helpers

    private var recoveryDir: URL {
        library.root.appendingPathComponent("recovery/\(sessionID.uuidString)", isDirectory: true)
    }

    private func sync() { phase = machine.phase }

    private func tick() {
        elapsed = accumulated + (segmentStart.map { Date().timeIntervalSince($0) } ?? 0)
        // Free space is checked every ~5 s (20 ticks of 0.25 s), not on every redraw.
        if storageTicks % 20 == 0 { checkStorage() }
        storageTicks += 1
    }

    private func checkStorage() {
        guard machine.phase == .recording || machine.phase == .paused, let free = DiskSpace.freeBytes(at: library.root) else { return }
        let was = storage, now = DiskSpace.level(freeBytes: free, bitrate: videoBitrate)
        freeBytes = free; storage = now
        if now == .low, was == .normal { Toast.show(String(localized: "Almacenamiento bajo: libera espacio o detén la grabación"), symbol: "externaldrive.badge.exclamationmark") }
        if now == .critical {
            // Stopping now keeps a valid file; running the disk to zero would corrupt the tail of the recording.
            failure = String(localized: "Disco casi lleno")
            Toast.show(String(localized: "Disco casi lleno: se detiene la grabación y se guarda lo grabado"), symbol: "exclamationmark.triangle")
            stop()
        }
    }

    private func showBar() {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isMovableByWindowBackground = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let host = NSHostingView.fixed(RecordingBarView(controller: self))
        p.contentView = host
        p.setContentSize(host.fittingSize)
        if let f = NSScreen.main?.visibleFrame { p.setFrameOrigin(NSPoint(x: f.midX - p.frame.width / 2, y: f.maxY - p.frame.height - 12)) }
        p.orderFrontRegardless()
        bar = p
    }
}
