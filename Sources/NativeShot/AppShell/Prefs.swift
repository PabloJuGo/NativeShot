import Foundation
import NativeShotKit

/// UserDefaults keys. Values stay in the platform form (@AppStorage reads them directly).
enum Prefs {
    static let afterCapture = "afterCapture"          // AfterCapture.rawValue
    static let showsCursor = "showsCursor"
    static let windowShadow = "windowShadow"
    static let playSound = "playSound"
    static let saveFolder = "saveFolder"              // path; default ~/Pictures/NativeShot
    static let timerSeconds = "timerSeconds"
    static let overlayDuration = "overlayDuration"    // seconds, 0 = until closed
    static let overlayCorner = "overlayCorner"        // OverlayCorner.rawValue
    static let keepHistory = "keepHistory"
    static let ocrIndex = "ocrIndex"
    static let historyMaxCount = "historyMaxCount"    // 0 = never delete automatically
    static let trashRetentionDays = "trashRetentionDays" // 0 = keep trashed items until emptied by hand

    static let fileNameTemplate = "fileNameTemplate" // FileNamingPolicy template
    static let exportFormat = "exportFormat"          // png | jpeg | heic
    static let jpegQuality = "jpegQuality"            // 0.1...1, also used for HEIC
    static let exportScale = "exportScale"            // 2 = full pixels, 1 = half (points on Retina)
    static let adjustRegion = "adjustRegion"          // CAP-001: keep the region editable after releasing the mouse
    static let aspectPreset = "aspectPreset"          // CAP-006: AspectPreset.rawValue
    static let showLoupe = "showLoupe"                // CAP-009
    static let freezeScreen = "freezeScreen"          // CAP-010
    static let multiRegionJoin = "multiRegionJoin"    // CAP-011: true = one composition, false = one capture per region
    static let hideDesktopIcons = "hideDesktopIcons"  // CAP-012
    static let excludeNotch = "excludeNotch"          // CAP-019
    static let scrollAxis = "scrollAxis"              // SCR-002: ScrollAxis.rawValue
    static let scrollPDF = "scrollPDF"                // SCR-006: also write a multipage PDF
    static let scrollCrop = "scrollCrop"              // SCR-007: offer a final crop before saving
    static let showDockIcon = "showDockIcon"
    static let onboardingDone = "onboardingDone"
    static let ocrOpensWindow = "ocrOpensWindow"      // "Capturar texto" opens the result window instead of copying
    static let urlSchemeEnabled = "urlSchemeEnabled"  // nativeshot:// actions, off by default
    static let urlSchemeAllowed = "urlSchemeAllowed"  // comma separated URLSchemeCommand raw values

    static func register() {
        UserDefaults.standard.register(defaults: [
            afterCapture: AfterCapture.overlay.rawValue,
            showsCursor: false,
            windowShadow: true,
            playSound: true,
            timerSeconds: 0,
            overlayDuration: 6,
            overlayCorner: OverlayCorner.bottomLeft.rawValue,
            keepHistory: true,
            ocrIndex: true,
            historyMaxCount: 0,
            trashRetentionDays: 30,
            fileNameTemplate: FileNamingPolicy.default.template,
            exportFormat: "png",
            jpegQuality: 0.9,
            exportScale: 2,
            adjustRegion: false,
            aspectPreset: AspectPreset.free.rawValue,
            showLoupe: false,
            freezeScreen: false,
            multiRegionJoin: true,
            hideDesktopIcons: false,
            excludeNotch: false,
            scrollAxis: ScrollAxis.vertical.rawValue,
            scrollPDF: false,
            scrollCrop: true,
            showDockIcon: false,
            onboardingDone: false,
            ocrOpensWindow: false,
            urlSchemeEnabled: false,
            urlSchemeAllowed: "",
        ])
    }

    static var saveFolderURL: URL {
        if let p = UserDefaults.standard.string(forKey: saveFolder), !p.isEmpty { return URL(fileURLWithPath: p) }
        return FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0].appendingPathComponent("NativeShot")
    }
}

/// CAP-020: what happens right after a capture.
enum AfterCapture: String, CaseIterable {
    case overlay, copy, save, copyAndSave
}

enum OverlayCorner: String, CaseIterable {
    case bottomLeft, bottomRight, topLeft, topRight
}
