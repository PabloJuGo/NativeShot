import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Disk thumbnails (`thumbnails/<uuid>.jpg`) decoded straight to the target size, so a 5K original
/// never gets fully decoded for a grid cell.
public enum Thumbnails {
    public static let maxPixel = 480

    public static func url(for id: UUID, root: URL) -> URL {
        root.appendingPathComponent("thumbnails/\(id.uuidString).jpg")
    }

    /// Writes the JPEG atomically. Safe to call off the main thread.
    public static func generate(from original: URL, to dest: URL) throws {
        guard let src = CGImageSourceCreateWithURL(original as CFURL, nil),
              let img = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
              ] as CFDictionary) else { throw CocoaError(.fileReadCorruptFile) }
        try write(img, to: dest)
    }

    /// Writes an already-sized image (e.g. a video poster frame) as the thumbnail JPEG, atomically.
    public static func write(_ img: CGImage, to dest: URL) throws {
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = dest.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        guard let out = CGImageDestinationCreateWithURL(tmp as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(out, img, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(out) else {
            try? FileManager.default.removeItem(at: tmp)
            throw CocoaError(.fileWriteUnknown)
        }
        _ = try FileManager.default.replaceItemAt(dest, withItemAt: tmp)
    }
}
