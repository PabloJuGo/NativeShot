#if NATIVESHOT_QA
import AppKit
import SwiftUI
import AVFoundation
import Carbon.HIToolbox
import ScreenCaptureKit
import NativeShotKit

/// End-to-end self-test against real permissions, real ScreenCaptureKit and real windows (docs/QA-manual.md,
/// automated part). Launch with: NativeShot --qa-selftest <dir>. Writes report.json, report.md and PNG
/// evidence to <dir>, then quits. Only compiled with -DNATIVESHOT_QA (scripts/selftest.sh).
@MainActor
final class QARunner {
    struct Step: Codable {
        var id: String
        var title: String
        var status: String = "pass"   // pass | fail | skip
        var details: [String] = []
        var ms: Double = 0
    }

    struct Fixture {
        let process: Process
        let output: FileHandle
        let pid: pid_t
        let content: CGRect   // Quartz global points
        let frame: CGRect
        let scale: CGFloat
    }

    private static var current: QARunner?
    /// Windows that became visible with an empty frame (invisible UI that still "exists").
    private static var zeroSized: [String] = []
    private let out: URL
    private var steps: [Step] = []
    private var step = Step(id: "", title: "")
    private let app = AppController.shared
    private let only: Set<String>
    private var savedDefaults: [String: Any?] = [:]

    static func start(outputDir: URL) {
        let r = QARunner(out: outputDir)
        current = r
        // Trace every window that shows up, so a crash in AppKit layout can be tied to a panel.
        var seen = Set<Int>()
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated {
                for w in NSApp.windows where w.isVisible && !seen.contains(w.windowNumber) {
                    seen.insert(w.windowNumber)
                    if (w.frame.width < 1 || w.frame.height < 1) && !(w.className.contains("StatusBar")) { zeroSized.append("\(type(of: w)) '\(w.title)'") }
                    FileHandle.standardError.write(Data("[WIN] \(type(of: w)) '\(w.title)' content=\(w.contentView.map { String(describing: type(of: $0)) } ?? "nil")\n".utf8))
                }
            }
        }
        Task { await r.runAll(); NSApp.terminate(nil) }
    }

    private init(out: URL) {
        self.out = out
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        only = Set((ProcessInfo.processInfo.environment["NS_QA_ONLY"] ?? "").split(separator: ",").map(String.init))
    }

    // MARK: Driver

    private var freshMB = Double.nan

    private func runAll() async {
        OnboardingWindow.close()
        try? await Task.sleep(for: .seconds(1.5))
        freshMB = Self.residentMB()
        overrideDefaults()
        await run("ENV", "Entorno, permisos y atajos") { try await self.environment() }
        await run("CAP-REGION", "Captura de región sobre ventana patrón (CAP-001, CAP-016, QAO-001)") { try await self.regionCapture() }
        await run("CAP-EXCLUDE", "Ventanas propias excluidas de la captura (CAP-013, QAO-005)") { try await self.exclusion() }
        await run("CAP-WINDOW", "Captura de ventana con y sin sombra (CAP-002)") { try await self.windowCapture() }
        await run("CAP-DISPLAY", "Captura de pantalla completa (CAP-003)") { try await self.displayCapture() }
        await run("CAP-LAST", "Repetir última región (CAP-005)") { try await self.lastRegion() }
        await run("EXP", "Copiar, guardar con plantilla y formatos (EXP, QAO-002)") { try await self.exportChecks() }
        await run("OCR", "OCR español/inglés y QR sin abrir URL (OCR)") { try await self.ocr() }
        await run("HIS", "Biblioteca: indexado OCR, búsqueda sin acentos, papelera (HIS)") { try await self.history() }
        await run("IMG", "Editor: redacción irreversible verificada con OCR (IMG)") { try await self.editor() }
        await run("PIN", "Pines: fijar, zoom, cerrar (PIN)") { try await self.pins() }
        await run("REC", "Grabación de región con audio del sistema (REC)") { try await self.recording(webcam: false, mic: false) }
        await run("REC-MIC", "Grabación con micrófono (REC)") { try await self.recording(webcam: false, mic: true) }
        await run("REC-CAM", "Grabación con webcam (REC)") { try await self.recording(webcam: true, mic: false) }
        await run("GIF", "Exportar GIF de la grabación (VID)") { try await self.gif() }
        await run("VID", "Editor de vídeo: zoom automático y exportación (VID)") { try await self.videoExport() }
        await run("QAO-KEYS", "Miniatura: foco por teclado, Esc y «Restaurar última» (QAO-5)") { try await self.thumbnailKeys() }
        await run("PIN-KEYS", "Pines: ⌘+, ⌘−, opacidad, Esc y ⌘W (PIN-2, PIN-3)") { try await self.pinKeys() }
        await run("S1-PASTE", "Copiar y pegar en un editor de texto enriquecido de AppKit (S1-1..3)") { try await self.pasteIntoTextView() }
        await run("REC-COUNTDOWN", "Cuenta atrás de 3 s antes de grabar y cancelación (REC-1)") { try await self.countdown() }
        await run("E2E-HOTKEY", "Atajo → overlay → arrastre → miniatura (gate S1)") { try await self.hotkeyFlow() }
        await run("E2E-ESC", "Esc cancela sin capturar") { try await self.escCancels() }
        await run("E2E-WINDOW", "Atajo de ventana + clic (CAP-002)") { try await self.hotkeyWindow() }
        await run("SCR", "Captura con scroll real (SCR)") { try await self.scrollCapture() }
        await run("SCR-BACK", "Scroll hacia atrás a mitad de la captura (SCR-2)") { try await self.scrollBack() }
        await run("SCR-CANCEL", "Cancelar la captura con scroll (SCR-5)") { try await self.scrollCancel() }
        await run("MULTI", "Varias regiones con ⌘ y Return (CAP-011)") { try await self.multiRegion() }
        await run("FREEZE", "Pantalla congelada (CAP-010)") { try await self.freeze() }
        await run("PRIVATE", "Sesión privada: nada llega a la biblioteca (HIS)") { try await self.privateSession() }
        await run("PIN-LOCK", "Pin bloqueado: los clics lo atraviesan (PIN-001)") { try await self.pinLock() }
        await run("TOOLS", "Ventana de OCR y gestor de exportación, claro y oscuro (UI-07, UI-19)") { try await self.toolWindows() }
        await run("PERF", "Latencias reales atajo→overlay y selección→miniatura") { try await self.latency() }
        await run("UI", "Capturas de todas las superficies, claro y oscuro") { try await self.uiSnapshots() }
        if let n = Int(ProcessInfo.processInfo.environment["NS_QA_SOAK"] ?? "") {
            await run("SOAK", "Estrés: \(n) capturas seguidas sin crecimiento de memoria (B-04)") { try await self.soak(cycles: n) }
        }
        if let secs = Double(ProcessInfo.processInfo.environment["NS_QA_LONG"] ?? "") {
            await run("REC-LONG", "Grabación larga de \(Int(secs)) s: duración, fotogramas, sincronía y memoria (REC-5)") { try await self.longRecording(seconds: secs) }
        }
        await run("IDLE", "Reposo: CPU < 1 % y memoria ≤ 120 MB") { try await self.idle() }
        await run("A11Y", "Auditoría de accesibilidad: todo control tiene nombre para VoiceOver (EXT-4)") { try await self.accessibilityAudit() }
        await run("WIN-SIZE", "Ninguna ventana visible con tamaño cero") {
            self.check(Self.zeroSized.isEmpty, "Ventanas vacías: \(Self.zeroSized)")
        }
        restoreDefaults()
        writeReport()
        // Keeps the process alive for heap/vmmap inspection.
        if let hold = Double(ProcessInfo.processInfo.environment["NS_QA_HOLD"] ?? "") { log("HOLD pid=\(getpid())"); try? await Task.sleep(for: .seconds(hold)) }
    }

    private func run(_ id: String, _ title: String, _ body: () async throws -> Void) async {
        guard only.isEmpty || only.contains(id) else { return }
        step = Step(id: id, title: title)
        let t0 = CFAbsoluteTimeGetCurrent()
        do { try await body() } catch let e as Skip {
            step.status = "skip"; step.details.append("SKIP: \(e.reason)")
        } catch {
            step.status = "fail"; step.details.append("ERROR: \(error.localizedDescription)")
        }
        step.ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        steps.append(step)
        writeReport()
        log("\(step.status.uppercased()) \(id) (\(Int(step.ms)) ms) rss=\(Int(Self.residentMB())) MB")
        // Leave the screen clean between steps.
        closeTransientWindows()
        try? await Task.sleep(for: .milliseconds(400))
    }

    struct Skip: Error { let reason: String }

    private func note(_ s: String) { step.details.append(s) }

    private func check(_ ok: Bool, _ what: String) {
        step.details.append((ok ? "✔ " : "✘ ") + what)
        if !ok { step.status = "fail" }
    }

    private func log(_ s: String) {
        FileHandle.standardError.write(Data("[QA] \(s)\n".utf8))
    }

    // MARK: Defaults isolation

    private func overrideDefaults() {
        let d = UserDefaults.standard
        let values: [String: Any] = [Prefs.timerSeconds: 0, Prefs.afterCapture: AfterCapture.overlay.rawValue, Prefs.playSound: false,
                                     Prefs.keepHistory: true, Prefs.ocrIndex: true, Prefs.saveFolder: out.appendingPathComponent("saved").path,
                                     Prefs.overlayDuration: 0.0, Prefs.showsCursor: false, RecorderPrefs.countdown: 0]
        for (k, v) in values { savedDefaults[k] = d.object(forKey: k); d.set(v, forKey: k) }
    }

    private func restoreDefaults() {
        let d = UserDefaults.standard
        for (k, v) in savedDefaults { if let v { d.set(v, forKey: k) } else { d.removeObject(forKey: k) } }
    }

    // MARK: Fixture

    private func launchFixture(_ mode: String) async throws -> Fixture {
        let p = Process()
        p.executableURL = Bundle.main.bundleURL.deletingLastPathComponent()
            .appendingPathComponent("NSQAFixture.app/Contents/MacOS/NativeShot") // separate bundle id, see scripts/selftest.sh
        p.arguments = ["--qa-fixture", mode]
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run()
        let line: Data = try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async {
                var buf = Data()
                while true {
                    let chunk = pipe.fileHandleForReading.availableData
                    if chunk.isEmpty { cont.resume(throwing: CocoaError(.fileReadUnknown)); return }
                    buf.append(chunk)
                    if buf.contains(0x0A) { cont.resume(returning: buf); return }
                }
            }
        }
        guard let obj = try JSONSerialization.jsonObject(with: line.prefix { $0 != 0x0A }) as? [String: Any],
              let c = obj["content"] as? [Double], let f = obj["frame"] as? [Double] else { throw CocoaError(.fileReadCorruptFile) }
        try await Task.sleep(for: .milliseconds(300))
        return Fixture(process: p, output: pipe.fileHandleForReading, pid: p.processIdentifier, content: CGRect(x: c[0], y: c[1], width: c[2], height: c[3]),
                       frame: CGRect(x: f[0], y: f[1], width: f[2], height: f[3]), scale: obj["scale"] as? Double ?? 2)
    }

    /// Next JSON line the fixture prints, or nil after `timeout`.
    private func nextLine(_ f: Fixture, timeout: Double) async -> [String: Any]? {
        let h = f.output
        let data: Data? = await withCheckedContinuation { cont in
            let done = OSAllocatedUnfairLockBox()
            DispatchQueue.global().async {
                var buf = Data()
                while !buf.contains(0x0A) {
                    let chunk = h.availableData
                    if chunk.isEmpty { break }
                    buf.append(chunk)
                }
                if done.claim() { cont.resume(returning: buf.isEmpty ? nil : buf) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if done.claim() { cont.resume(returning: nil) } }
        }
        guard let data else { return nil }
        return try? JSONSerialization.jsonObject(with: data.prefix { $0 != 0x0A }) as? [String: Any]
    }

    private func stop(_ f: Fixture) { f.process.terminate(); f.process.waitUntilExit() }

    private var mainDisplay: CGDirectDisplayID { CGMainDisplayID() }

    // MARK: Pixels

    /// Image redrawn into 8-bit sRGB RGBA so colour checks don't depend on the display profile.
    struct Pixels {
        let w: Int, h: Int, data: [UInt8]
        init(_ img: CGImage) {
            w = img.width; h = img.height
            var buf = [UInt8](repeating: 0, count: w * h * 4)
            let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            data = buf
        }
        /// x, y from the top-left.
        func at(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
            let i = (y * w + x) * 4  // bitmap contexts store the top row first
            return (Int(data[i]), Int(data[i + 1]), Int(data[i + 2]))
        }
    }

    private func dominant(_ p: (r: Int, g: Int, b: Int)) -> String {
        if p.r > 180 && p.g > 160 && p.b < 90 { return "yellow" }
        if p.r > 170 && p.g < 90 && p.b < 90 { return "red" }
        if p.g > 140 && p.r < 90 && p.b < 90 { return "green" }
        if p.b > 170 && p.r < 90 && p.g < 90 { return "blue" }
        if p.r > 235 && p.g > 235 && p.b > 235 { return "white" }
        if p.r < 40 && p.g < 40 && p.b < 40 { return "black" }
        return "other(\(p.r),\(p.g),\(p.b))"
    }

    /// Quadrant colours of the static fixture, sampled at their centres. `origin` = fixture content's top-left in image pixels.
    private func quadrants(_ img: CGImage, origin: CGPoint, scale: CGFloat) -> [String] {
        let px = Pixels(img)
        let centers = [CGPoint(x: 160, y: 50), CGPoint(x: 480, y: 50), CGPoint(x: 160, y: 150), CGPoint(x: 480, y: 150)]
        return centers.map { c in
            let x = Int(origin.x + c.x * scale), y = Int(origin.y + c.y * scale)
            guard x >= 0, y >= 0, x < px.w, y < px.h else { return "out" }
            return dominant(px.at(x, y))
        }
    }

    private func savePNG(_ img: CGImage, _ name: String) {
        _ = try? Library.writePNG(img, to: out.appendingPathComponent(name))
    }

    private func waitUntil(_ timeout: Double, _ cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return cond()
    }

    // MARK: Steps

    private func environment() async throws {
        let screen = ScreenCaptureAdapter.hasPermission
        check(screen, "Permiso de grabación de pantalla concedido")
        note("Micrófono: \(AVCaptureDevice.authorizationStatus(for: .audio).rawValue) (3 = concedido)")
        note("Cámara: \(AVCaptureDevice.authorizationStatus(for: .video).rawValue) (3 = concedido), dispositivos: \(AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external], mediaType: .video, position: .unspecified).devices.map(\.localizedName))")
        note("Accesibilidad (para eventos sintéticos): \(AXIsProcessTrusted())")
        note("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        for s in NSScreen.screens { note("Pantalla \(s.displayID): \(Int(s.frame.width))×\(Int(s.frame.height)) pt, escala \(s.backingScaleFactor)") }
        for a in ShortcutAction.allCases {
            note("Atajo \(a.rawValue): \(app.shortcuts.bindings[a]?.displayString ?? "—")\(app.shortcutFailures[a].map { " FALLO \($0)" } ?? "")")
        }
        check(app.shortcutFailures.isEmpty, "Todos los atajos por defecto se registraron sin conflicto")
        note("Sonda ⇧⌘5 de Apple: \(SystemScreenshotShortcutProbe.state())")
        if !screen { throw Skip(reason: "sin permiso de pantalla no se puede seguir") }
    }

    private func regionCapture() async throws {
        let f = try await launchFixture("static")
        defer { stop(f) }
        let r = CGRect(x: f.content.minX, y: f.content.minY, width: f.content.width, height: 200)
        let before = app.qaLastCapture?.id
        let t0 = CFAbsoluteTimeGetCurrent()
        await app.capture(.region(r, display: mainDisplay), purpose: .region)
        let c = try XCTUnwrap(app.qaLastCapture, "captura entregada")
        note(String(format: "capture()→deliver: %.0f ms", (CFAbsoluteTimeGetCurrent() - t0) * 1000))
        check(c.id != before, "Se entregó una captura nueva")
        check(c.image.width == Int(r.width * f.scale) && c.image.height == Int(r.height * f.scale),
              "Tamaño en píxeles = región × escala (\(c.image.width)×\(c.image.height), esperado \(Int(r.width * f.scale))×\(Int(r.height * f.scale)))")
        let q = quadrants(c.image, origin: .zero, scale: f.scale)
        check(q == ["red", "green", "blue", "yellow"], "Colores de los cuadrantes en su sitio: \(q)")
        savePNG(c.image, "cap-region.png")
        check(FileManager.default.fileExists(atPath: c.fileURL.path), "Original guardado en la biblioteca")
        check(app.qaThumbnails > 0, "Miniatura flotante visible")
        await app.library.refresh()
        check(app.library.recent.first?.id == c.id, "La captura aparece la primera en el historial")
    }

    private func exclusion() async throws {
        let f = try await launchFixture("static")
        defer { stop(f) }
        // A NativeShot pin (black) placed right over the red quadrant must not show in the capture.
        let black = CGContext(data: nil, width: 200, height: 120, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        black.setFillColor(CGColor(gray: 0, alpha: 1)); black.fill(CGRect(x: 0, y: 0, width: 200, height: 120))
        app.pin(Capture(id: UUID(), image: black.makeImage()!, fileURL: out))
        try await Task.sleep(for: .milliseconds(300))
        guard let pin = NSApp.windows.first(where: { $0 is PinPanel && $0.isVisible }) else { throw Skip(reason: "no se abrió el pin") }
        let appKitRed = DisplayGeometry.flip(CGRect(x: f.content.minX + 60, y: f.content.minY + 10, width: 200, height: 80), primaryHeight: NSScreen.primaryHeight)
        pin.setFrame(appKitRed, display: true)
        try await Task.sleep(for: .milliseconds(300))
        let r = CGRect(x: f.content.minX, y: f.content.minY, width: f.content.width, height: 200)
        let img = try await ScreenCaptureAdapter.capture(display: mainDisplay, rect: r, showsCursor: false)
        let q = quadrants(img, origin: .zero, scale: f.scale)
        check(q[0] == "red", "El pin negro de NativeShot no aparece encima del rojo: \(q[0])")
        savePNG(img, "cap-exclusion.png")
        app.closeAllPins()
    }

    private func fixtureWindowID(_ f: Fixture) -> CGWindowID? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return nil }
        return list.first { ($0[kCGWindowOwnerPID as String] as? Int32) == f.pid && ($0[kCGWindowLayer as String] as? Int) != nil
            && ($0[kCGWindowName as String] as? String) == "NS-QA-Fixture" }?[kCGWindowNumber as String] as? CGWindowID
            ?? list.first { ($0[kCGWindowOwnerPID as String] as? Int32) == f.pid }?[kCGWindowNumber as String] as? CGWindowID
    }

    private func windowCapture() async throws {
        let f = try await launchFixture("static")
        defer { stop(f) }
        let id = try XCTUnwrap(fixtureWindowID(f), "ventana patrón localizada")
        check(WindowCandidate.onScreen().contains { $0.id == id }, "La ventana patrón es candidata para el modo ventana")
        let noShadow = try await ScreenCaptureAdapter.capture(windowID: id, shadow: false)
        let ew = Int(f.frame.width * f.scale), eh = Int(f.frame.height * f.scale)
        check(abs(noShadow.width - ew) <= 2 && abs(noShadow.height - eh) <= 2, "Sin sombra: \(noShadow.width)×\(noShadow.height) ≈ ventana \(ew)×\(eh)")
        let titleBar = (f.frame.height - f.content.height) * f.scale
        let q = quadrants(noShadow, origin: CGPoint(x: 0, y: titleBar), scale: f.scale)
        check(q == ["red", "green", "blue", "yellow"], "Contenido de la ventana correcto: \(q)")
        let shadow = try await ScreenCaptureAdapter.capture(windowID: id, shadow: true)
        check(shadow.width > noShadow.width && shadow.height > noShadow.height, "Con sombra la imagen es mayor (\(shadow.width)×\(shadow.height))")
        let corner = Pixels(shadow)
        let alpha = corner.data[3] // top-left pixel (bottom row in buffer is irrelevant for a corner of a shadow image)
        check(alpha < 255, "Fondo transparente alrededor de la sombra (alfa esquina \(alpha))")
        savePNG(noShadow, "cap-window.png"); savePNG(shadow, "cap-window-shadow.png")
    }

    private func displayCapture() async throws {
        let img = try await ScreenCaptureAdapter.capture(display: mainDisplay, rect: nil, showsCursor: false)
        let b = CGDisplayBounds(mainDisplay)
        let scale = NSScreen.screens[0].backingScaleFactor
        check(img.width == Int(b.width * scale) && img.height == Int(b.height * scale), "Pantalla completa a resolución nativa \(img.width)×\(img.height)")
        let small = downscale(img, maxWidth: 1400)
        savePNG(small, "cap-display.png")
    }

    private func lastRegion() async throws {
        let f = try await launchFixture("static")
        defer { stop(f) }
        let r = CGRect(x: f.content.minX + 320, y: f.content.minY, width: 320, height: 100)
        await app.capture(.region(r, display: mainDisplay), purpose: .region)
        let first = try XCTUnwrap(app.qaLastCapture, "primera captura")
        app.captureLastRegion()
        let ok = await waitUntil(5) { self.app.qaLastCapture?.id != first.id && self.app.qaIdle }
        check(ok, "Repetir última región produce otra captura")
        if let c = app.qaLastCapture { check(c.image.width == first.image.width && c.image.height == first.image.height, "Mismo tamaño que la anterior")
            check(quadrants(c.image, origin: CGPoint(x: -320 * f.scale, y: 0), scale: f.scale)[1] == "green", "Misma zona (verde)") }
    }

    private func exportChecks() async throws {
        let c = try XCTUnwrap(app.qaLastCapture, "hay una captura previa")
        app.copy(c)
        let pbImg = NSImage(pasteboard: .general)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        check(pbImg?.width == c.image.width, "Copiar deja la imagen a tamaño completo en el portapapeles (\(pbImg?.width ?? 0) px)")
        let folder = out.appendingPathComponent("saved")
        try? FileManager.default.removeItem(at: folder)
        for fmt in ["png", "jpeg"] {
            UserDefaults.standard.set(fmt, forKey: Prefs.exportFormat)
            app.save(c)
        }
        UserDefaults.standard.removeObject(forKey: Prefs.exportFormat)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        note("Guardados: \(files.sorted())")
        check(files.contains { $0.hasSuffix(".png") } && files.contains { $0.hasSuffix(".jpg") || $0.hasSuffix(".jpeg") }, "Guardar crea PNG y JPEG en la carpeta elegida")
        check(Set(files).count == files.count && files.count >= 2, "Nombres únicos, sin sobrescribir")
        for name in files {
            let props = CGImageSourceCreateWithURL(folder.appendingPathComponent(name) as CFURL, nil).flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [String: Any] }
            check(props?[kCGImagePropertyGPSDictionary as String] == nil, "\(name) sin datos GPS")
        }
    }

    private func ocr() async throws {
        let f = try await launchFixture("static")
        defer { stop(f) }
        let r = CGRect(x: f.content.minX, y: f.content.minY + 200, width: f.content.width, height: 200)
        let img = try await ScreenCaptureAdapter.capture(display: mainDisplay, rect: r, showsCursor: false)
        savePNG(img, "ocr-source.png")
        let res = try await TextRecognizer.recognize(img)
        note("Texto: \(res.text.replacingOccurrences(of: "\n", with: " | "))")
        check(res.text.contains("NativeShot QA 2026"), "Reconoce «NativeShot QA 2026»")
        check(res.text.contains("Número de pedido 4815"), "Reconoce acentos: «Número de pedido 4815»")
        check(res.text.contains("Canción año acción"), "Reconoce ñ y tildes: «Canción año acción»")
        check(res.barcodes.contains(QAFixture.qrPayload), "Lee el QR: \(res.barcodes)")
        // Full flow through the app: result goes to the clipboard, never opens the URL.
        let frontBefore = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        await app.capture(.region(r, display: mainDisplay), purpose: .textRecognition)
        let pb = NSPasteboard.general.string(forType: .string) ?? ""
        check(pb.contains("NativeShot QA 2026") && pb.contains(QAFixture.qrPayload), "El flujo «Capturar texto» copia texto y QR")
        try await Task.sleep(for: .milliseconds(500))
        check(NSWorkspace.shared.frontmostApplication?.bundleIdentifier == frontBefore, "No se abrió ningún navegador con la URL del QR")
    }

    private func history() async throws {
        let f = try await launchFixture("static")
        defer { stop(f) }
        await app.capture(.region(f.content, display: mainDisplay), purpose: .region)
        let c = try XCTUnwrap(app.qaLastCapture, "captura")
        let store = try XCTUnwrap(app.library.store, "almacén")
        let found = await waitUntilAsync(20) { (try? await store.search(HistoryQuery(text: "numero pedido")))?.contains { $0.id == c.id } == true }
        check(found, "El OCR en segundo plano indexa la captura y «numero pedido» (sin tilde) la encuentra")
        let thumb = Thumbnails.url(for: c.id, root: app.library.root)
        check(await waitUntilAsync(5) { FileManager.default.fileExists(atPath: thumb.path) }, "Miniatura en disco generada")
        app.delete(c)
        let trashed = await waitUntilAsync(5) { (try? await store.search(HistoryQuery()))?.contains { $0.id == c.id } == false }
        check(trashed, "«Eliminar» en la miniatura la manda a la papelera")
        let inTrash = (try? await store.search(HistoryQuery(includeDeleted: true)))?.contains { $0.id == c.id } == true
        check(inTrash, "Sigue recuperable en la papelera")
        try await store.restore(c.id)
        await app.library.refresh()
        check(app.library.recent.contains { $0.id == c.id }, "Restaurar la devuelve al historial")
    }

    private func waitUntilAsync(_ timeout: Double, _ cond: () async -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if await cond() { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return await cond()
    }

    private func editor() async throws {
        let f = try await launchFixture("static")
        defer { stop(f) }
        let r = CGRect(x: f.content.minX, y: f.content.minY + 200, width: f.content.width, height: 200)
        let img = try await ScreenCaptureAdapter.capture(display: mainDisplay, rect: r, showsCursor: false)
        let s = f.scale
        for kind in [AnnotationKind.redact, .pixelate, .blur] {
            var doc = EditorDocument(original: img)
            // Cover the "Número de pedido" line (fixture y 270…300 → 70…100 within the captured strip).
            doc.objects = [Annotation(kind: kind, start: CGPoint(x: 10 * s, y: 62 * s), end: CGPoint(x: 400 * s, y: 104 * s))]
            let flat = try XCTUnwrap(EditorRenderer.render(doc), "render")
            let url = out.appendingPathComponent("editor-\(kind.rawValue).png")
            try ImageExporter.encode(flat, format: .png).write(to: url)
            let back = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }, "relectura")
            let text = try await TextRecognizer.recognize(back).text
            check(!text.contains("4815") && !text.lowercased().contains("pedido"), "\(kind.rawValue): el texto censurado no es legible por OCR tras exportar (leído: \(text.replacingOccurrences(of: "\n", with: " | ")))")
            check(text.contains("NativeShot QA 2026"), "\(kind.rawValue): el resto de la imagen sigue intacto")
        }
        ImageEditorController.edit(img)
        try await Task.sleep(for: .milliseconds(800))
        if let w = NSApp.windows.first(where: { $0 is EditorWindow && $0.isVisible }) {
            await snapshot(w, "ui-editor")
            check(true, "Ventana del editor abierta")
        } else { check(false, "Ventana del editor abierta") }
    }

    private func pins() async throws {
        let c = try XCTUnwrap(app.qaLastCapture, "captura")
        let before = app.qaPins
        app.pin(c)
        try await Task.sleep(for: .milliseconds(300))
        check(app.qaPins == before + 1, "Se abre un pin")
        if let p = NSApp.windows.compactMap({ $0 as? PinPanel }).last {
            check(p.level == .floating, "El pin flota sobre las ventanas normales")
            p.close()
        }
        check(app.qaPins == before, "Cerrar el pin lo elimina")
    }

    // MARK: Recording

    private var lastVideo: URL?

    private func recording(webcam: Bool, mic: Bool) async throws {
        if mic && AVCaptureDevice.authorizationStatus(for: .audio) == .denied { throw Skip(reason: "micrófono denegado") }
        if webcam {
            let cams = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external], mediaType: .video, position: .unspecified).devices
            if cams.isEmpty { throw Skip(reason: "no hay cámara") }
            if AVCaptureDevice.authorizationStatus(for: .video) == .denied { throw Skip(reason: "cámara denegada") }
        }
        let f = try await launchFixture("audio")
        defer { stop(f) }
        let d = UserDefaults.standard
        for (k, v) in [RecorderPrefs.systemAudio: true, RecorderPrefs.microphone: mic, RecorderPrefs.webcam: webcam, RecorderPrefs.clicks: true] as [String: Bool] {
            savedDefaults[k] = savedDefaults[k] ?? d.object(forKey: k); d.set(v, forKey: k)
        }
        let rec = app.recorder
        let source: SelectionResult = webcam ? .display(mainDisplay) : .region(f.content, display: mainDisplay)
        rec.qaSet(source: source)
        rec.start()
        let started = await waitUntil(webcam || mic ? 30 : 10) { rec.phase == .recording }
        check(started, "La grabación arranca (fase \(rec.phase))")
        guard started else { return }
        if webcam { check(!rec.qaOverlayWindowIDs.isEmpty, "La burbuja de cámara se incluye en el stream (\(rec.qaOverlayWindowIDs.count) ventanas)") }
        try await Task.sleep(for: .seconds(1))
        if !mic && !webcam, let bar = window(hosting: "RecordingBarView") { await snapshot(bar, "ui-recording-bar") }
        try await Task.sleep(for: .seconds(3))
        rec.togglePause()
        check(await waitUntil(2) { rec.phase == .paused }, "Pausa")
        try await Task.sleep(for: .seconds(1.5))
        rec.togglePause()
        check(await waitUntil(2) { rec.phase == .recording }, "Reanudar")
        try await Task.sleep(for: .seconds(1.5))
        rec.stop()
        rec.stop() // double press must be harmless
        var sawFinalizing = false
        let done = await waitUntil(20) {
            if rec.phase == .finalizing { sawFinalizing = true }
            return rec.phase == .ready || (sawFinalizing && rec.phase == .idle)
        }
        check(done, "Finaliza (fase \(rec.phase))")
        await app.library.refresh()
        guard let a = app.library.recent.first(where: { $0.type == .video }) else { check(false, "El vídeo está en el historial"); return }
        let url = app.library.url(for: a)
        lastVideo = url
        check(FileManager.default.fileExists(atPath: Thumbnails.url(for: a.id, root: app.library.root).path), "El vídeo tiene miniatura en la biblioteca")
        let asset = AVURLAsset(url: url)
        let dur = try await asset.load(.duration).seconds
        check(dur > 4.5 && dur < 7.5, String(format: "Duración sin la pausa ≈ 5,5 s (%.2f s)", dur))
        let v = try await asset.loadTracks(withMediaType: .video)
        let au = try await asset.loadTracks(withMediaType: .audio)
        if let vt = v.first {
            let size = try await vt.load(.naturalSize)
            note("Vídeo \(Int(size.width))×\(Int(size.height))")
            if !webcam { check(abs(Int(size.width) - Int(f.content.width * f.scale) & ~1) <= 2, "Resolución = región × escala") }
        } else { check(false, "Pista de vídeo") }
        check(au.count == (mic ? 2 : 1), "Pistas de audio: \(au.count) (esperado \(mic ? 2 : 1))")
        if let sys = au.first {
            let peak = try await audioPeak(asset: asset, track: sys)
            check(peak > 0.01, String(format: "El audio del sistema contiene el tono de prueba (pico %.3f)", peak))
        }
        if mic, au.count > 1 {
            let peak = try await audioPeak(asset: asset, track: au[1])
            note(String(format: "Pico del micrófono: %.4f (ruido ambiente)", peak))
            check(peak > 0.0001, "El micrófono registra señal")
        }
        if let frame = try? await AVAssetImageGenerator(asset: asset).image(at: CMTime(seconds: 2, preferredTimescale: 600)).image {
            savePNG(downscale(frame, maxWidth: 1400), "rec-\(webcam ? "webcam" : mic ? "mic" : "region")-frame.png")
        }
        if !mic && !webcam, let r = NSApp.windows.first(where: { $0 is RecordingResultPanel && $0.isVisible }) { await snapshot(r, "ui-recording-result") }
        // Results panel must not stay on top of the next steps.
        for w in NSApp.windows where w is RecordingResultPanel { w.orderOut(nil) }
    }

    private func audioPeak(asset: AVURLAsset, track: AVAssetTrack) async throws -> Float {
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32,
                                                                          AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false])
        reader.add(out)
        reader.startReading()
        var peak: Float = 0
        while let sb = out.copyNextSampleBuffer() {
            peak = max(peak, AudioMeter.peak(sb))
        }
        return peak
    }

    private func gif() async throws {
        let src = try XCTUnwrap(lastVideo, "hay un vídeo grabado")
        let dst = out.appendingPathComponent("rec.gif")
        let r = try await GIFExporter.export(video: src, to: dst, options: .init(fps: 10, maxWidth: 480))
        check(r.frames >= 40, "GIF con \(r.frames) fotogramas")
        let n = CGImageSourceCreateWithURL(dst as CFURL, nil).map(CGImageSourceGetCount) ?? 0
        check(n == r.frames, "El GIF se puede abrir y tiene los fotogramas declarados (\(n))")
        note("Tamaño: \(r.byteSize / 1024) KB")
    }

    private func videoExport() async throws {
        let src = try XCTUnwrap(lastVideo, "hay un vídeo grabado")
        let dur = try await AVURLAsset(url: src).load(.duration).seconds
        var p = VideoProject(duration: dur)
        p.zooms = AutoZoom.suggest(clicks: [VideoClickEvent(t: 1, x: 0.3, y: 0.4), VideoClickEvent(t: 1.4, x: 0.32, y: 0.42)], duration: dur)
        check(!p.zooms.isEmpty, "El zoom automático propone keyframes")
        let dst = out.appendingPathComponent("video-export.mp4")
        try? FileManager.default.removeItem(at: dst)
        try await VideoExporter.export(project: p, source: src, preset: .tutorial, to: dst) { _, _ in }
        let outDur = try await AVURLAsset(url: dst).load(.duration).seconds
        check(abs(outDur - dur) < 0.5, String(format: "Exportado con la misma duración (%.2f s)", outDur))
        VideoEditorController.open(url: src, library: app.library)
        try await Task.sleep(for: .seconds(1.5))
        if let w = NSApp.windows.first(where: { $0.isVisible && $0.contentView is NSHostingView<VideoEditorView> }) ?? NSApp.windows.last(where: { $0.isVisible && $0.title.contains(".mp4") || $0.title.contains("vídeo") }) {
            await snapshot(w, "ui-video-editor")
        }
        let events = VideoClickEvents.sidecarURL(forSource: src)
        note("events.json de la grabadora: \(FileManager.default.fileExists(atPath: events.path) ? "presente" : "ausente (sin clics durante la grabación)")")
    }

    // MARK: Synthetic input (needs Accessibility)

    private func requireAX() throws {
        if !AXIsProcessTrusted() {
            AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            throw Skip(reason: "NativeShot necesita permiso de Accesibilidad para enviar eventos sintéticos (solicitado)")
        }
    }

    private func key(_ code: Int, _ flags: CGEventFlags) {
        let src = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(code), keyDown: true)!
        down.flags = flags
        let up = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(code), keyDown: false)!
        up.flags = flags
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
    }

    /// Virtual key that types `char` in the current keyboard layout (⌘+ is not on kVK_ANSI_Equal in a Spanish layout).
    private func keyCode(for char: Character) -> Int? {
        guard let src = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        return data.withUnsafeBytes { raw -> Int? in
            let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress!
            for code in 0..<128 {
                for mods: UInt32 in [0, UInt32(shiftKey >> 8)] {
                    var dead: UInt32 = 0, len = 0
                    var chars = [UniChar](repeating: 0, count: 4)
                    UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDown), mods, UInt32(LMGetKbdType()),
                                   OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &len, &chars)
                    if mods == 0, len == 1, Character(UnicodeScalar(chars[0])!) == char { return code }
                }
            }
            return nil
        }
    }

    private func mouse(_ type: CGEventType, _ p: CGPoint, _ flags: CGEventFlags? = nil) {
        let e = CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState), mouseType: type, mouseCursorPosition: p, mouseButton: .left)!
        if let flags { e.flags = flags }
        e.post(tap: .cghidEventTap)
    }

    private func drag(from a: CGPoint, to b: CGPoint, flags: CGEventFlags? = nil) async {
        mouse(.mouseMoved, a, flags)
        try? await Task.sleep(for: .milliseconds(120))
        mouse(.leftMouseDown, a, flags)
        for i in 1...12 {
            let t = CGFloat(i) / 12
            mouse(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t), flags)
            try? await Task.sleep(for: .milliseconds(16))
        }
        mouse(.leftMouseUp, b, flags)
    }

    /// A bare modifier transition (flagsChanged), e.g. releasing ⌘ after the shortcut.
    private func modifier(_ code: Int, down: Bool, _ flags: CGEventFlags) {
        let e = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: CGKeyCode(code), keyDown: down)!
        e.type = .flagsChanged; e.flags = flags
        e.post(tap: .cghidEventTap)
    }

    private func setDefault(_ k: String, _ v: Any) {
        let d = UserDefaults.standard
        savedDefaults[k] = savedDefaults[k] ?? d.object(forKey: k); d.set(v, forKey: k)
    }

    /// Every AXValue/AXTitle/AXDescription string under our window titled `w.title`.
    private func axTexts(_ w: NSWindow) -> [String] {
        func attr(_ e: AXUIElement, _ a: String) -> AnyObject? { var v: AnyObject?; AXUIElementCopyAttributeValue(e, a as CFString, &v); return v }
        let windows = (attr(AXUIElementCreateApplication(getpid()), "AXWindows") as? [AXUIElement]) ?? []
        guard let root = windows.first(where: { attr($0, "AXTitle") as? String == w.title }) else { return [] }
        var out: [String] = []
        func walk(_ e: AXUIElement, _ depth: Int) {
            guard depth < 30, out.count < 2000 else { return }
            for a in ["AXValue", "AXTitle", "AXDescription"] { if let s = attr(e, a) as? String, !s.isEmpty { out.append(s) } }
            for c in (attr(e, "AXChildren") as? [AXUIElement]) ?? [] { walk(c, depth + 1) }
        }
        walk(root, 0)
        return out
    }

    // MARK: Wave 3

    /// CAP-011: ⌘-drag sets regions aside; Return hands them over as one composition. ⌘ held from the shortcut must not count.
    private func multiRegion() async throws {
        try requireAX()
        let f = try await launchFixture("static")
        defer { stop(f) }
        setDefault(Prefs.multiRegionJoin, true)
        let before = app.qaLastCapture?.id
        key(kVK_ANSI_4, hyper)
        check(await waitUntil(3) { self.app.qaOverlayActive }, "Overlay abierto")
        try await Task.sleep(for: .milliseconds(250))
        modifier(kVK_Command, down: false, [])
        modifier(kVK_Command, down: true, .maskCommand)
        let c = f.content
        await drag(from: CGPoint(x: c.minX + 20, y: c.minY + 20), to: CGPoint(x: c.minX + 120, y: c.minY + 100), flags: .maskCommand)
        try await Task.sleep(for: .milliseconds(150))
        check(app.qaOverlayActive, "Soltar con ⌘ guarda la región y sigue seleccionando")
        await drag(from: CGPoint(x: c.maxX - 120, y: c.maxY - 100), to: CGPoint(x: c.maxX - 20, y: c.maxY - 20), flags: .maskCommand)
        modifier(kVK_Command, down: false, [])
        try await Task.sleep(for: .milliseconds(150))
        check(app.qaOverlayActive, "Segunda región guardada")
        key(kVK_Return, [])
        let got = await waitUntil(5) { self.app.qaLastCapture?.id != before && self.app.qaIdle }
        check(got, "Return entrega las regiones")
        if got, let img = app.qaLastCapture?.image {
            let one = Int(100 * f.scale)
            check(img.width >= 2 * one - 2 || img.height >= 2 * Int(80 * f.scale) - 2, "Una composición con las 2 regiones: \(img.width)×\(img.height) (cada una \(one)×\(Int(80 * f.scale)))")
            savePNG(img, "multi-region.png")
        }
    }

    /// CAP-010: with «freeze» on, the capture is cut from the snapshot taken when the overlay opened.
    private func freeze() async throws {
        try requireAX()
        let f = try await launchFixture("static")
        defer { stop(f) }
        setDefault(Prefs.freezeScreen, true)
        let before = app.qaLastCapture?.id
        key(kVK_ANSI_4, hyper)
        check(await waitUntil(3) { self.app.qaOverlayActive }, "Overlay abierto con la pantalla congelada")
        try await Task.sleep(for: .milliseconds(400))
        if let ov = NSApp.windows.first(where: { $0 is OverlayPanel && $0.isVisible }) { await snapshot(ov, "ui-overlay-frozen", crop: f.frame.insetBy(dx: -60, dy: -60)) }
        await drag(from: CGPoint(x: f.content.minX + 20, y: f.content.minY + 20), to: CGPoint(x: f.content.minX + 300, y: f.content.minY + 180))
        let got = await waitUntil(5) { self.app.qaLastCapture?.id != before && self.app.qaIdle }
        check(got, "Arrastrar sobre la pantalla congelada produce una captura")
        if got, let c = app.qaLastCapture {
            check(abs(c.image.width - Int(280 * f.scale)) <= 2, "Tamaño correcto: \(c.image.width)×\(c.image.height)")
            check(dominant(Pixels(c.image).at(10, 10)) == "red", "Contenido real (rojo), sin el oscurecido del overlay")
        }
        setDefault(Prefs.freezeScreen, false)
    }

    /// HIS: in a private session nothing reaches the library.
    private func privateSession() async throws {
        let f = try await launchFixture("static")
        defer { stop(f); app.privateSession = false }
        await app.library.refresh()
        let first = app.library.recent.first?.id
        app.privateSession = true
        let before = app.qaLastCapture?.id
        await app.capture(.region(CGRect(x: f.content.minX, y: f.content.minY, width: 200, height: 120), display: mainDisplay), purpose: .region)
        check(app.qaLastCapture?.id != before, "La captura se hace igualmente")
        await app.library.refresh()
        check(app.library.recent.first?.id == first, "No aparece en la biblioteca")
        // Recordings too: they go to the save folder, never to the library.
        let saved = Set((try? FileManager.default.contentsOfDirectory(atPath: Prefs.saveFolderURL.path)) ?? [])
        let rec = app.recorder
        rec.qaSet(source: .region(f.content, display: mainDisplay))
        rec.start()
        if await waitUntil(10, { rec.phase == .recording }) {
            try await Task.sleep(for: .seconds(2))
            rec.stop()
            _ = await waitUntil(20) { rec.phase == .ready || rec.phase == .idle }
            await app.library.refresh()
            check(app.library.recent.first?.id == first, "La grabación tampoco aparece en la biblioteca")
            let now = Set((try? FileManager.default.contentsOfDirectory(atPath: Prefs.saveFolderURL.path)) ?? [])
            check(now.subtracting(saved).contains { $0.hasSuffix(".mp4") }, "La grabación se guarda en la carpeta elegida")
        } else { check(false, "La grabación arranca en sesión privada") }
        app.privateSession = false
    }

    /// PIN-001: a locked pin lets clicks through and is unlocked from the app.
    private func pinLock() async throws {
        let c = try XCTUnwrap(app.qaLastCapture, "captura")
        app.pin(c)
        try await Task.sleep(for: .milliseconds(300))
        let p = try XCTUnwrap(NSApp.windows.compactMap({ $0 as? PinPanel }).last, "pin")
        app.setPinsLocked(true)
        check(p.ignoresMouseEvents, "Bloqueado: los clics lo atraviesan")
        app.setPinsLocked(false)
        check(!p.ignoresMouseEvents, "Desbloqueado: vuelve a recibir clics")
        p.close()
    }

    /// UI-07 / UI-19: the OCR result window and the export manager open with content.
    private func toolWindows() async throws {
        let f = try await launchFixture("static")
        defer { stop(f) }
        await app.capture(.region(f.content, display: mainDisplay), purpose: .region)
        let c = try XCTUnwrap(app.qaLastCapture, "captura")
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            NSApp.appearance = NSAppearance(named: appearance)
            let tag = appearance == .aqua ? "light" : "dark"
            app.recognizeText(c)
            let ocrTitle = String(localized: "Texto reconocido")
            check(await waitUntil(5) { NSApp.windows.contains { $0.isVisible && $0.title == ocrTitle } }, "Se abre la ventana de texto reconocido (\(tag))")
            try await Task.sleep(for: .milliseconds(600))
            if let w = NSApp.windows.first(where: { $0.isVisible && $0.title == ocrTitle }) {
                check(axTexts(w).contains { $0.contains("4815") }, "La ventana muestra el texto reconocido")
                await snapshot(w, "ui-ocr-\(tag)"); w.close()
            }
            ExportManager.show(image: c.image)
            let exTitle = String(localized: "Exportar captura")
            try await Task.sleep(for: .milliseconds(700))
            if let w = NSApp.windows.first(where: { $0.isVisible && $0.title == exTitle }) {
                check(w.frame.width > 300 && w.frame.height > 300, "Gestor de exportación visible: \(w.frame.size)")
                await snapshot(w, "ui-export-\(tag)"); w.close()
            } else { check(false, "Se abre el gestor de exportación (\(tag))") }
        }
        NSApp.appearance = nil
    }

    private let hyper: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]

    private func hotkeyFlow() async throws {
        try requireAX()
        let f = try await launchFixture("static")
        defer { stop(f) }
        let before = app.qaLastCapture?.id
        key(kVK_ANSI_4, hyper)
        check(await waitUntil(3) { self.app.qaOverlayActive }, "⌃⌥⌘4 abre el overlay de selección")
        try await Task.sleep(for: .milliseconds(250))
        if let ov = NSApp.windows.first(where: { $0 is OverlayPanel && $0.isVisible }) { await snapshot(ov, "ui-overlay", crop: f.frame.insetBy(dx: -60, dy: -60)) }
        if let bar = NSApp.windows.first(where: { $0 is ModeBarPanel && $0.isVisible }) { await snapshot(bar, "ui-modebar") }
        let a = CGPoint(x: f.content.minX + 20, y: f.content.minY + 20), b = CGPoint(x: f.content.minX + 300, y: f.content.minY + 180)
        await drag(from: a, to: b)
        let got = await waitUntil(5) { self.app.qaLastCapture?.id != before && self.app.qaIdle }
        check(got, "Arrastrar produce una captura")
        if let c = app.qaLastCapture, got {
            check(abs(c.image.width - Int(280 * f.scale)) <= 2 && abs(c.image.height - Int(160 * f.scale)) <= 2, "Tamaño del arrastre: \(c.image.width)×\(c.image.height) ≈ \(Int(280 * f.scale))×\(Int(160 * f.scale))")
            check(dominant(Pixels(c.image).at(10, 10)) == "red", "La esquina de la selección cae donde se arrastró (rojo)")
            check(app.qaThumbnails > 0, "Miniatura visible tras el arrastre")
            try await Task.sleep(for: .milliseconds(300)) // fade-in finished
            if let t = NSApp.windows.last(where: { $0 is ThumbnailPanel && $0.isVisible }) {
                check(t.alphaValue > 0.99 && t.frame.width > 150 && t.frame.height > 80, "La miniatura es visible: alfa \(t.alphaValue), marco \(t.frame)")
                await snapshot(t, "ui-thumbnail")
            }
        }
        // Paste into another app: TextEdit receives the image from the clipboard.
        if let c = app.qaLastCapture {
            app.copy(c)
            let types = NSPasteboard.general.types ?? []
            check(types.contains(.tiff) || types.contains(.png), "El portapapeles ofrece la imagen como \(types.map(\.rawValue).prefix(3))")
        }
    }

    private func escCancels() async throws {
        try requireAX()
        let before = app.qaLastCapture?.id
        key(kVK_ANSI_4, hyper)
        check(await waitUntil(3) { self.app.qaOverlayActive }, "Overlay abierto")
        try await Task.sleep(for: .milliseconds(200))
        key(kVK_Escape, [])
        check(await waitUntil(2) { !self.app.qaOverlayActive && self.app.qaIdle }, "Esc cierra el overlay")
        try await Task.sleep(for: .milliseconds(300))
        check(app.qaLastCapture?.id == before, "Esc no produce captura")
    }

    private func hotkeyWindow() async throws {
        try requireAX()
        let f = try await launchFixture("static")
        defer { stop(f) }
        let before = app.qaLastCapture?.id
        let center = CGPoint(x: f.content.midX, y: f.content.midY)
        mouse(.mouseMoved, center)
        key(kVK_ANSI_6, hyper)
        check(await waitUntil(3) { self.app.qaOverlayActive }, "⌃⌥⌘6 abre el modo ventana")
        try await Task.sleep(for: .milliseconds(300))
        if let ov = NSApp.windows.first(where: { $0 is OverlayPanel && $0.isVisible }) { await snapshot(ov, "ui-overlay-window", crop: f.frame.insetBy(dx: -60, dy: -60)) }
        mouse(.leftMouseDown, center); mouse(.leftMouseUp, center)
        let got = await waitUntil(5) { self.app.qaLastCapture?.id != before && self.app.qaIdle }
        check(got, "Clic sobre la ventana la captura")
        if let c = app.qaLastCapture, got {
            check(c.image.width >= Int(f.frame.width * f.scale) - 2, "Es la ventana completa (\(c.image.width)×\(c.image.height))")
        }
    }

    private func scrollCapture() async throws {
        try requireAX()
        let f = try await launchFixture("scroll")
        defer { stop(f) }
        let scroll = app.scroll
        var outcome: ScrollCaptureController.Outcome?
        var failure: Error?
        let task = Task { @MainActor in
            do { outcome = try await scroll.run(display: self.mainDisplay, rect: f.content) } catch { failure = error }
        }
        try await Task.sleep(for: .milliseconds(800))
        let center = CGPoint(x: f.content.midX, y: f.content.midY)
        mouse(.mouseMoved, center)
        // ~30 rows down, in steps the aligner can follow (each step well under one viewport).
        for _ in 0..<40 {
            let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -40, wheel2: 0, wheel3: 0)!
            e.location = center
            e.post(tap: .cghidEventTap)
            try await Task.sleep(for: .milliseconds(110))
        }
        try await Task.sleep(for: .milliseconds(700))
        if let sp = NSApp.windows.first(where: { $0 is ScrollPanel && $0.isVisible }) { await snapshot(sp, "ui-scroll-panel") }
        scroll.qaFinish()
        await task.value
        if let failure { check(false, "Sesión de scroll sin error: \(failure.localizedDescription)"); return }
        let o = try XCTUnwrap(outcome, "resultado")
        note("Partes: \(o.parts.count), rechazados: \(o.rejected.count)")
        for (i, r) in o.rejected.enumerated() { savePNG(r, "scroll-rejected-\(i).png") }
        let img = try XCTUnwrap(o.parts.last, "imagen unida")
        savePNG(img, "scroll-stitched.png")
        let viewportPx = Int(f.content.height * f.scale)
        check(img.height > viewportPx * 2, "La imagen unida es más alta que 2 viewports (\(img.height) px vs \(viewportPx))")
        check(img.width == Int(f.content.width * f.scale), "Ancho = región")
        let text = try await TextRecognizer.recognize(img).text
        let rows = text.components(separatedBy: .newlines).compactMap { l -> Int? in
            guard let r = l.range(of: #"FILA \d{4}"#, options: .regularExpression) else { return nil }
            return Int(l[r].dropFirst(5))
        }
        let unique = Set(rows)
        check(rows.first == 1, "Empieza en FILA 0001 (\(rows.first.map(String.init) ?? "—"))")
        check(rows.count == unique.count, "Ninguna fila duplicada por la unión (\(rows.count) leídas, \(unique.count) únicas)")
        if let mx = unique.max() {
            let missing = (1...mx).filter { !unique.contains($0) }
            check(missing.count <= max(1, mx / 20), "Sin huecos: faltan \(missing.prefix(10)) de 1…\(mx) (OCR puede saltarse alguna)")
        }
    }

    private func latency() async throws {
        try requireAX()
        let f = try await launchFixture("static")
        defer { stop(f) }
        var toOverlay: [Double] = [], toThumb: [Double] = []
        for i in 0..<8 {
            let before = app.qaLastCapture?.id
            let t0 = CFAbsoluteTimeGetCurrent()
            key(kVK_ANSI_4, hyper)
            guard await waitUntil(3, { self.app.qaOverlayActive && NSApp.windows.contains { $0 is OverlayPanel && $0.isVisible } }) else { continue }
            toOverlay.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            try await Task.sleep(for: .milliseconds(150))
            let a = CGPoint(x: f.content.minX + 20 + CGFloat(i), y: f.content.minY + 20)
            let b = CGPoint(x: a.x + 300, y: a.y + 170)
            mouse(.mouseMoved, a); mouse(.leftMouseDown, a); mouse(.leftMouseDragged, CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)); mouse(.leftMouseDragged, b)
            let t1 = CFAbsoluteTimeGetCurrent()
            mouse(.leftMouseUp, b)
            guard await waitUntil(5, { self.app.qaLastCapture?.id != before && self.app.qaThumbnails > 0 }) else { continue }
            toThumb.append((CFAbsoluteTimeGetCurrent() - t1) * 1000)
            _ = await waitUntil(3) { self.app.qaIdle }
            closeTransientWindows()
            try await Task.sleep(for: .milliseconds(300))
        }
        func p(_ a: [Double], _ q: Double) -> Double { let s = a.sorted(); return s.isEmpty ? .nan : s[min(s.count - 1, Int(Double(s.count) * q))] }
        note(String(format: "Atajo→overlay visible: p50 %.0f ms, p95 %.0f ms (n=%d). objetivo: p50 ≤ 120, p95 ≤ 250", p(toOverlay, 0.5), p(toOverlay, 0.95), toOverlay.count))
        note(String(format: "Soltar→miniatura visible: p50 %.0f ms, p95 %.0f ms (n=%d). objetivo: p50 ≤ 300, p95 ≤ 600", p(toThumb, 0.5), p(toThumb, 0.95), toThumb.count))
        check(toOverlay.count >= 6 && toThumb.count >= 6, "Mediciones completas")
        check(p(toOverlay, 0.5) <= 120, "Atajo→overlay dentro del objetivo p50")
        check(p(toThumb, 0.5) <= 300, "Selección→miniatura dentro del objetivo p50")
    }

    // MARK: More manual cases

    private func thumbnailKeys() async throws {
        try requireAX()
        let f = try await launchFixture("static")
        defer { stop(f) }
        await app.capture(.region(CGRect(x: f.content.minX, y: f.content.minY, width: 200, height: 100), display: mainDisplay), purpose: .region)
        let n = app.qaThumbnails
        check(n > 0, "Miniatura abierta")
        app.focusThumbnail()
        try await Task.sleep(for: .milliseconds(300))
        key(kVK_Escape, [])
        check(await waitUntil(2) { self.app.qaThumbnails == n - 1 }, "Esc con la miniatura enfocada la cierra (\(app.qaThumbnails))")
        app.restoreLastThumbnail()
        try await Task.sleep(for: .milliseconds(300))
        check(app.qaThumbnails == n, "«Restaurar última miniatura» la recupera")
        app.focusThumbnail()
        try await Task.sleep(for: .milliseconds(300))
        let pbBefore = NSPasteboard.general.changeCount
        key(kVK_ANSI_C, .maskCommand)
        check(await waitUntil(2) { NSPasteboard.general.changeCount != pbBefore }, "⌘C en la miniatura enfocada copia la imagen")
    }

    private func pinKeys() async throws {
        try requireAX()
        let c = try XCTUnwrap(app.qaLastCapture, "captura")
        app.closeAllPins()
        app.pin(c)
        try await Task.sleep(for: .milliseconds(400))
        let p = try XCTUnwrap(NSApp.windows.compactMap { $0 as? PinPanel }.last { $0.isVisible }, "pin")
        // Click it first, as a user would, so it receives the keyboard.
        let center = CGPoint(x: p.frame.midX, y: NSScreen.primaryHeight - p.frame.midY)
        mouse(.mouseMoved, center); mouse(.leftMouseDown, center); mouse(.leftMouseUp, center)
        try await Task.sleep(for: .milliseconds(300))
        let w0 = p.frame.width
        let plus = keyCode(for: "+") ?? kVK_ANSI_Equal, minus = keyCode(for: "-") ?? kVK_ANSI_Minus
        note("Teclas según la distribución: + = \(plus), - = \(minus)")
        key(plus, .maskCommand)
        try await Task.sleep(for: .milliseconds(300))
        check(p.frame.width > w0 * 1.05, String(format: "⌘+ amplía el pin (%.0f → %.0f pt)", w0, p.frame.width))
        let w1 = p.frame.width
        key(minus, .maskCommand)
        try await Task.sleep(for: .milliseconds(300))
        check(p.frame.width < w1 * 0.95, String(format: "⌘− reduce el pin (%.0f → %.0f pt)", w1, p.frame.width))
        check(abs(p.frame.width / p.frame.height - CGFloat(c.image.width) / CGFloat(c.image.height)) < 0.02, "Mantiene la proporción")
        if let item = p.contentView?.menu?.items.first(where: { $0.tag == 50 }), let action = item.action {
            NSApp.sendAction(action, to: item.target, from: item)
            check(abs(p.alphaValue - 0.5) < 0.01, "Opacidad 50 % desde el menú contextual")
        } else { check(false, "Menú contextual con opacidad") }
        key(kVK_Escape, [])
        check(await waitUntil(2) { self.app.qaPins == 0 }, "Esc cierra el pin")
        app.pin(c)
        try await Task.sleep(for: .milliseconds(400))
        if let p2 = NSApp.windows.compactMap({ $0 as? PinPanel }).last(where: { $0.isVisible }) {
            let c2 = CGPoint(x: p2.frame.midX, y: NSScreen.primaryHeight - p2.frame.midY)
            mouse(.mouseMoved, c2); mouse(.leftMouseDown, c2); mouse(.leftMouseUp, c2)
            try await Task.sleep(for: .milliseconds(300))
        }
        key(kVK_ANSI_W, .maskCommand)
        check(await waitUntil(2) { self.app.qaPins == 0 }, "⌘W cierra el pin")
        app.pin(c); app.pin(c)
        try await Task.sleep(for: .milliseconds(300))
        check(app.qaPins == 2, "Dos pines abiertos")
        app.closeAllPins()
        check(app.qaPins == 0, "«Cerrar imágenes fijadas» los cierra todos")
    }

    private func pasteIntoTextView() async throws {
        try requireAX()
        let c = try XCTUnwrap(app.qaLastCapture, "captura")
        app.copy(c)
        let f = try await launchFixture("paste")
        defer { stop(f) }
        try await Task.sleep(for: .milliseconds(600))
        let target = CGPoint(x: f.content.midX, y: f.content.midY)
        mouse(.mouseMoved, target); mouse(.leftMouseDown, target); mouse(.leftMouseUp, target)
        try await Task.sleep(for: .milliseconds(300))
        key(kVK_ANSI_V, .maskCommand)
        let line = await nextLine(f, timeout: 4)
        if let img = try? await captureIncludingOwn(SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true), f.frame) { savePNG(img, "paste-target.png") }
        note("Tipos en el portapapeles: \((NSPasteboard.general.types ?? []).map(\.rawValue))")
        let atts = line?["attachments"] as? [[Double]] ?? []
        check(atts.count == 1, "Se pega una imagen (\(atts.count) adjuntos)")
        if let a = atts.first { check(Int(a[0]) == c.image.width && Int(a[1]) == c.image.height, "A tamaño completo: \(Int(a[0]))×\(Int(a[1])) px") }
    }

    private func countdown() async throws {
        let f = try await launchFixture("audio")
        defer { stop(f) }
        let d = UserDefaults.standard
        savedDefaults[RecorderPrefs.countdown] = savedDefaults[RecorderPrefs.countdown] ?? d.object(forKey: RecorderPrefs.countdown)
        d.set(3, forKey: RecorderPrefs.countdown)
        defer { d.set(0, forKey: RecorderPrefs.countdown) }
        let rec = app.recorder
        rec.qaSet(source: .region(f.content, display: mainDisplay))
        let t0 = CFAbsoluteTimeGetCurrent()
        rec.start()
        check(await waitUntil(3) { rec.phase == .countdown }, "Entra en cuenta atrás")
        check(await waitUntil(6) { rec.phase == .recording }, "Empieza a grabar al terminar")
        let waited = CFAbsoluteTimeGetCurrent() - t0
        check(waited > 2.7 && waited < 4.5, String(format: "La cuenta atrás dura ≈3 s (%.1f s)", waited))
        rec.qaCancel() // same path as «Descartar» in the confirmation alert
        let ended = await waitUntil(5) { rec.phase == .idle || rec.phase == .cancelled }
        check(ended, "Cancelar termina la sesión (fase \(rec.phase))")
    }

    private func scrollSession(_ f: Fixture, wheel: [Int32], finish: Bool) async throws -> ScrollCaptureController.Outcome? {
        let scroll = app.scroll
        var outcome: ScrollCaptureController.Outcome?
        var failure: Error?
        let task = Task { @MainActor in
            do { outcome = try await scroll.run(display: self.mainDisplay, rect: f.content) } catch { failure = error }
        }
        try await Task.sleep(for: .milliseconds(800))
        let center = CGPoint(x: f.content.midX, y: f.content.midY)
        mouse(.mouseMoved, center)
        for dy in wheel {
            let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: dy, wheel2: 0, wheel3: 0)!
            e.location = center
            e.post(tap: .cghidEventTap)
            try await Task.sleep(for: .milliseconds(110))
        }
        try await Task.sleep(for: .milliseconds(700))
        if finish { scroll.qaFinish() } else { scroll.qaCancel() }
        await task.value
        if let failure { throw failure }
        return outcome
    }

    private func stitchedRows(_ img: CGImage) async throws -> [Int] {
        let text = try await TextRecognizer.recognize(img).text
        return text.components(separatedBy: .newlines).compactMap { l -> Int? in
            guard let r = l.range(of: #"FILA \d{4}"#, options: .regularExpression) else { return nil }
            return Int(l[r].dropFirst(5))
        }
    }

    private func scrollBack() async throws {
        try requireAX()
        let f = try await launchFixture("scroll")
        defer { stop(f) }
        let o = try XCTUnwrap(try await scrollSession(f, wheel: Array(repeating: -40, count: 20) + Array(repeating: 40, count: 8) + Array(repeating: -40, count: 16), finish: true), "resultado")
        let img = try XCTUnwrap(o.parts.last, "imagen")
        savePNG(img, "scroll-back.png")
        let rows = try await stitchedRows(img)
        check(rows.count == Set(rows).count, "Volver atrás no duplica filas (\(rows.count) leídas)")
        check(rows == rows.sorted(), "Las filas quedan en orden")
        check((rows.max() ?? 0) > 20, "Sigue avanzando tras volver (hasta FILA \(rows.max() ?? 0))")
    }

    private func scrollCancel() async throws {
        try requireAX()
        let f = try await launchFixture("scroll")
        defer { stop(f) }
        let before = app.library.recent.first?.id
        do {
            _ = try await scrollSession(f, wheel: Array(repeating: -40, count: 6), finish: false)
            check(false, "Cancelar debería abortar la sesión")
        } catch is CancellationError {
            check(true, "Cancelar aborta la sesión")
        }
        check(!NSApp.windows.contains { $0 is ScrollPanel && $0.isVisible }, "El panel de scroll se cierra")
        await app.library.refresh()
        check(app.library.recent.first?.id == before, "No se guarda nada en la biblioteca")
    }

    /// Walks our own accessibility tree (what VoiceOver reads) for every surface and flags unnamed controls.
    private func accessibilityAudit() async throws {
        try requireAX()
        let me = AXUIElementCreateApplication(getpid())
        func attr(_ e: AXUIElement, _ a: String) -> AnyObject? { var v: AnyObject?; AXUIElementCopyAttributeValue(e, a as CFString, &v); return v }
        let controls: Set<String> = ["AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXSlider", "AXTextField", "AXMenuButton", "AXSwitch", "AXToggle", "AXIncrementor", "AXColorWell"]
        func audit(_ root: AXUIElement, depth: Int = 0, into bad: inout [String], count: inout Int) {
            guard depth < 40 else { return }
            let role = attr(root, "AXRole") as? String ?? ""
            let sub = attr(root, "AXSubrole") as? String ?? ""
            let windowButtons: Set<String> = ["AXCloseButton", "AXMinimizeButton", "AXZoomButton", "AXFullScreenButton", "AXToolbarButton", "AXIncrementArrow", "AXDecrementArrow", "AXIncrementPage", "AXDecrementPage"] // system chrome
            if controls.contains(role), !windowButtons.contains(sub) {
                count += 1
                let names = ["AXTitle", "AXDescription", "AXLabel", "AXHelp", "AXValueDescription"].compactMap { attr(root, $0) as? String }.filter { !$0.isEmpty }
                let titled = (attr(root, "AXTitleUIElement") != nil)
                if names.isEmpty && !titled && role != "AXTextField" { var frame = CGRect.zero
                    if let v = attr(root, "AXFrame") { AXValueGetValue(v as! AXValue, .cgRect, &frame) }
                    let kids = ((attr(root, "AXChildren") as? [AXUIElement]) ?? []).compactMap { attr($0, "AXRole") as? String }
                    bad.append("\(role)/\(sub) \(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))×\(Int(frame.height)) hijos=\(kids)") }
            }
            for child in (attr(root, "AXChildren") as? [AXUIElement]) ?? [] { audit(child, depth: depth + 1, into: &bad, count: &count) }
        }
        let surfaces: [(String, () -> Void)] = [
            ("Bienvenida", { OnboardingWindow.show(app: self.app) }),
            ("Biblioteca", { LibraryWindowController.shared.show(app: self.app) }),
            ("Grabar pantalla", { self.app.recorder.showPanel() }),
            ("Ayuda y diagnóstico", { HelpWindow.show(app: self.app) }),
            ("Ajustes", { self.app.openSettings() }),
        ]
        for (name, open) in surfaces {
            let before = Set(NSApp.windows.filter(\.isVisible).map(\.windowNumber))
            open()
            try await Task.sleep(for: .milliseconds(1200))
            var bad: [String] = [], count = 0
            for w in (attr(me, "AXWindows") as? [AXUIElement]) ?? [] { audit(w, into: &bad, count: &count) }
            check(count > 0 && bad.isEmpty, "\(name): \(count) controles accesibles, sin nombre: \(bad.prefix(8))")
            for w in NSApp.windows where w.isVisible && !before.contains(w.windowNumber) { w.close() }
            OnboardingWindow.close()
        }
        // Floating thumbnail: hover-only buttons must still be reachable by name.
        let f = try await launchFixture("static")
        defer { stop(f) }
        await app.capture(.region(CGRect(x: f.content.minX, y: f.content.minY, width: 200, height: 100), display: mainDisplay), purpose: .region)
        try await Task.sleep(for: .milliseconds(500))
        if let t = NSApp.windows.last(where: { $0 is ThumbnailPanel && $0.isVisible }) {
            let actions = (t.contentView.map { [$0] + $0.subviews } ?? []).flatMap { $0.accessibilityCustomActions() ?? [] }
            var bad: [String] = [], count = 0
            for w in (attr(me, "AXWindows") as? [AXUIElement]) ?? [] { audit(w, into: &bad, count: &count) }
            var names: [String] = []
            for w in (attr(me, "AXWindows") as? [AXUIElement]) ?? [] {
                func collect(_ e: AXUIElement, _ d: Int) {
                    guard d < 30 else { return }
                    var v: CFArray?
                    if AXUIElementCopyActionNames(e, &v) == .success, let a = v as? [String] { names += a.filter { $0.hasPrefix("Name:") || !$0.hasPrefix("AX") } }
                    for c in (attr(e, "AXChildren") as? [AXUIElement]) ?? [] { collect(c, d + 1) }
                }
                collect(w, 0)
            }
            _ = actions
            note("Acciones de VoiceOver en la miniatura: \(names.prefix(8))")
            check(names.count >= 5, "La miniatura expone sus acciones (copiar, guardar, editar, fijar, compartir) al rotor")
        }
    }

    private func longRecording(seconds: Double) async throws {
        let f = try await launchFixture("animated")
        defer { stop(f) }
        let d = UserDefaults.standard
        for (k, v) in [RecorderPrefs.systemAudio: true, RecorderPrefs.microphone: false, RecorderPrefs.webcam: false] as [String: Bool] {
            savedDefaults[k] = savedDefaults[k] ?? d.object(forKey: k); d.set(v, forKey: k)
        }
        let rec = app.recorder
        rec.qaSet(source: .region(f.content, display: mainDisplay))
        rec.start()
        guard await waitUntil(15, { rec.phase == .recording }) else { check(false, "Arranca"); return }
        var rss: [Double] = []
        let t0 = Date()
        while Date().timeIntervalSince(t0) < seconds {
            try await Task.sleep(for: .seconds(10))
            rss.append(Self.residentMB())
        }
        rec.stop()
        var sawFinalizing = false
        let done = await waitUntil(60) {
            if rec.phase == .finalizing { sawFinalizing = true }
            return rec.phase == .ready || (sawFinalizing && rec.phase == .idle)
        }
        check(done, "Finaliza")
        await app.library.refresh()
        guard let a = app.library.recent.first(where: { $0.type == .video }) else { check(false, "Vídeo en la biblioteca"); return }
        let asset = AVURLAsset(url: app.library.url(for: a))
        let dur = try await asset.load(.duration).seconds
        check(abs(dur - seconds) < 3, String(format: "Duración %.1f s ≈ %.0f s", dur, seconds))
        let vt = try XCTUnwrap(try await asset.loadTracks(withMediaType: .video).first, "pista de vídeo")
        let fps = try await vt.load(.nominalFrameRate)
        let vDur = try await vt.load(.timeRange).duration.seconds
        // Count real samples: ScreenCaptureKit only delivers frames when content changes, and the fixture animates at 30 fps.
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: vt, outputSettings: nil)
        reader.add(out); reader.startReading()
        var frames = 0
        while out.copyNextSampleBuffer() != nil { frames += 1 }
        let expected = vDur * 30
        note(String(format: "Vídeo: %d fotogramas en %.1f s (%.1f fps de media, nominal %.1f)", frames, vDur, Double(frames) / max(vDur, 0.001), fps))
        check(Double(frames) >= expected * 0.95, String(format: "Sin pérdida apreciable de fotogramas (%.1f %% de los esperados a 30 fps)", Double(frames) / expected * 100))
        if let at = try await asset.loadTracks(withMediaType: .audio).first {
            let aDur = try await at.load(.timeRange).duration.seconds
            check(abs(aDur - vDur) < 0.5, String(format: "Audio y vídeo con la misma duración (%.2f vs %.2f s)", aDur, vDur))
        } else { check(false, "Pista de audio del sistema") }
        let firstHalf = rss.prefix(rss.count / 2), secondHalf = rss.suffix(rss.count / 2)
        let growth = (secondHalf.max() ?? 0) - (firstHalf.max() ?? 0)
        note(String(format: "RSS durante la grabación: %.0f → %.0f MB (máx %.0f)", rss.first ?? 0, rss.last ?? 0, rss.max() ?? 0))
        check(growth < 50, String(format: "Memoria estable durante la grabación (+%.0f MB entre mitades)", growth))
        for w in NSApp.windows where w is RecordingResultPanel { w.orderOut(nil) }
    }

    // MARK: Resources

    /// Physical footprint (what Activity Monitor shows); resident size would also count shared framework pages.
    private static func residentMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : .nan
    }

    private static func cpuSeconds() -> Double {
        var u = rusage(); getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
    }

    private func idle() async throws {
        closeTransientWindows()
        for w in NSApp.windows where w.isVisible && !(w.className.contains("StatusBar")) { w.orderOut(nil) }
        try await Task.sleep(for: .seconds(5)) // let background work (OCR indexing, thumbnails) settle
        let c0 = Self.cpuSeconds(), t0 = Date()
        try await Task.sleep(for: .seconds(20))
        let cpu = (Self.cpuSeconds() - c0) / Date().timeIntervalSince(t0) * 100
        let mb = Self.residentMB()
        check(cpu < 1, String(format: "CPU en reposo %.2f %% (objetivo < 1 %%)", cpu))
        check(freshMB <= 120, String(format: "Memoria en reposo al arrancar %.0f MB (objetivo ≤ 120 MB)", freshMB))
        // After every feature has run (camera, AVFoundation, Vision loaded) the footprint is higher; this bound catches leaks.
        check(mb <= 250, String(format: "Memoria tras toda la batería %.0f MB (cota anti-fugas ≤ 250 MB)", mb))
    }

    private func soak(cycles: Int) async throws {
        let f = try await launchFixture("static")
        defer { stop(f) }
        let r = CGRect(x: f.content.minX, y: f.content.minY, width: 400, height: 300)
        var samples: [Double] = []
        for i in 0..<cycles {
            await app.capture(.region(r, display: mainDisplay), purpose: .region)
            closeTransientWindows()
            app.qaCloseAllThumbnails()
            if i % 10 == 0 { samples.append(Self.residentMB()) }
            await Task.yield()
        }
        try await Task.sleep(for: .seconds(3))
        samples.append(Self.residentMB())
        // Slope over the second half (after warm-up), in MB per 100 captures.
        let half = Array(samples.suffix(samples.count / 2))
        let slope = half.count > 1 ? (half.last! - half.first!) / Double(half.count - 1) * 10 : 0
        note(String(format: "RSS: inicio %.0f MB, máx %.0f MB, final %.0f MB; pendiente 2.ª mitad %.2f MB/100 capturas", samples.first ?? 0, samples.max() ?? 0, samples.last ?? 0, slope))
        check(slope < 5, "Sin crecimiento sostenido de memoria")
    }

    // MARK: UI evidence

    private func uiSnapshots() async throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            NSApp.appearance = NSAppearance(named: appearance)
            let tag = appearance == .aqua ? "light" : "dark"
            OnboardingWindow.show(app: app)
            try await Task.sleep(for: .milliseconds(700))
            if let w = NSApp.windows.first(where: { $0.isVisible && $0.title == String(localized: "Bienvenido a NativeShot") }) { await snapshot(w, "ui-onboarding-\(tag)") }
            OnboardingWindow.close()
            HelpWindow.show(app: app)
            try await Task.sleep(for: .milliseconds(700))
            if let w = NSApp.windows.first(where: { $0.isVisible && $0.title == String(localized: "Ayuda y diagnóstico") }) { await snapshot(w, "ui-help-\(tag)") }
            for w in NSApp.windows where w.title == String(localized: "Ayuda y diagnóstico") { w.close() }
            LibraryWindowController.shared.show(app: app)
            try await Task.sleep(for: .milliseconds(1200))
            if let w = NSApp.windows.first(where: { $0.isVisible && $0.title == String(localized: "Biblioteca") }) { await snapshot(w, "ui-library-\(tag)"); w.close() }
            app.recorder.showPanel()
            try await Task.sleep(for: .milliseconds(700))
            if let w = NSApp.windows.first(where: { $0.isVisible && $0.title == String(localized: "Grabar pantalla") }) { await snapshot(w, "ui-recorder-\(tag)"); w.orderOut(nil) }
            let before = Set(NSApp.windows.filter(\.isVisible).map(\.windowNumber))
            app.openSettings()
            try await Task.sleep(for: .milliseconds(1000))
            if let w = NSApp.windows.first(where: { $0.isVisible && !before.contains($0.windowNumber) && $0.styleMask.contains(.titled) }) {
                await snapshot(w, "ui-settings-\(tag)")
                w.close()
            } else { check(false, "La ventana de Ajustes se abre (\(tag))") }
        }
        NSApp.appearance = nil
        let files = (try? FileManager.default.contentsOfDirectory(atPath: out.path).filter { $0.hasPrefix("ui-") }) ?? []
        check(files.count >= 8, "Capturas de interfaz generadas: \(files.count)")
    }

    /// Real pixels of one of our own windows via ScreenCaptureKit (materials included).
    private func snapshot(_ w: NSWindow, _ name: String, crop: CGRect? = nil) async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let sw = content.windows.first(where: { $0.windowID == CGWindowID(w.windowNumber) }) else { note("snapshot \(name): ventana no listada"); return }
            let img: CGImage
            if let crop {
                img = try await captureIncludingOwn(content, crop)
            } else {
                let filter = SCContentFilter(desktopIndependentWindow: sw)
                let cfg = SCStreamConfiguration()
                cfg.width = Int(filter.contentRect.width * CGFloat(filter.pointPixelScale))
                cfg.height = Int(filter.contentRect.height * CGFloat(filter.pointPixelScale))
                cfg.ignoreShadowsSingleWindow = true
                if let i = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg) { img = i }
                else { img = try await captureIncludingOwn(content, CGRect(x: w.frame.minX, y: NSScreen.primaryHeight - w.frame.maxY, width: w.frame.width, height: w.frame.height).insetBy(dx: -20, dy: -20)) }
            }
            savePNG(img, name + ".png")
        } catch { note("snapshot \(name): \(error.localizedDescription)") }
    }

    /// Screen pixels in `rect` (Quartz points) with NativeShot's own windows left in, unlike the product capture path.
    private func captureIncludingOwn(_ content: SCShareableContent, _ rect: CGRect) async throws -> CGImage {
        let display = try XCTUnwrap(content.displays.first { $0.displayID == mainDisplay }, "pantalla")
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let cfg = SCStreamConfiguration()
        cfg.sourceRect = rect
        cfg.width = Int(rect.width * CGFloat(filter.pointPixelScale)); cfg.height = Int(rect.height * CGFloat(filter.pointPixelScale))
        cfg.showsCursor = true
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
    }

    private func downscale(_ img: CGImage, maxWidth: Int) -> CGImage {
        guard img.width > maxWidth else { return img }
        let h = img.height * maxWidth / img.width
        let ctx = CGContext(data: nil, width: maxWidth, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: maxWidth, height: h))
        return ctx.makeImage()!
    }

    private func window(hosting name: String) -> NSWindow? {
        NSApp.windows.first { w in w.isVisible && (w.contentView.map { v in ([v] + v.subviews).contains { String(describing: type(of: $0)).contains(name) } } ?? false) }
    }

    private func closeTransientWindows() {
        for w in NSApp.windows where (w is ThumbnailPanel || w is PinPanel || w is EditorWindow) && w.isVisible { w.orderOut(nil) }
    }

    // MARK: Report

    private func writeReport() {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(steps).write(to: out.appendingPathComponent("report.json"))
        var md = "# NativeShot self-test\n\n\(Date().formatted()) · macOS \(ProcessInfo.processInfo.operatingSystemVersionString)\n\n"
        let pass = steps.filter { $0.status == "pass" }.count, fail = steps.filter { $0.status == "fail" }.count
        md += "**\(pass) pass · \(fail) fail · \(steps.count - pass - fail) skip**\n\n"
        for s in steps {
            md += "## \(s.status == "pass" ? "✅" : s.status == "fail" ? "❌" : "⏭️") \(s.id) — \(s.title) (\(Int(s.ms)) ms)\n"
            for d in s.details { md += "- \(d)\n" }
            md += "\n"
        }
        try? md.write(to: out.appendingPathComponent("report.md"), atomically: true, encoding: .utf8)
        log("Report: \(out.path)/report.md — \(pass) pass, \(fail) fail")
    }
}

/// One-shot flag shared by a reader thread and a timeout: whoever claims first resumes the continuation.
private final class OSAllocatedUnfairLockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if claimed { return false }; claimed = true; return true }
}

private func XCTUnwrap<T>(_ v: T?, _ what: String) throws -> T {
    guard let v else { throw QAFailure(what: what) }
    return v
}

private struct QAFailure: LocalizedError {
    let what: String
    var errorDescription: String? { "falta: \(what)" }
}
#endif
