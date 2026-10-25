import CoreGraphics
import CoreText
import Foundation

enum TextLayout {
    static func line(_ s: String, fontSize: Double, color: CGColor = CGColor(gray: 0, alpha: 1)) -> CTLine {
        let font = CTFontCreateUIFontForLanguage(.system, fontSize, nil) ?? CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let attrs: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: color]
        return CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs as [NSAttributedString.Key: Any]))
    }

    static func lineHeight(fontSize: Double) -> (ascent: Double, height: Double) {
        let l = line("Hg", fontSize: fontSize)
        var a: CGFloat = 0, d: CGFloat = 0, g: CGFloat = 0
        CTLineGetTypographicBounds(l, &a, &d, &g)
        return (a, a + d + g)
    }

    static func size(_ text: String, fontSize: Double) -> CGSize {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let w = lines.map { CTLineGetTypographicBounds(line(String($0), fontSize: fontSize), nil, nil, nil) }.max() ?? 0
        return CGSize(width: max(w, 1), height: lineHeight(fontSize: fontSize).height * Double(max(lines.count, 1)))
    }
}

/// Flattens a document into a bitmap. Redaction objects rewrite the pixels beneath them in the same
/// bitmap, so nothing from the original survives in the output.
public enum EditorRenderer {
    /// `applyCrop`/`applyBackground` are off for the live canvas, which always shows the full image.
    public static func render(_ doc: EditorDocument, applyCrop: Bool = true, applyBackground: Bool = true) -> CGImage? {
        let full = CGRect(origin: .zero, size: doc.imageSize)
        var region = full
        if applyCrop, let c = doc.crop {
            let r = c.integral.intersection(full)
            if !r.isNull, r.width >= 1, r.height >= 1 { region = r }
        }
        let w = Int(region.width), h = Int(region.height)
        guard let ctx = makeContext(width: w, height: h, like: doc.original) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(doc.original, in: CGRect(x: -region.minX, y: -(full.height - region.maxY), width: full.width, height: full.height))
        // From here on: top-left origin, image pixel coordinates.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: -region.minX, y: -region.minY)
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        // A magnifier must never reveal pixels a redaction hides, wherever it sits in the layer order.
        var safeBase: CGImage?
        if doc.objects.contains(where: { $0.kind == .magnifier }) {
            var d = doc
            d.objects = doc.objects.filter(\.kind.isRedaction)
            d.crop = nil; d.background = nil; d.border = nil
            safeBase = render(d, applyCrop: false, applyBackground: false)
        }
        for a in doc.objects { draw(a, in: ctx, region: region, doc: doc, safeBase: safeBase) }
        if let b = doc.border, b.width > 0 {
            ctx.setStrokeColor(b.color.cg)
            ctx.setLineWidth(b.width)
            ctx.stroke(region.insetBy(dx: b.width / 2, dy: b.width / 2))
        }
        guard let content = ctx.makeImage() else { return nil }
        if applyBackground, let bg = doc.background { return compose(content, bg, images: doc.images) }
        return content
    }

    static func makeContext(width: Int, height: Int, like image: CGImage?) -> CGContext? {
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        if let cs = image?.colorSpace, cs.model == .rgb,
           let c = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: info) { return c }
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info)
    }

    // MARK: Objects

    private static func rounded(_ r: CGRect, _ radius: Double) -> CGPath {
        let k = max(0, min(radius, r.width / 2, r.height / 2))
        return k > 0 ? CGPath(roundedRect: r, cornerWidth: k, cornerHeight: k, transform: nil) : CGPath(rect: r, transform: nil)
    }

    private static func drawArrow(_ a: Annotation, in ctx: CGContext) {
        let len = hypot(a.end.x - a.start.x, a.end.y - a.start.y)
        guard len > 0 else { return }
        let head = min(max(12, a.style.width * 4), a.headStart && a.headEnd ? len / 2 : len)
        let c = a.controlPoint
        var from = a.start, to = a.end
        var heads: [(tip: CGPoint, base: CGPoint, ux: Double, uy: Double)] = []
        func addHead(tip: CGPoint) -> CGPoint {
            let l = hypot(tip.x - c.x, tip.y - c.y)
            let ux = (tip.x - c.x) / l, uy = (tip.y - c.y) / l
            let base = CGPoint(x: tip.x - ux * head, y: tip.y - uy * head)
            heads.append((tip, base, ux, uy))
            return base
        }
        if a.headEnd { to = addHead(tip: a.end) }
        if a.headStart { from = addHead(tip: a.start) }
        ctx.move(to: from)
        ctx.addQuadCurve(to: to, control: c)
        ctx.strokePath()
        let half = head * 0.45
        for h in heads {
            ctx.move(to: h.tip)
            ctx.addLine(to: CGPoint(x: h.base.x - h.uy * half, y: h.base.y + h.ux * half))
            ctx.addLine(to: CGPoint(x: h.base.x + h.uy * half, y: h.base.y - h.ux * half))
            ctx.closePath(); ctx.fillPath()
        }
    }

    private static func drawMagnifier(_ a: Annotation, in ctx: CGContext, safeBase: CGImage?) {
        let b = a.bounds
        let r = min(b.width, b.height) / 2
        guard r >= 1, let src = safeBase else { return }
        let c = CGPoint(x: b.midX, y: b.midY)
        let z = max(1.5, min(a.magnification, 8))
        ctx.saveGState()
        ctx.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)); ctx.clip()
        ctx.translateBy(x: c.x, y: c.y); ctx.scaleBy(x: z, y: z); ctx.translateBy(x: -c.x, y: -c.y)
        ctx.translateBy(x: 0, y: CGFloat(src.height)); ctx.scaleBy(x: 1, y: -1)
        ctx.draw(src, in: CGRect(x: 0, y: 0, width: src.width, height: src.height))
        ctx.restoreGState()
        let w = a.style.width
        ctx.strokeEllipse(in: CGRect(x: c.x - r + w / 2, y: c.y - r + w / 2, width: 2 * r - w, height: 2 * r - w))
    }

    private static func draw(_ a: Annotation, in ctx: CGContext, region: CGRect, doc: EditorDocument, safeBase: CGImage?) {
        if a.kind.isRedaction { redact(a, in: ctx, region: region); return }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setAlpha(a.style.opacity)
        // Offset is in base space (y up), unlike the flipped drawing space.
        if a.shadow && a.kind != .spotlight { ctx.setShadow(offset: CGSize(width: 2, height: -4), blur: 8, color: CGColor(gray: 0, alpha: 0.5)) }
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        defer { ctx.endTransparencyLayer() }
        let color = a.style.color.cg
        ctx.setStrokeColor(color)
        ctx.setFillColor(color)
        ctx.setLineWidth(a.style.width)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        switch a.kind {
        case .line:
            ctx.move(to: a.start); ctx.addLine(to: a.end); ctx.strokePath()
        case .arrow: drawArrow(a, in: ctx)
        case .rectangle:
            ctx.addPath(rounded(a.bounds, a.cornerRadius)); ctx.strokePath()
        case .filledRectangle:
            ctx.addPath(rounded(a.bounds, a.cornerRadius)); ctx.fillPath()
        case .underline:
            ctx.move(to: CGPoint(x: a.bounds.minX, y: a.bounds.maxY)); ctx.addLine(to: CGPoint(x: a.bounds.maxX, y: a.bounds.maxY)); ctx.strokePath()
        case .strikethrough:
            ctx.move(to: CGPoint(x: a.bounds.minX, y: a.bounds.midY)); ctx.addLine(to: CGPoint(x: a.bounds.maxX, y: a.bounds.midY)); ctx.strokePath()
        case .spotlight:
            let path = CGMutablePath()
            path.addRect(region)
            path.addPath(rounded(a.bounds, a.cornerRadius))
            ctx.addPath(path); ctx.fillPath(using: .evenOdd)
        case .magnifier: drawMagnifier(a, in: ctx, safeBase: safeBase)
        case .image:
            guard let id = a.imageID, let img = doc.images[id] else { return }
            let b = a.bounds
            guard b.width >= 1, b.height >= 1 else { return }
            ctx.addPath(rounded(b, a.cornerRadius)); ctx.clip()
            ctx.translateBy(x: b.minX, y: b.maxY); ctx.scaleBy(x: 1, y: -1)
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: b.width, height: b.height))
        case .ellipse: ctx.strokeEllipse(in: a.bounds)
        case .freehand, .highlighter:
            let pts = a.points.isEmpty ? [a.start, a.end] : a.points
            if a.kind == .highlighter {
                ctx.setBlendMode(.multiply)
                ctx.setLineWidth(a.highlighterWidth)
                ctx.setLineCap(.butt)
            }
            ctx.move(to: pts[0])
            if pts.count == 1 { ctx.addLine(to: pts[0]) }
            pts.dropFirst().forEach { ctx.addLine(to: $0) }
            ctx.strokePath()
        case .text:
            let lh = TextLayout.lineHeight(fontSize: a.fontSize)
            for (i, s) in a.text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                ctx.textPosition = CGPoint(x: a.start.x, y: a.start.y + lh.ascent + lh.height * Double(i))
                CTLineDraw(TextLayout.line(String(s), fontSize: a.fontSize, color: color), ctx)
            }
        case .counter:
            ctx.fillEllipse(in: a.bounds)
            let ink = a.style.color.luminance > 0.6 ? CGColor(gray: 0, alpha: 1) : CGColor(gray: 1, alpha: 1)
            let line = TextLayout.line(String(a.number), fontSize: a.counterRadius * 1.1, color: ink)
            let r = CTLineGetBoundsWithOptions(line, [])
            // y-down space: the glyph spans baseline - maxY ... baseline - minY, so centre the baseline accordingly.
            ctx.textPosition = CGPoint(x: a.start.x - r.midX, y: a.start.y + (r.maxY + r.minY) / 2)
            CTLineDraw(line, ctx)
        default: break
        }
    }

    // MARK: Redaction (pixel rewriting)

    private static func redact(_ a: Annotation, in ctx: CGContext, region: CGRect) {
        guard let data = ctx.data else { return }
        let local = a.bounds.offsetBy(dx: -region.minX, dy: -region.minY)
        let x0 = max(0, Int(local.minX.rounded(.down))), y0 = max(0, Int(local.minY.rounded(.down)))
        let x1 = min(ctx.width, Int(local.maxX.rounded(.up))), y1 = min(ctx.height, Int(local.maxY.rounded(.up)))
        guard x1 > x0, y1 > y0 else { return }
        let px = data.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * ctx.height)
        let stride = ctx.bytesPerRow
        let strength = max(2, a.style.width)
        switch a.kind {
        case .redact:
            let c = a.style.color
            let rgb = [c.r, c.g, c.b].map { UInt8(max(0, min(255, ($0 * 255).rounded()))) }
            for y in y0..<y1 {
                for x in x0..<x1 {
                    let o = y * stride + x * 4
                    px[o] = rgb[0]; px[o + 1] = rgb[1]; px[o + 2] = rgb[2]; px[o + 3] = 255
                }
            }
        case .pixelate:
            let block = max(2, Int(strength * 3))
            var by = y0
            while by < y1 {
                var bx = x0
                while bx < x1 {
                    let ex = min(bx + block, x1), ey = min(by + block, y1)
                    var sum = [Int](repeating: 0, count: 4)
                    for y in by..<ey { for x in bx..<ex { let o = y * stride + x * 4; for c in 0..<4 { sum[c] += Int(px[o + c]) } } }
                    let n = (ex - bx) * (ey - by)
                    for y in by..<ey { for x in bx..<ex { let o = y * stride + x * 4; for c in 0..<4 { px[o + c] = UInt8(sum[c] / n) } } }
                    bx = ex
                }
                by += block
            }
        default: // blur
            let w = x1 - x0, h = y1 - y0
            var buf = [UInt8](repeating: 0, count: w * h * 4)
            for y in 0..<h { for i in 0..<(w * 4) { buf[y * w * 4 + i] = px[(y0 + y) * stride + x0 * 4 + i] } }
            let r = max(1, min(Int(strength * 2.5), max(w, h) / 2))
            for _ in 0..<3 { boxBlur(&buf, w: w, h: h, radius: r) }
            for y in 0..<h { for i in 0..<(w * 4) { px[(y0 + y) * stride + x0 * 4 + i] = buf[y * w * 4 + i] } }
        }
    }

    /// Edges clamp to the region, so no pixel outside it influences the result.
    private static func boxBlur(_ buf: inout [UInt8], w: Int, h: Int, radius r: Int) {
        var tmp = buf
        pass(buf, &tmp, count: w, lines: h, step: 4, lineStep: w * 4, r)
        pass(tmp, &buf, count: h, lines: w, step: w * 4, lineStep: 4, r)
    }

    private static func pass(_ src: [UInt8], _ dst: inout [UInt8], count: Int, lines: Int, step: Int, lineStep: Int, _ r: Int) {
        let div = 2 * r + 1
        for line in 0..<lines {
            for c in 0..<4 {
                let base = line * lineStep + c
                var sum = 0
                for i in -r...r { sum += Int(src[base + min(max(i, 0), count - 1) * step]) }
                for i in 0..<count {
                    dst[base + i * step] = UInt8((sum + div / 2) / div)
                    sum += Int(src[base + min(i + r + 1, count - 1) * step]) - Int(src[base + max(i - r, 0) * step])
                }
            }
        }
    }

    // MARK: Background (BG)

    private static func compose(_ content: CGImage, _ bg: BackdropStyle, images: [UUID: CGImage]) -> CGImage? {
        let pad = Int((bg.autoBalance ? Double(max(content.width, content.height)) * 0.08 : max(0, min(bg.padding, 2000))).rounded())
        var w = content.width + 2 * pad, h = content.height + 2 * pad
        if let ar = bg.aspect?.ratio { // grow the shorter axis; the capture stays centred
            if Double(w) / Double(h) < ar { w = Int((Double(h) * ar).rounded(.up)) } else { h = Int((Double(w) / ar).rounded(.up)) }
        }
        guard w <= GeometryOp.maxSide, h <= GeometryOp.maxSide, w * h <= GeometryOp.maxPixels,
              let ctx = makeContext(width: w, height: h, like: content) else { return nil }
        let canvas = CGRect(x: 0, y: 0, width: w, height: h)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        if let end = bg.gradientEnd,
           let g = CGGradient(colorsSpace: space, colors: [bg.color.cg, end.cg] as CFArray, locations: nil) {
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: CGFloat(h)), end: CGPoint(x: CGFloat(w), y: 0), options: [])
        } else {
            ctx.setFillColor(bg.color.cg)
            ctx.fill(canvas)
        }
        if let id = bg.imageID, let img = images[id] { // aspect-fill, centred
            let k = max(Double(w) / Double(img.width), Double(h) / Double(img.height))
            let iw = Double(img.width) * k, ih = Double(img.height) * k
            ctx.interpolationQuality = .high
            ctx.draw(img, in: CGRect(x: (Double(w) - iw) / 2, y: (Double(h) - ih) / 2, width: iw, height: ih))
        }
        if let pattern = bg.pattern { drawPattern(pattern, in: ctx, size: canvas.size, dark: bg.color.luminance < 0.5) }
        let rect = CGRect(x: (w - content.width) / 2, y: (h - content.height) / 2, width: content.width, height: content.height)
        let radius = min(bg.cornerRadius, Double(min(content.width, content.height)) / 2)
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        let shadowSize = Double(min(w, h) - min(content.width, content.height)) / 2
        if bg.shadow, shadowSize > 0 {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -shadowSize / 6), blur: shadowSize / 2, color: CGColor(gray: 0, alpha: 0.4))
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            ctx.addPath(path); ctx.fillPath()
            ctx.restoreGState()
        }
        ctx.addPath(path); ctx.clip()
        ctx.draw(content, in: rect)
        return ctx.makeImage()
    }

    private static func drawPattern(_ p: BackdropPattern, in ctx: CGContext, size: CGSize, dark: Bool) {
        let step = max(12, min(size.width, size.height) / 30)
        ctx.saveGState()
        defer { ctx.restoreGState() }
        let ink = CGColor(gray: dark ? 1 : 0, alpha: dark ? 0.2 : 0.12)
        ctx.setFillColor(ink); ctx.setStrokeColor(ink)
        switch p {
        case .dots:
            var y = step / 2
            while y < size.height {
                var x = step / 2
                while x < size.width { ctx.fillEllipse(in: CGRect(x: x - step / 10, y: y - step / 10, width: step / 5, height: step / 5)); x += step }
                y += step
            }
        case .grid:
            ctx.setLineWidth(max(1, step / 24))
            var x = 0.0
            while x <= size.width { ctx.move(to: CGPoint(x: x, y: 0)); ctx.addLine(to: CGPoint(x: x, y: size.height)); x += step }
            var y = 0.0
            while y <= size.height { ctx.move(to: CGPoint(x: 0, y: y)); ctx.addLine(to: CGPoint(x: size.width, y: y)); y += step }
            ctx.strokePath()
        case .stripes:
            ctx.setLineWidth(step / 4)
            var x = -size.height
            while x <= size.width { ctx.move(to: CGPoint(x: x, y: 0)); ctx.addLine(to: CGPoint(x: x + size.height, y: size.height)); x += step * 1.5 }
            ctx.strokePath()
        }
    }
}
