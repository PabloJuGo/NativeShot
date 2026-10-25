import CoreGraphics
import Foundation
import ScreenCaptureKit
import NativeShotKit

/// Grabs one fixed region over and over and feeds the stitcher. An actor so pixel conversion and
/// alignment never run on the MainActor.
actor ScrollCaptureEngine {
    struct Update: Sendable {
        let result: ScrollAddResult
        let height: Int
        let preview: CGImage?
        /// The frame that could not be joined, kept so the user can still save it separately (SCR-008).
        let rejectedImage: CGImage?
    }

    struct EngineError: LocalizedError { let errorDescription: String? }

    private var stitcher = ScrollStitcher()
    /// Pixels per point of the captured display (the PDF export needs it to size pages).
    private(set) var scale: CGFloat = 2
    private var filter: SCContentFilter?
    private var config: SCStreamConfiguration?
    private var colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private var lastRaw: ScrollFrame?

    /// `rect` is in Quartz global points. Resolved once: re-querying shareable content every tick would dominate the cost.
    func prepare(display displayID: CGDirectDisplayID, rect: CGRect) async throws {
        let c = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = c.displays.first(where: { $0.displayID == displayID }) else {
            throw EngineError(errorDescription: String(localized: "La pantalla ya no está disponible."))
        }
        let own = c.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let f = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
        let scale = CGFloat(f.pointPixelScale)
        self.scale = scale
        guard let local = DisplayGeometry.local(rect, in: CGDisplayBounds(displayID)) else {
            throw EngineError(errorDescription: String(localized: "La región está fuera de la pantalla."))
        }
        let aligned = DisplayGeometry.pixelAligned(local, scale: scale)
        let px = DisplayGeometry.pixelSize(of: aligned, scale: scale)
        let cfg = SCStreamConfiguration()
        cfg.sourceRect = aligned
        cfg.width = px.width
        cfg.height = px.height
        cfg.showsCursor = false // a moving pointer would perturb every frame
        cfg.captureResolution = .best
        cfg.captureDynamicRange = .SDR // CAP-015
        stitcher = ScrollStitcher(axis: ScrollAxis(rawValue: UserDefaults.standard.string(forKey: Prefs.scrollAxis) ?? "") ?? .vertical)
        filter = f
        config = cfg
    }

    /// SCR-002: switching direction restarts the stitching, since earlier joins were made along the other axis.
    func setAxis(_ axis: ScrollAxis) {
        stitcher = ScrollStitcher(axis: axis)
        lastRaw = nil
    }

    func step() async throws -> Update {
        guard let filter, let config else { throw EngineError(errorDescription: nil) }
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        guard let frame = frame(from: image) else {
            throw EngineError(errorDescription: String(localized: "No se pudo leer la imagen capturada."))
        }
        if frame == lastRaw { return Update(result: .still, height: stitcher.height, preview: nil, rejectedImage: nil) }
        lastRaw = frame
        let result = stitcher.add(frame)
        var preview: CGImage?
        var rejected: CGImage?
        switch result {
        case .first, .appended: preview = stitcher.tail(maxRows: 600).flatMap(cgImage)
        case .rejected: rejected = image
        default: break
        }
        return Update(result: result, height: max(stitcher.height, frame.height), preview: preview, rejectedImage: rejected)
    }

    func finish() -> [CGImage] { stitcher.finish().compactMap(cgImage) }

    private func frame(from image: CGImage) -> ScrollFrame? {
        let w = image.width, h = image.height
        if let cs = image.colorSpace, cs.model == .rgb { colorSpace = cs }
        var ok = true
        let data = [UInt8](unsafeUninitializedCapacity: w * h * 4) { buf, n in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { ok = false; n = 0; return }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            n = w * h * 4
        }
        return ok ? ScrollFrame(width: w, height: h, bytesPerPixel: 4, data: data) : nil
    }

    private func cgImage(_ f: ScrollFrame) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(f.data) as CFData) else { return nil }
        return CGImage(width: f.width, height: f.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: f.rowBytes,
                       space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
