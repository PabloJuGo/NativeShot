import AppKit
import ServiceManagement
import SwiftUI
import NativeShotKit

/// Coordinates shortcuts, capture flow, library and floating UI. Owns no pixels long-term.
@MainActor
final class AppController: ObservableObject, CaptureActions {
    static let shared = AppController()

    let library = Library()
    var recents: Library { library }
    private(set) var shortcuts: ShortcutRegistry!
    @Published private(set) var shortcutFailures: [ShortcutAction: ShortcutError] = [:]
    @Published var lastError: String?
    /// Set by the ⌘⇧5 wizard: the next selector trigger confirms the shortcut instead of capturing.
    @Published var testingSelectorShortcut = false
    @Published private(set) var selectorShortcutVerified = false
    /// HIS: while on, captures are not stored or indexed. Not persisted on purpose.
    @Published var privateSession = false { didSet { library.privateSession = privateSession } }
    /// QAO-002: what "Repetir" takes again.
    private var lastRepeatable: (selection: SelectionResult, purpose: CaptureMode)?

    private var state = CaptureStateMachine()
    private var overlay: SelectionOverlay?
    private lazy var quick = QuickOverlayController(actions: self)
    private let pins = PinController()
    private(set) lazy var recorder = RecorderController(library: library)
    let scroll = ScrollCaptureController()
    /// CAP-005: last region per display, invalidated if the display set changes.
    private var lastRegion: (rect: CGRect, display: CGDirectDisplayID)?

    private init() {}

    #if NATIVESHOT_QA
    var qaLastCapture: Capture?
    var qaOverlayActive: Bool { overlay != nil }
    var qaIdle: Bool { !state.isBusy }
    var qaThumbnails: Int { quick.qaCount }
    var qaPins: Int { pins.count }
    func qaCloseAllThumbnails() { quick.qaCloseAll() }
    var qaLastError: String? { lastError }
    #endif

    func start() {
        Prefs.register()
        let registrar = CarbonHotKeyRegistrar { [weak self] id in self?.shortcuts.trigger(id: id) }
        shortcuts = ShortcutRegistry(registrar: registrar)
        shortcuts.onTrigger = { [weak self] in self?.perform($0) }
        shortcutFailures = shortcuts.activate()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.lastRegion = nil }
        }
        Task { await library.purgeExpiredTrash(); await library.refresh() }
        Task { await recorder.offerRecovery() }
        applyDockPolicy()
        DistributedNotificationCenter.default().addObserver(forName: KeyboardLayoutLabels.changedNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.shortcuts.refreshLabels(); self?.objectWillChange.send() }
        }
        if !UserDefaults.standard.bool(forKey: Prefs.onboardingDone) || !ScreenCaptureAdapter.hasPermission { OnboardingWindow.show(app: self) }
    }

    // MARK: Shortcuts

    func perform(_ action: ShortcutAction) {
        switch action {
        case .selector:
            if testingSelectorShortcut {
                testingSelectorShortcut = false
                selectorShortcutVerified = true
                NSSound(named: "Glass")?.play()
                return
            }
            beginCapture(.region, purpose: .region)
        case .region: beginCapture(.region, purpose: .region)
        case .window: beginCapture(.window, purpose: .window)
        case .display: beginCapture(.display, purpose: .display)
        case .textRecognition: beginCapture(.region, purpose: .textRecognition)
        case .lastRegion: captureLastRegion()
        case .recordScreen: recorder.toggle()
        case .scrolling: beginCapture(.region, purpose: .scrolling)
        case .pinClipboard: pinClipboard()
        case .openLibrary: LibraryWindowController.shared.show(app: self)
        case .openSettings: openSettings()
        case .togglePrivateSession: privateSession.toggle(); announcePrivateSession()
        case .closePins: closeAllPins()
        }
    }

    func rebind(_ action: ShortcutAction, to combo: KeyCombo?) throws(ShortcutError) {
        if let combo { try shortcuts.bind(action, to: combo) } else { shortcuts.unbind(action) }
        shortcutFailures[action] = nil
        objectWillChange.send()
    }

    // MARK: Capture flow

    func beginCapture(_ mode: SelectionOverlay.Mode, purpose: CaptureMode) {
        guard state.handle(.begin) else { return } // ignore re-entry while a capture runs
        guard ScreenCaptureAdapter.hasPermission else {
            state.handle(.cancel); state.handle(.reset)
            OnboardingWindow.show(app: self)
            return
        }
        Signposts.begin("shortcut-to-overlay")
        let overlay = SelectionOverlay(mode: mode, purpose: purpose, screenshot: [.region, .window, .display].contains(purpose))
        self.overlay = overlay
        state.handle(.overlayShown)
        overlay.begin { [weak self, overlay] result in
            guard let self else { return }
            self.overlay = nil
            guard let result else {
                self.state.handle(.cancel); self.state.handle(.reset)
                return
            }
            self.state.handle(.selectionConfirmed)
            Signposts.begin("selection-to-thumbnail")
            if purpose == .scrolling { self.captureScrolling(result); return }
            let extras = overlay.extraRegions, frozen = overlay.frozenSnapshots
            Task { await self.capture(result, purpose: purpose, extras: extras, frozen: frozen) }
        }
    }

    func captureLastRegion() {
        guard let last = lastRegion, state.handle(.begin) else { return }
        state.handle(.selectionConfirmed)
        Task { await capture(.region(last.rect, display: last.display), purpose: .region) }
    }

    /// `extras` are regions picked earlier with ⌘ (CAP-011); `frozen` are the snapshots the user selected on (CAP-010).
    func capture(_ selection: SelectionResult, purpose: CaptureMode, extras: [SelectedRegion] = [], frozen: [CGDirectDisplayID: CGImage] = [:]) async {
        let d = UserDefaults.standard
        if purpose != .scrolling { lastRepeatable = (selection, purpose) }
        do {
            try await Countdown.run(seconds: d.integer(forKey: Prefs.timerSeconds))
            // Let the overlay leave the window server before grabbing pixels.
            try await Task.sleep(for: .milliseconds(40))
            var images: [CGImage] = []
            var sourceApp: String?
            let cursor = d.bool(forKey: Prefs.showsCursor)
            func grab(_ display: CGDirectDisplayID, _ rect: CGRect?) async throws -> CGImage {
                if let snap = frozen[display] { return try ScreenCaptureAdapter.crop(snap, display: display, rect: rect) }
                return try await ScreenCaptureAdapter.capture(display: display, rect: rect, showsCursor: cursor)
            }
            switch selection {
            case .region(let r, let display):
                lastRegion = (r, display)
                for region in extras { images.append(try await grab(region.display, region.rect)) }
                images.append(try await grab(display, r))
            case .window(let id, _):
                sourceApp = WindowCandidate.onScreen().first { $0.id == id }?.owner
                images = [try await ScreenCaptureAdapter.capture(windowID: id, shadow: d.bool(forKey: Prefs.windowShadow))]
            case .display(let id):
                images = [try await grab(id, nil)]
            }
            state.handle(.pixelsReceived)
            if purpose == .textRecognition, let image = images.first {
                await recognizeText(in: image)
            } else if images.count > 1, !d.bool(forKey: Prefs.multiRegionJoin) {
                for image in images { await deliver(image, sourceApp: sourceApp) } // CAP-011: one capture per region
            } else if let image = RegionComposition.compose(images) {
                await deliver(image, sourceApp: sourceApp)
            }
            state.handle(.artifactStored)
        } catch is CancellationError {
            state.handle(.fail("cancelled"))
        } catch {
            state.handle(.fail(error.localizedDescription))
            report(error)
        }
        state.handle(.reset)
    }

    /// NS-010: the state machine stays in `capturing` while the user scrolls, so a second capture cannot start.
    private func captureScrolling(_ selection: SelectionResult) {
        guard let target = ScrollCaptureController.target(of: selection) else {
            state.handle(.fail("no display")); state.handle(.reset)
            return
        }
        Task {
            do {
                let outcome = try await scroll.run(display: target.display, rect: target.rect)
                state.handle(.pixelsReceived)
                await deliverScroll(outcome)
                state.handle(.artifactStored)
            } catch is CancellationError {
                state.handle(.fail("cancelled"))
            } catch {
                state.handle(.fail(error.localizedDescription))
                report(error)
            }
            state.handle(.reset)
        }
    }

    private func deliverScroll(_ captured: ScrollCaptureController.Outcome) async {
        guard let o = ScrollCaptureController.review(captured) else { return } // SCR-007: cancelled at the crop step
        if UserDefaults.standard.bool(forKey: Prefs.scrollPDF) {
            do {
                let url = try ScrollCaptureController.writePDF(o, in: Prefs.saveFolderURL)
                Toast.show(String(localized: "PDF guardado: \(url.lastPathComponent)"), symbol: "doc.richtext")
            } catch { report(error) }
        }
        if o.saveSeparately {
            do {
                let dir = try ScrollCaptureController.saveSeparately(o, in: Prefs.saveFolderURL)
                NSWorkspace.shared.activateFileViewerSelecting([dir])
            } catch { report(error) }
            return
        }
        guard let last = o.parts.last else { return }
        // Tiles beyond the first only exist when the height limit split the capture; they go to history, the last one to the overlay.
        for part in o.parts.dropLast() {
            do { _ = try await library.add(part, sourceApp: nil) } catch { report(error) }
        }
        if o.parts.count > 1 { Toast.show(String(localized: "Captura larga dividida en \(o.parts.count) partes"), symbol: "rectangle.split.1x2") }
        await deliver(last, sourceApp: nil)
    }

    private func deliver(_ image: CGImage, sourceApp: String?) async {
        if UserDefaults.standard.bool(forKey: Prefs.playSound) { NSSound(named: "Tink")?.play() }
        do {
            let (id, url) = try await library.add(image, sourceApp: sourceApp)
            let c = Capture(id: id, image: image, fileURL: url)
            #if NATIVESHOT_QA
            qaLastCapture = c
            #endif
            switch AfterCapture(rawValue: UserDefaults.standard.string(forKey: Prefs.afterCapture) ?? "") ?? .overlay {
            case .overlay: quick.show(c); Signposts.end("selection-to-thumbnail")
            case .copy: copy(c)
            case .save: save(c)
            case .copyAndSave: copy(c); save(c)
            }
        } catch {
            // Storage failed: still let the user copy the pixels rather than lose the capture.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([NSImage(cgImage: image, size: .zero)])
            report(error)
        }
    }

    /// The quick path copies to the clipboard; the result window opens when the preference says so or when asked explicitly.
    private func recognizeText(in image: CGImage, forceWindow: Bool = false) async {
        do {
            let r = try await TextRecognizer.recognize(image)
            if forceWindow || UserDefaults.standard.bool(forKey: Prefs.ocrOpensWindow) {
                OCRWindow.show(image: image, result: r)
                return
            }
            var parts = [r.text].filter { !$0.isEmpty }
            parts += r.barcodes // payloads are copied as text, never opened automatically
            let joined = parts.joined(separator: "\n")
            guard !joined.isEmpty else {
                Toast.show(String(localized: "No se ha encontrado texto"), symbol: "text.viewfinder")
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(joined, forType: .string)
            let msg = r.barcodes.isEmpty
                ? String(localized: "Texto copiado (\(joined.count) caracteres)")
                : String(localized: "Código copiado: \(r.barcodes[0])")
            Toast.show(msg, symbol: "doc.on.clipboard")
        } catch {
            report(error)
        }
    }

    private func report(_ error: Error) {
        lastError = error.localizedDescription
        Toast.show(error.localizedDescription, symbol: "exclamationmark.triangle")
    }

    // MARK: CaptureActions

    func copy(_ c: Capture) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([c.nsImage])
    }

    func save(_ c: Capture) {
        let folder = Prefs.saveFolderURL
        do {
            _ = try ExportSettings.write(c.image, type: "screenshot", to: folder)
            Toast.show(String(localized: "Guardada en \(folder.lastPathComponent)"), symbol: "checkmark.circle")
        } catch {
            report(error)
        }
    }

    /// EXP: system share sheet (AirDrop included when available) over the stored original.
    func share(_ c: Capture, from anchor: NSView) {
        NSSharingServicePicker(items: [c.fileURL]).show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }

    func copyPath(_ c: Capture) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(c.fileURL.path, forType: .string)
        Toast.show(String(localized: "Ruta copiada"), symbol: "doc.on.clipboard")
    }

    func pin(_ c: Capture) { pins.pin(c.image) }

    func export(_ c: Capture) { ExportManager.show(image: c.image) }
    func printCapture(_ c: Capture) { PrintAction.print(c.image) }
    func recognizeText(_ c: Capture) { Task { await recognizeText(in: c.image, forceWindow: true) } }

    func repeatCapture() {
        guard let last = lastRepeatable, state.handle(.begin) else { return }
        state.handle(.selectionConfirmed)
        Task { await capture(last.selection, purpose: last.purpose) }
    }

    var canRepeat: Bool { lastRepeatable != nil }

    private func isInLibrary(_ c: Capture) -> Bool { c.fileURL.path.hasPrefix(library.root.path) }
    func canExcludeFromHistory(_ c: Capture) -> Bool { isInLibrary(c) }

    /// HIS: removes the stored copy (row, index, thumbnail) and keeps the capture usable from a temporary file.
    func excludeFromHistory(_ c: Capture) {
        guard isInLibrary(c) else { return }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("NativeShot/\(c.id.uuidString).png")
        Task {
            do {
                try FileManager.default.createDirectory(at: tmp.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: tmp)
                try FileManager.default.copyItem(at: c.fileURL, to: tmp)
                await library.purge([c.id])
                quick.show(Capture(id: c.id, image: c.image, fileURL: tmp))
                Toast.show(String(localized: "Excluida del historial"), symbol: "eye.slash")
            } catch { report(error) }
        }
    }

    func announcePrivateSession() {
        Toast.show(privateSession ? String(localized: "Sesión privada: las capturas no se guardan en el historial")
                                  : String(localized: "Sesión privada desactivada"),
                   symbol: privateSession ? "eye.slash" : "eye")
    }

    /// PIN-001: click-through. The unlock lives in the menu bar because a locked pin cannot be clicked.
    func setPinsLocked(_ on: Bool) { pins.setLocked(on) }

    func edit(_ c: Capture) { Signposts.begin("editor-open"); ImageEditorController.edit(c.image); Signposts.end("editor-open") }

    func reveal(_ c: Capture) { NSWorkspace.shared.activateFileViewerSelecting([c.fileURL]) }

    /// Recoverable: goes to the library trash. Without history there is no row, so the temp file is just removed.
    func delete(_ c: Capture) {
        Task {
            if isInLibrary(c) {
                await library.trash([c.id])
                Toast.show(String(localized: "Movida a la papelera de la biblioteca"), symbol: "trash")
            } else {
                try? FileManager.default.removeItem(at: c.fileURL)
            }
        }
    }

    // MARK: Menu helpers

    func capture(from artifact: StoredArtifact) -> Capture? {
        let url = library.url(for: artifact)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        return Capture(id: artifact.id, image: img, fileURL: url)
    }

    /// CAP-017 / PIN-003: pin whatever image is on the clipboard.
    func pinClipboard() {
        guard let img = NSImage(pasteboard: .general), let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            Toast.show(String(localized: "No hay ninguna imagen en el portapapeles"), symbol: "doc.on.clipboard")
            return
        }
        pins.pin(cg)
    }

    func restoreLastThumbnail() { quick.restoreLast() }
    func focusThumbnail() { quick.focusLatest() }
    func closeAllPins() { pins.closeAll() }

    func openLibraryFolder() { NSWorkspace.shared.open(library.root.appendingPathComponent("originals")) }

    /// `showSettingsWindow:` is a no-op since macOS 14; the SwiftUI `openSettings` action is the only supported
    /// route, and it needs a view in a window. A transparent one-shot window hosts it and closes itself.
    func openSettings() {
        NSApp.activate()
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1), styleMask: [.borderless], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.ignoresMouseEvents = true
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: SettingsOpener { [weak w] in w?.close() })
        w.orderFrontRegardless()
    }

    /// UTL: the app is an accessory (menu bar only) unless the user asks for a Dock icon.
    func applyDockPolicy() {
        NSApp.setActivationPolicy(UserDefaults.standard.bool(forKey: Prefs.showDockIcon) ? .regular : .accessory)
    }

    // MARK: Launch at login (UTL)

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do { newValue ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
            catch { report(error) }
            objectWillChange.send()
        }
    }
}

private struct SettingsOpener: View {
    let done: () -> Void
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        Color.clear.onAppear { openSettings(); Task { @MainActor in done() } }
    }
}
