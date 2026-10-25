import CoreGraphics
import Foundation

/// CAP-009: pixel math of the magnifier.
public enum Loupe {
    /// Square of `side` pixels centred on pixel (`x`, `y`), slid back inside an image of the given size.
    public static func sourceRect(centerX x: Int, y: Int, side: Int, imageWidth: Int, imageHeight: Int) -> CGRect {
        let s = min(side, imageWidth, imageHeight)
        let ox = min(max(x - s / 2, 0), imageWidth - s), oy = min(max(y - s / 2, 0), imageHeight - s)
        return CGRect(x: ox, y: oy, width: s, height: s)
    }

    public static func hex(r: UInt8, g: UInt8, b: UInt8) -> String { String(format: "#%02X%02X%02X", r, g, b) }
}

/// CAP-011: several captured regions as one image, stacked top to bottom on a transparent canvas.
public enum RegionComposition {
    public static func layout(sizes: [(width: Int, height: Int)], spacing: Int) -> (width: Int, height: Int, origins: [Int]) {
        var y = 0
        var origins: [Int] = []
        for s in sizes { origins.append(y); y += s.height + spacing }
        return (sizes.map(\.width).max() ?? 0, max(0, y - spacing), origins)
    }

    public static func compose(_ images: [CGImage], spacing: Int = 16) -> CGImage? {
        guard let first = images.first else { return nil }
        guard images.count > 1 else { return first }
        let l = layout(sizes: images.map { ($0.width, $0.height) }, spacing: spacing)
        guard let ctx = CGContext(data: nil, width: l.width, height: l.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: first.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        for (img, top) in zip(images, l.origins) {
            // CoreGraphics is y-up: the first image sits at the top.
            ctx.draw(img, in: CGRect(x: 0, y: l.height - top - img.height, width: img.width, height: img.height))
        }
        return ctx.makeImage()
    }
}
