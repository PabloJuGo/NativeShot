import CoreGraphics
import Foundation

/// UI-19: everything the export manager lets the user choose, independent of preferences.
public struct ExportRequest: Sendable, Equatable {
    public var folder: URL
    public var template: String
    public var type: String
    public var app: String?
    public var format: ExportFormat
    /// 1 = full pixels, 2 = half width/height.
    public var downscale: Int
    public var keepMetadata: Bool

    public init(folder: URL, template: String = FileNamingPolicy.default.template, type: String = "screenshot", app: String? = nil,
                format: ExportFormat = .png, downscale: Int = 1, keepMetadata: Bool = false) {
        self.folder = folder; self.template = template; self.type = type; self.app = app
        self.format = format; self.downscale = downscale; self.keepMetadata = keepMetadata
    }
}

public enum ExportJob {
    /// Encodes and writes atomically; never overwrites an existing file. Returns the written URL.
    public static func run(_ image: CGImage, _ r: ExportRequest, date: Date = Date()) throws -> URL {
        try FileManager.default.createDirectory(at: r.folder, withIntermediateDirectories: true)
        let data = try ImageExporter.encode(ImageExporter.downscaled(image, factor: r.downscale), format: r.format, keepMetadata: r.keepMetadata)
        let name = FileNamingPolicy(template: r.template).name(date: date, type: r.type, app: r.app, ext: r.format.fileExtension)
        let dest = FileNamingPolicy.uniqueURL(in: r.folder, name: name)
        try data.write(to: dest, options: .atomic)
        return dest
    }
}
