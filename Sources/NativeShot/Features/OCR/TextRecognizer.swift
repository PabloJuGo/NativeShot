import Vision
import NativeShotKit

/// On-device text and barcode recognition (OCR). Nothing leaves the Mac.
enum TextRecognizer {
    struct Result: Sendable {
        var text: String
        var barcodes: [String]
        /// Lines with normalized boxes (origin bottom-left), for the OCR window.
        var blocks: [OCRBlock] = []
    }

    /// Spanish and English are always tried first; the rest comes from what this macOS version supports.
    static let defaultLanguages = ["es-ES", "en-US"]

    static var supportedLanguages: [String] {
        let r = VNRecognizeTextRequest()
        r.recognitionLevel = .accurate
        return ((try? r.supportedRecognitionLanguages()) ?? defaultLanguages).sorted()
    }

    /// `languages == nil` is automatic detection; otherwise only the chosen language is used.
    static func recognize(_ image: CGImage, languages: [String]? = nil) async throws -> Result {
        try await Task.detached(priority: .userInitiated) {
            let text = VNRecognizeTextRequest()
            text.recognitionLevel = .accurate
            text.usesLanguageCorrection = true
            text.automaticallyDetectsLanguage = languages == nil
            text.recognitionLanguages = languages ?? defaultLanguages
            let codes = VNDetectBarcodesRequest()
            try VNImageRequestHandler(cgImage: image).perform([text, codes])
            // Vision returns observations top-to-bottom; one line per observation keeps the layout readable.
            let blocks: [OCRBlock] = (text.results ?? []).compactMap { o in
                guard let s = o.topCandidates(1).first?.string, !s.isEmpty else { return nil }
                let b = o.boundingBox
                return OCRBlock(text: s, x: b.minX, y: b.minY, w: b.width, h: b.height)
            }
            let payloads = (codes.results ?? []).compactMap(\.payloadStringValue)
            return Result(text: blocks.map(\.text).joined(separator: "\n"), barcodes: Array(Set(payloads)).sorted(), blocks: blocks)
        }.value
    }
}
