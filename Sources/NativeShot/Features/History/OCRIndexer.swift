import Vision
import NativeShotKit

/// Background OCR for the search index. Separate from `TextRecognizer`, which serves the
/// interactive "copy text" flow and has no use for the boxes.
enum OCRIndexer {
    /// Blocking: call from a detached task, never the main actor.
    static func recognize(_ image: CGImage) throws -> [OCRBlock] {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        req.automaticallyDetectsLanguage = true
        req.recognitionLanguages = ["es-ES", "en-US"]
        try VNImageRequestHandler(cgImage: image).perform([req])
        return (req.results ?? []).compactMap { o in
            guard let s = o.topCandidates(1).first?.string, !s.isEmpty else { return nil }
            let b = o.boundingBox
            return OCRBlock(text: s, x: b.minX, y: b.minY, w: b.width, h: b.height)
        }
    }
}
