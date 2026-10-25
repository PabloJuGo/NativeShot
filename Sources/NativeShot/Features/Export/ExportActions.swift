import AppKit

/// EXP: printing and "open with" for a capture file.
@MainActor
enum PrintAction {
    /// System print panel. The image is fitted to the printable area, never enlarged past its point size.
    static func print(_ image: CGImage) {
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        info.isHorizontallyCentered = true
        info.isVerticallyCentered = true
        info.orientation = image.width > image.height ? .landscape : .portrait
        let area = NSSize(width: info.paperSize.width - info.leftMargin - info.rightMargin,
                          height: info.paperSize.height - info.topMargin - info.bottomMargin)
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let natural = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let fit = min(1, area.width / max(natural.width, 1), area.height / max(natural.height, 1))
        let size = NSSize(width: natural.width * fit, height: natural.height * fit)
        let view = NSImageView(frame: NSRect(origin: .zero, size: size))
        view.image = NSImage(cgImage: image, size: size)
        view.imageScaling = .scaleProportionallyUpOrDown
        let op = NSPrintOperation(view: view, printInfo: info)
        op.jobTitle = "NativeShot"
        op.showsPrintPanel = true
        NSApp.activate()
        op.run()
    }
}

@MainActor
enum OpenWith {
    struct App: Identifiable { let url: URL; var id: URL { url }; var name: String { FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "") } }

    static func apps(for file: URL) -> [App] {
        NSWorkspace.shared.urlsForApplications(toOpen: file).prefix(12).map(App.init)
    }

    static func open(_ file: URL, with app: App) {
        NSWorkspace.shared.open([file], withApplicationAt: app.url, configuration: NSWorkspace.OpenConfiguration())
    }
}
