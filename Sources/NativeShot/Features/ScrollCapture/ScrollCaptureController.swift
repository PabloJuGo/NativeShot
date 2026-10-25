import AppKit
import SwiftUI
import NativeShotKit

/// Manual-assisted scrolling capture (SCR-003): the user scrolls, we grab the chosen region periodically,
/// join only the frames we can align confidently and show progress in a floating panel.
@MainActor
final class ScrollCaptureController {
    struct Outcome {
        /// Stitched tiles in order (one image unless the memory/height limits split it, SCR-006).
        var parts: [CGImage]
        /// Frames that could not be joined, for the separate-frames alternative (SCR-008).
        var rejected: [CGImage]
        var saveSeparately = false
        var axis = ScrollAxis.vertical
        /// Pixels per point, to size PDF pages like the original on screen.
        var scale: CGFloat = 2
    }

    private enum End { case finish, cancel, failed(String), limit }

    private let model = ScrollPanelModel()
    private var panel: ScrollPanel?
    private var continuation: CheckedContinuation<End, Never>?
    private var rejected: [CGImage] = []
    /// Bounded so a long failing session cannot hold unbounded bitmaps.
    private static let maxKeptRejected = 6

    var isRunning: Bool { continuation != nil }

    #if NATIVESHOT_QA
    func qaFinish() { end(.finish) }
    func qaCancel() { end(.cancel) }
    var qaHeight: Int { Int(model.height) }
    #endif

    /// Quartz-global region and its display for any selection kind; nil if it cannot be scrolled.
    static func target(of selection: SelectionResult) -> (display: CGDirectDisplayID, rect: CGRect)? {
        switch selection {
        case .region(let r, let d): return (d, r)
        case .display(let d): return (d, CGDisplayBounds(d))
        case .window(_, let frame):
            var count: UInt32 = 0
            var ids = [CGDirectDisplayID](repeating: 0, count: 8)
            CGGetDisplaysWithPoint(CGPoint(x: frame.midX, y: frame.midY), 8, &ids, &count)
            guard count > 0 else { return nil }
            return (ids[0], frame)
        }
    }

    /// Returns when the user finishes (or memory runs out); throws CancellationError on cancel.
    func run(display: CGDirectDisplayID, rect: CGRect) async throws -> Outcome {
        let engine = ScrollCaptureEngine()
        try await engine.prepare(display: display, rect: rect)
        model.reset()
        model.axis = ScrollAxis(rawValue: UserDefaults.standard.string(forKey: Prefs.scrollAxis) ?? "") ?? .vertical
        rejected = []
        let panel = ScrollPanel(model: model, finish: { [weak self] in self?.end(.finish) }, cancel: { [weak self] in self?.end(.cancel) },
                                axisChanged: { [weak self] axis in
                                    UserDefaults.standard.set(axis.rawValue, forKey: Prefs.scrollAxis)
                                    self?.rejected = []
                                    self?.model.restart()
                                    Task { await engine.setAxis(axis) }
                                })
        panel.place(avoiding: DisplayGeometry.flip(rect, primaryHeight: NSScreen.primaryHeight))
        self.panel = panel

        let loop = Task.detached(priority: .userInitiated) { [weak self] in
            while !Task.isCancelled {
                do {
                    let u = try await engine.step()
                    await self?.apply(u)
                } catch {
                    await self?.end(.failed(error.localizedDescription))
                    return
                }
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
        let reason = await withCheckedContinuation { continuation = $0 }
        loop.cancel()
        await loop.value // no capture in flight once the panel is gone
        panel.orderOut(nil)
        self.panel = nil

        switch reason {
        case .cancel: throw CancellationError()
        case .failed(let message): throw ScrollCaptureEngine.EngineError(errorDescription: message)
        case .limit, .finish:
            var outcome = Outcome(parts: await engine.finish(), rejected: rejected, axis: model.axis, scale: await engine.scale)
            if case .limit = reason { Toast.show(String(localized: "Límite de memoria alcanzado: se conserva lo capturado hasta aquí"), symbol: "memorychip") }
            #if NATIVESHOT_QA
            outcome.saveSeparately = false // never block the self-test on a modal alert
            #else
            if !rejected.isEmpty { outcome.saveSeparately = Self.askSeparateFrames(count: rejected.count) }
            #endif
            return outcome
        }
    }

    private func end(_ reason: End) {
        continuation?.resume(returning: reason)
        continuation = nil
    }

    private func apply(_ u: ScrollCaptureEngine.Update) {
        guard isRunning else { return }
        switch u.result {
        case .first, .appended:
            model.warning = nil
            model.height = u.height
            if let p = u.preview { model.preview = p }
            if case .appended = u.result { model.joined += 1 }
        case .rejected(let r):
            if let img = u.rejectedImage, rejected.count < Self.maxKeptRejected { rejected.append(img) }
            model.warning = Self.message(for: r)
        case .limitReached: end(.limit)
        case .still, .scrolledBack: break
        }
    }

    private static func message(for r: ScrollRejection) -> String {
        switch r {
        case .noOverlap: String(localized: "No se puede unir: desplázate más despacio o sube un poco.")
        case .ambiguous: String(localized: "Contenido repetitivo: la unión no es fiable. Sube un poco y continúa.")
        case .fixedBandsTooLarge: String(localized: "Casi todo el contenido es fijo: no hay nada que unir.")
        case .sizeMismatch: String(localized: "La región ha cambiado de tamaño. Termina o cancela.")
        }
    }

    /// SCR-008: be honest that some content cannot be joined and offer successive captures instead.
    private static func askSeparateFrames(count: Int) -> Bool {
        let alert = NSAlert()
        alert.messageText = String(localized: "Algunas partes no se pudieron unir con seguridad")
        alert.informativeText = String(localized: "Se omitieron \(count) fotogramas (contenido repetitivo, animado o demasiado rápido). La imagen unida solo contiene uniones fiables. También puedes guardar los fotogramas por separado para montarlos a mano.")
        alert.addButton(withTitle: String(localized: "Guardar imagen unida"))
        alert.addButton(withTitle: String(localized: "Guardar por separado"))
        NSApp.activate()
        return alert.runModal() == .alertSecondButtonReturn
    }

    /// SCR-007: last chance to trim the stitched result before it is saved. Nil = the user cancelled.
    /// shortcut: only single-tile results (under the 8192 px segment limit) are offered the crop; segmented ones are saved as they are.
    static func review(_ outcome: Outcome) -> Outcome? {
        #if NATIVESHOT_QA
        return outcome // never block the self-test on a modal alert
        #else
        guard UserDefaults.standard.bool(forKey: Prefs.scrollCrop), outcome.parts.count == 1, let image = outcome.parts.first else { return outcome }
        let model = CropModel(width: image.width, height: image.height)
        let alert = NSAlert()
        alert.messageText = String(localized: "Recortar la captura larga")
        alert.informativeText = String(localized: "Quita lo que sobre por cada lado antes de guardar. Puedes dejarlo como está.")
        alert.accessoryView = NSHostingView.fixed(ScrollCropView(image: image, model: model))
        alert.addButton(withTitle: String(localized: "Guardar"))
        alert.addButton(withTitle: String(localized: "Cancelar"))
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        guard let rect = model.pixelRect, let cropped = image.cropping(to: rect) else { return outcome }
        var out = outcome
        out.parts = [cropped]
        return out
        #endif
    }

    /// SCR-006: the stitched result as a multipage PDF next to the other captures.
    static func writePDF(_ outcome: Outcome, in folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = FileNamingPolicy.uniqueURL(in: folder, name: FileNamingPolicy.default.name(date: Date(), type: "scroll", ext: "pdf"))
        try ScrollPDF.write(parts: outcome.parts, axis: outcome.axis, scale: outcome.scale, to: url)
        return url
    }

    /// Writes every tile and unjoined frame as numbered PNGs into a fresh folder under `folder`.
    static func saveSeparately(_ outcome: Outcome, in folder: URL) throws -> URL {
        let name = FileNamingPolicy.default.name(date: Date(), type: "scroll", ext: "png")
        let dir = FileNamingPolicy.uniqueURL(in: folder, name: name).deletingPathExtension()
        let images = outcome.parts + outcome.rejected
        for (i, img) in images.enumerated() {
            let prefix = i < outcome.parts.count ? "parte" : "fotograma"
            _ = try Library.writePNG(img, to: dir.appendingPathComponent("\(prefix)-\(i + 1).png"))
        }
        return dir
    }
}

// MARK: Panel

@MainActor
final class ScrollPanelModel: ObservableObject {
    @Published var height = 0
    @Published var joined = 0
    @Published var preview: CGImage?
    @Published var warning: String?
    @Published var axis = ScrollAxis.vertical
    func reset() { height = 0; joined = 0; preview = nil; warning = nil }
    /// Direction changed: progress so far is discarded, the direction stays.
    func restart() { let a = axis; reset(); axis = a }
}

final class ScrollPanel: NSPanel {
    @MainActor
    init(model: ScrollPanelModel, finish: @escaping () -> Void, cancel: @escaping () -> Void, axisChanged: @escaping (ScrollAxis) -> Void) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isReleasedWhenClosed = false
        let host = NSHostingView.fixed(ScrollPanelView(model: model, finish: finish, cancel: cancel, axisChanged: axisChanged))
        contentView = host
        setContentSize(host.fittingSize)
    }

    override var canBecomeKey: Bool { false }

    /// Beside the region (right, left, below, above) so it never blocks the area being scrolled.
    @MainActor
    func place(avoiding region: CGRect) { // AppKit coordinates
        let screen = NSScreen.screens.first { $0.frame.intersects(region) } ?? NSScreen.main!
        let v = screen.visibleFrame, s = frame.size, gap: CGFloat = 12
        let candidates = [
            CGPoint(x: region.maxX + gap, y: region.maxY - s.height),
            CGPoint(x: region.minX - gap - s.width, y: region.maxY - s.height),
            CGPoint(x: region.midX - s.width / 2, y: region.minY - gap - s.height),
            CGPoint(x: region.midX - s.width / 2, y: region.maxY + gap),
        ]
        let spot = candidates.first { v.contains(CGRect(origin: $0, size: s)) } ?? CGPoint(x: v.maxX - s.width - gap, y: v.minY + gap)
        setFrameOrigin(spot)
        orderFrontRegardless()
    }
}

private struct ScrollPanelView: View {
    @ObservedObject var model: ScrollPanelModel
    let finish: () -> Void
    let cancel: () -> Void
    let axisChanged: (ScrollAxis) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Desplázate por el contenido…").font(.headline)
            // SCR-002: the direction is fixed per capture; changing it restarts the stitching.
            Picker("Dirección", selection: $model.axis) {
                Text("Vertical").tag(ScrollAxis.vertical)
                Text("Horizontal").tag(ScrollAxis.horizontal)
            }
            .pickerStyle(.segmented).labelsHidden()
            .accessibilityLabel(Text("Dirección del scroll"))
            .onChange(of: model.axis) { axisChanged(model.axis) }
            (model.axis == .vertical ? Text("Altura: \(model.height) px · Uniones: \(model.joined)")
                                     : Text("Ancho: \(model.height) px · Uniones: \(model.joined)"))
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            // Fixed-size slots: the panel is sized once, so content must not change its height.
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 6).fill(.black.opacity(0.06))
                if let p = model.preview { Image(decorative: p, scale: 1).resizable().scaledToFit() }
            }
            .frame(width: 220, height: 160)
            .accessibilityHidden(true)
            Group {
                if let w = model.warning {
                    Label(w, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .frame(width: 220, height: 44, alignment: .topLeading)
            HStack {
                Button("Cancelar", action: cancel)
                Spacer()
                Button("Terminar", action: finish).keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
        .frame(width: 244)
        .panelBackground(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(1)
    }
}

// MARK: Final crop (SCR-007)

@MainActor
final class CropModel: ObservableObject {
    static let minSide = 16.0
    let width: Int, height: Int
    @Published var left = 0.0
    @Published var top = 0.0
    @Published var right = 0.0
    @Published var bottom = 0.0
    init(width: Int, height: Int) { self.width = width; self.height = height }

    /// Kept area in image pixels; always at least `minSide` wide and tall.
    var rect: CGRect {
        let w = Double(width), h = Double(height)
        let l = min(left, max(0, w - Self.minSide - right)), t = min(top, max(0, h - Self.minSide - bottom))
        return CGRect(x: l, y: t, width: w - l - min(right, w - Self.minSide - l), height: h - t - min(bottom, h - Self.minSide - t)).integral
    }

    var pixelRect: CGRect? { left + top + right + bottom == 0 ? nil : rect }
}

private struct ScrollCropView: View {
    let image: CGImage
    @ObservedObject var model: CropModel

    var body: some View {
        let w = Double(model.width), h = Double(model.height)
        VStack(spacing: 10) {
            Image(decorative: image, scale: 1).resizable().scaledToFit()
                .overlay {
                    GeometryReader { g in
                        let r = model.rect
                        let box = CGRect(x: r.minX / w * g.size.width, y: r.minY / h * g.size.height,
                                         width: r.width / w * g.size.width, height: r.height / h * g.size.height)
                        Path { $0.addRect(CGRect(origin: .zero, size: g.size)); $0.addRect(box) }
                            .fill(.black.opacity(0.5), style: FillStyle(eoFill: true))
                        Path { $0.addRect(box) }.stroke(Color.accentColor, lineWidth: 2)
                    }
                }
                .frame(width: 480, height: 260)
                .accessibilityHidden(true)
            edge("Arriba", $model.top, limit: h - CropModel.minSide - model.bottom)
            edge("Abajo", $model.bottom, limit: h - CropModel.minSide - model.top)
            edge("Izquierda", $model.left, limit: w - CropModel.minSide - model.right)
            edge("Derecha", $model.right, limit: w - CropModel.minSide - model.left)
            Text("Resultado: \(Int(model.rect.width)) × \(Int(model.rect.height)) px")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        .frame(width: 480)
        .padding(.vertical, 4)
    }

    private func edge(_ title: LocalizedStringKey, _ value: Binding<Double>, limit: Double) -> some View {
        HStack {
            Text(title).frame(width: 70, alignment: .leading)
            Slider(value: value, in: 0...max(1, limit)).accessibilityLabel(Text(title))
            Text("\(Int(value.wrappedValue)) px").monospacedDigit().frame(width: 70, alignment: .trailing)
        }
    }
}
