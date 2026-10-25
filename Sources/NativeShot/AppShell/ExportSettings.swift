import AppKit
import NativeShotKit

/// EXP: how a capture is written to the save folder, read from preferences.
enum ExportSettings {
    static var policy: FileNamingPolicy {
        let t = UserDefaults.standard.string(forKey: Prefs.fileNameTemplate) ?? ""
        return t.isEmpty ? .default : FileNamingPolicy(template: t)
    }

    /// Falls back to PNG when HEIC was chosen but this Mac cannot encode it.
    static var format: ExportFormat {
        let d = UserDefaults.standard
        let q = d.double(forKey: Prefs.jpegQuality)
        switch d.string(forKey: Prefs.exportFormat) {
        case "jpeg": return .jpeg(quality: q)
        case "heic" where ImageExporter.supportsHEIC: return .heic(quality: q)
        default: return .png
        }
    }

    static var downscaleFactor: Int { UserDefaults.standard.integer(forKey: Prefs.exportScale) == 1 ? 2 : 1 }

    /// The saved preferences as an export request (bulk export, export manager defaults).
    static func request(folder: URL, type: String = "screenshot", app: String? = nil) -> ExportRequest {
        ExportRequest(folder: folder, template: policy.template, type: type, app: app, format: format, downscale: downscaleFactor)
    }

    /// Encodes and writes atomically; never overwrites an existing file.
    static func write(_ image: CGImage, type: String, app: String? = nil, to folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let format = format
        let data = try ImageExporter.encode(ImageExporter.downscaled(image, factor: downscaleFactor), format: format)
        let name = policy.name(date: Date(), type: type, app: app, ext: format.fileExtension)
        let dest = FileNamingPolicy.uniqueURL(in: folder, name: name)
        try data.write(to: dest, options: .atomic)
        return dest
    }
}
