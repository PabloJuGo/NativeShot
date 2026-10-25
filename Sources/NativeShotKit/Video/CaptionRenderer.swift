import CoreGraphics
import CoreText
import Foundation

/// Draws one caption as a rounded dark pill with white bold text (CoreText, so it needs no AppKit).
enum CaptionRenderer {
    static func image(text: String, fontSize: CGFloat, maxWidth: CGFloat) -> CGImage? {
        let font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, max(fontSize, 6), nil)
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
        ]
        let framesetter = CTFramesetterCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        let pad = fontSize * 0.45
        let limit = CGSize(width: max(maxWidth - 2 * pad, 10), height: .greatestFiniteMagnitude)
        let fit = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(), nil, limit, nil)
        let w = Int(ceil(fit.width + 2 * pad)), h = Int(ceil(fit.height + 2 * pad))
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.65))
        ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: w, height: h), cornerWidth: pad, cornerHeight: pad, transform: nil))
        ctx.fillPath()
        let path = CGPath(rect: CGRect(x: pad, y: pad, width: CGFloat(w) - 2 * pad, height: CGFloat(h) - 2 * pad), transform: nil)
        CTFrameDraw(CTFramesetterCreateFrame(framesetter, CFRange(), path, nil), ctx)
        return ctx.makeImage()
    }
}
