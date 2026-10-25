import AppKit
import ScreenCaptureKit
import NativeShotKit

/// Static captures through ScreenCaptureKit (ADR-0002). NativeShot's own windows (overlays,
/// thumbnails, pins) are always excluded from the output (CAP-013, QAO-005).
@MainActor
enum ScreenCaptureAdapter {
    struct CaptureError: LocalizedError {
        let errorDescription: String?
    }

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Triggers the system prompt (first time) and returns the current state.
    @discardableResult
    static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    static func openPrivacySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    private static func content() async throws -> SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }

    private static func ownApps(_ c: SCShareableContent) -> [SCRunningApplication] {
        c.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
    }

    /// SCK's own failures, said plainly (CAP-018): missing permission vs. content that cannot be captured right now.
    private static func grab(_ filter: SCContentFilter, _ config: SCStreamConfiguration) async throws -> CGImage {
        // CAP-015: always hand back SDR pixels (tone-mapped by the system) so an HDR display never yields a washed-out or clipped image.
        config.captureDynamicRange = .SDR
        do {
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch let e as NSError where e.domain == SCStreamErrorDomain {
            switch e.code {
            case SCStreamError.Code.userDeclined.rawValue:
                throw CaptureError(errorDescription: String(localized: "Falta el permiso de Grabación de pantalla. Actívalo en Ajustes del Sistema › Privacidad y seguridad."))
            case SCStreamError.Code.noWindowList.rawValue, SCStreamError.Code.noDisplayList.rawValue,
                 SCStreamError.Code.noCaptureSource.rawValue, SCStreamError.Code.failedNoMatchingApplicationContext.rawValue:
                throw CaptureError(errorDescription: String(localized: "No se puede capturar este contenido: puede estar en otro Space, minimizado o protegido."))
            default: throw e
            }
        }
    }

    /// CAP-012: the display minus NativeShot's windows and, if asked, Finder's desktop-icon windows. Nothing in Finder changes.
    private static func filter(for display: SCDisplay, in c: SCShareableContent) -> SCContentFilter {
        guard UserDefaults.standard.bool(forKey: Prefs.hideDesktopIcons) else {
            return SCContentFilter(display: display, excludingApplications: ownApps(c), exceptingWindows: [])
        }
        let me = ProcessInfo.processInfo.processIdentifier
        let icons = Int(CGWindowLevelForKey(.desktopIconWindow))
        let hidden = c.windows.filter {
            $0.owningApplication?.processID == me
                || ($0.owningApplication?.bundleIdentifier == "com.apple.finder" && $0.windowLayer == icons)
        }
        return SCContentFilter(display: display, excludingWindows: hidden)
    }

    /// CAP-019: height of the camera-housing band at the top of a built-in display (0 elsewhere).
    static func notchInset(of displayID: CGDirectDisplayID) -> CGFloat {
        NSScreen.screens.first { $0.displayID == displayID }?.safeAreaInsets.top ?? 0
    }

    /// Display-local rect (points) to capture; nil rect = whole display, minus the notch band if the preference asks.
    private static func localRect(display displayID: CGDirectDisplayID, rect: CGRect?, scale: CGFloat, skippingNotch: Bool) throws -> CGRect {
        let bounds = CGDisplayBounds(displayID)
        guard let rect else {
            let whole = CGRect(origin: .zero, size: bounds.size)
            return skippingNotch && UserDefaults.standard.bool(forKey: Prefs.excludeNotch)
                ? DisplayGeometry.excludingTop(whole, inset: notchInset(of: displayID)) : whole
        }
        guard let l = DisplayGeometry.local(rect, in: bounds) else {
            throw CaptureError(errorDescription: String(localized: "La región está fuera de la pantalla."))
        }
        return DisplayGeometry.pixelAligned(l, scale: scale)
    }

    /// Captures `rect` (Quartz global coordinates, points) from the display that contains it.
    /// A nil rect captures the whole display. `skippingNotch: false` is for freeze-frame snapshots, which must keep display geometry.
    static func capture(display displayID: CGDirectDisplayID, rect: CGRect?, showsCursor: Bool, skippingNotch: Bool = true) async throws -> CGImage {
        let c = try await content()
        guard let display = c.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError(errorDescription: String(localized: "La pantalla ya no está disponible."))
        }
        let filter = filter(for: display, in: c)
        let scale = CGFloat(filter.pointPixelScale)
        let local = try localRect(display: displayID, rect: rect, scale: scale, skippingNotch: skippingNotch)
        let config = SCStreamConfiguration()
        config.sourceRect = local
        let px = DisplayGeometry.pixelSize(of: local, scale: scale)
        config.width = px.width
        config.height = px.height
        config.showsCursor = showsCursor
        config.captureResolution = .best
        return try await grab(filter, config)
    }

    /// Cuts `rect` (nil = whole display) out of a full-display snapshot taken with `skippingNotch: false`.
    static func crop(_ snapshot: CGImage, display displayID: CGDirectDisplayID, rect: CGRect?) throws -> CGImage {
        let scale = CGFloat(snapshot.width) / CGDisplayBounds(displayID).width
        let l = try localRect(display: displayID, rect: rect, scale: scale, skippingNotch: true)
        let px = CGRect(x: l.minX * scale, y: l.minY * scale, width: l.width * scale, height: l.height * scale).integral
        guard let out = snapshot.cropping(to: px) else {
            throw CaptureError(errorDescription: String(localized: "La región está fuera de la pantalla."))
        }
        return out
    }

    /// Captures one window independently of what covers it, with transparent background (CAP-002).
    static func capture(windowID: CGWindowID, shadow: Bool) async throws -> CGImage {
        var c = try await content()
        if !c.windows.contains(where: { $0.windowID == windowID }) {
            // CAP-018: a window that is mid-transition (entering full screen, switching Space) often reappears a moment later.
            try await Task.sleep(for: .milliseconds(250))
            c = try await content()
        }
        guard let window = c.windows.first(where: { $0.windowID == windowID }) else {
            throw CaptureError(errorDescription: unavailableReason(of: windowID))
        }
        if sharingState(of: windowID) == 0 {
            throw CaptureError(errorDescription: String(localized: "Esta ventana tiene contenido protegido y macOS no permite capturarla."))
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(filter.pointPixelScale)
        let config = SCStreamConfiguration()
        let size = filter.contentRect.size
        config.width = Int((size.width * scale).rounded())
        config.height = Int((size.height * scale).rounded())
        config.ignoreShadowsSingleWindow = true
        config.shouldBeOpaque = false
        config.showsCursor = false
        config.captureResolution = .best
        let image = try await grab(filter, config)
        // SCK clips the system shadow to the window bounds, so the shadow is composited here instead.
        return shadow ? withShadow(image, scale: scale) : image
    }

    private static func windowInfo(_ id: CGWindowID) -> [String: Any]? {
        (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]])?.first { ($0[kCGWindowNumber as String] as? CGWindowID) == id }
    }

    /// kCGWindowSharingState: 0 = the window opted out of capture (DRM / secure content).
    private static func sharingState(of id: CGWindowID) -> Int? { windowInfo(id)?[kCGWindowSharingState as String] as? Int }

    private static func unavailableReason(of id: CGWindowID) -> String {
        guard let info = windowInfo(id) else { return String(localized: "La ventana ya no está disponible.") }
        if (info[kCGWindowSharingState as String] as? Int) == 0 {
            return String(localized: "Esta ventana tiene contenido protegido y macOS no permite capturarla.")
        }
        return String(localized: "La ventana no está en este Space o está minimizada. Ve a ella (o sal del modo pantalla completa) e inténtalo de nuevo.")
    }

    /// Window image on a transparent canvas with a macOS-like drop shadow around it.
    static func withShadow(_ image: CGImage, scale: CGFloat) -> CGImage {
        let blur = 34 * scale, dy = 14 * scale, pad = Int((blur + dy).rounded())
        let w = image.width + pad * 2, h = image.height + pad * 2
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        ctx.setShadow(offset: CGSize(width: 0, height: -dy), blur: blur, color: CGColor(gray: 0, alpha: 0.45))
        ctx.draw(image, in: CGRect(x: pad, y: pad, width: image.width, height: image.height))
        return ctx.makeImage() ?? image
    }
}

/// On-screen windows front-to-back, in Quartz global coordinates, for hover selection.
struct WindowCandidate {
    let id: CGWindowID
    let frame: CGRect
    let owner: String

    static func onScreen() -> [WindowCandidate] {
        let me = ProcessInfo.processInfo.processIdentifier
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { info in
            // Normal, floating (always-on-top utilities) and modal panel layers; not the Dock, menu bar or overlays.
            guard [0, Int(CGWindowLevelForKey(.floatingWindow)), Int(CGWindowLevelForKey(.modalPanelWindow))]
                    .contains(info[kCGWindowLayer as String] as? Int ?? -1),
                  (info[kCGWindowOwnerPID as String] as? Int32) != me,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let b = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: b),
                  frame.width > 40, frame.height > 40,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0
            else { return nil }
            return WindowCandidate(id: id, frame: frame, owner: info[kCGWindowOwnerName as String] as? String ?? "")
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
    }

    /// Height of the primary display, the pivot for AppKit ↔ Quartz conversion.
    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }
}
