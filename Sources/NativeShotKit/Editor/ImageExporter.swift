import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ExportFormat: Sendable, Equatable {
    case png
    case jpeg(quality: Double)
    case heic(quality: Double)
    case tiff
    /// One page holding the flattened bitmap (never vector objects, so redactions stay irreversible).
    case pdf

    public var fileExtension: String {
        switch self { case .png: "png"; case .jpeg: "jpg"; case .heic: "heic"; case .tiff: "tiff"; case .pdf: "pdf" }
    }

    /// Format for a file name's extension; unknown extensions fall back to PNG.
    public static func forExtension(_ ext: String) -> ExportFormat {
        switch ext.lowercased() {
        case "jpg", "jpeg": .jpeg(quality: 0.9)
        case "heic": .heic(quality: 0.9)
        case "tif", "tiff": .tiff
        case "pdf": .pdf
        default: .png
        }
    }

    /// Extensions this OS can write (HEIC depends on ImageIO). WebP is deliberately absent: ImageIO cannot write it.
    public static var writableExtensions: [String] {
        ["png", "jpg", "tiff", "pdf"] + (ImageExporter.supportsHEIC ? ["heic"] : [])
    }
}

public enum ExportError: Error, Equatable, Sendable {
    case renderFailed, encodeFailed
}

/// Writes flattened pixels only: the encoder is given no metadata dictionary, so nothing from the
/// source (EXIF, GPS, app info) is carried over.
public enum ImageExporter {
    /// HEIC encoding depends on the OS/hardware: ask ImageIO instead of assuming.
    public static var supportsHEIC: Bool {
        (CGImageDestinationCopyTypeIdentifiers() as? [String])?.contains("public.heic") ?? false
    }

    /// Downscale by an integer factor (2 = half width/height). Factor 1 returns the image untouched.
    public static func downscaled(_ image: CGImage, factor: Int) -> CGImage {
        guard factor > 1 else { return image }
        let w = max(1, image.width / factor), h = max(1, image.height / factor)
        guard let ctx = EditorRenderer.makeContext(width: w, height: h, like: image) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }

    public static func data(for doc: EditorDocument, format: ExportFormat) throws -> Data {
        guard let image = EditorRenderer.render(doc) else { throw ExportError.renderFailed }
        return try encode(image, format: format)
    }

    private static func pdf(_ image: CGImage) throws -> Data {
        let out = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        guard let consumer = CGDataConsumer(data: out), let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { throw ExportError.encodeFailed }
        ctx.beginPDFPage(nil)
        ctx.draw(image, in: box)
        ctx.endPDFPage()
        ctx.closePDF()
        return out as Data
    }

    /// `keepMetadata` writes only a Software/date stamp. Captures carry no EXIF or GPS, so nothing else exists to keep.
    public static func encode(_ image: CGImage, format: ExportFormat, keepMetadata: Bool = false) throws -> Data {
        var image = image
        var options: [CFString: Any] = [:]
        if keepMetadata {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy:MM:dd HH:mm:ss"
            options[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFSoftware: "NativeShot", kCGImagePropertyTIFFDateTime: f.string(from: Date())]
        }
        let type: UTType
        switch format {
        case .tiff:
            type = .tiff
        case .pdf:
            return try pdf(image)
        case .png:
            type = .png
        case .heic(let q):
            type = UTType("public.heic")!
            options[kCGImageDestinationLossyCompressionQuality] = max(0.1, min(q, 1))
        case .jpeg(let q):
            type = .jpeg
            options[kCGImageDestinationLossyCompressionQuality] = max(0.1, min(q, 1))
            // JPEG has no alpha: flatten onto white instead of letting transparency turn black.
            guard let ctx = EditorRenderer.makeContext(width: image.width, height: image.height, like: image) else { throw ExportError.encodeFailed }
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            guard let flat = ctx.makeImage() else { throw ExportError.encodeFailed }
            image = flat
        }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil) else { throw ExportError.encodeFailed }
        CGImageDestinationAddImage(dest, image, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ExportError.encodeFailed }
        return out as Data
    }
}
