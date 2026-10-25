import CoreGraphics
import Foundation

/// SCR-006: long captures as a multipage PDF. Pages are cut along the scroll axis with an A4-like proportion
/// and the stitched tiles are drawn across page boundaries, so segment seams never show.
public enum ScrollPDF {
    public enum PDFError: Error { case cannotCreate, empty }

    /// Pixel ranges (along the scroll axis) of each page; the last one may be shorter.
    public static func pageRanges(total: Int, pageLength: Int) -> [Range<Int>] {
        guard total > 0, pageLength > 0 else { return [] }
        return stride(from: 0, to: total, by: pageLength).map { $0..<min($0 + pageLength, total) }
    }

    /// `scale` = pixels per PDF point (2 on Retina) so the page shows the capture at its on-screen size.
    public static func write(parts: [CGImage], axis: ScrollAxis, scale: CGFloat, to url: URL) throws {
        guard let first = parts.first else { throw PDFError.empty }
        let vertical = axis == .vertical
        let cross = vertical ? first.width : first.height
        let total = parts.reduce(0) { $0 + (vertical ? $1.height : $1.width) }
        let pageLength = max(1, Int((Double(cross) * (vertical ? 1.4142 : 1 / 1.4142)).rounded()))
        var box = CGRect(x: 0, y: 0, width: CGFloat(vertical ? cross : pageLength) / scale, height: CGFloat(vertical ? pageLength : cross) / scale)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { throw PDFError.cannotCreate }
        for range in pageRanges(total: total, pageLength: pageLength) {
            let pageBox = CGRect(x: 0, y: 0, width: CGFloat(vertical ? cross : range.count) / scale, height: CGFloat(vertical ? range.count : cross) / scale)
            var pb = pageBox
            ctx.beginPDFPage([kCGPDFContextMediaBox as String: NSData(bytes: &pb, length: MemoryLayout<CGRect>.size)] as CFDictionary)
            var offset = 0
            for part in parts {
                let length = vertical ? part.height : part.width
                if offset + length > range.lowerBound, offset < range.upperBound {
                    let o = CGFloat(offset - range.lowerBound) / scale
                    // PDF is y-up: vertical pages count rows from the top edge.
                    let rect = vertical
                        ? CGRect(x: 0, y: pageBox.height - o - CGFloat(part.height) / scale, width: CGFloat(part.width) / scale, height: CGFloat(part.height) / scale)
                        : CGRect(x: o, y: 0, width: CGFloat(part.width) / scale, height: CGFloat(part.height) / scale)
                    ctx.draw(part, in: rect)
                }
                offset += length
            }
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }
}
