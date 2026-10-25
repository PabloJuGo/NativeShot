import CoreGraphics

/// Coordinate conversions between AppKit global space (origin bottom-left of the primary display, y up)
/// and Quartz/ScreenCaptureKit global space (origin top-left of the primary display, y down).
public enum DisplayGeometry {
    /// Flips a rect between AppKit and Quartz global space. The operation is its own inverse.
    public static func flip(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Rect spanned by a drag from `a` to `b`, regardless of drag direction.
    public static func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// Converts a global rect to display-local coordinates, clipped to the display. Nil if they don't intersect.
    public static func local(_ rect: CGRect, in displayFrame: CGRect) -> CGRect? {
        let clipped = rect.intersection(displayFrame)
        guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1 else { return nil }
        return clipped.offsetBy(dx: -displayFrame.minX, dy: -displayFrame.minY)
    }

    /// Pixel size for a point rect on a display with the given backing scale, rounded to whole pixels.
    public static func pixelSize(of rect: CGRect, scale: CGFloat) -> (width: Int, height: Int) {
        (Int((rect.width * scale).rounded()), Int((rect.height * scale).rounded()))
    }

    /// Snaps a point rect so its edges fall on whole device pixels (avoids half-pixel blurry captures).
    public static func pixelAligned(_ rect: CGRect, scale: CGFloat) -> CGRect {
        let minX = (rect.minX * scale).rounded(.down) / scale
        let minY = (rect.minY * scale).rounded(.down) / scale
        let maxX = (rect.maxX * scale).rounded(.up) / scale
        let maxY = (rect.maxY * scale).rounded(.up) / scale
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
