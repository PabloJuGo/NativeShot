import CoreGraphics
import Foundation
import ImageIO

public enum NShotError: Error, Equatable, Sendable, LocalizedError {
    case notAPackage
    case missingFile(String)
    case unsafePath(String)
    case unsupportedVersion(Int)
    case tooLarge(String)
    case sizeMismatch
    case corrupt(String)

    public var errorDescription: String? {
        switch self {
        case .notAPackage: String(localized: "El proyecto no es un paquete .nshot válido.")
        case .missingFile(let f): String(localized: "Falta el archivo «\(f)» del proyecto.")
        case .unsafePath(let p): String(localized: "El proyecto contiene una ruta no permitida: \(p)")
        case .unsupportedVersion(let v): String(localized: "El proyecto usa una versión de formato no compatible (\(v)).")
        case .tooLarge(let f): String(localized: "El archivo «\(f)» del proyecto es demasiado grande.")
        case .sizeMismatch: String(localized: "Las dimensiones de la imagen no coinciden con el proyecto.")
        case .corrupt(let why): String(localized: "El proyecto está dañado: \(why)")
        }
    }
}

/// `.nshot` is a directory: `manifest.json` (format version, relative resource paths, pixel size),
/// `original.png` and `objects.json`. Opening treats the package as untrusted input.
public enum NShotPackage {
    /// v2 adds picture objects (`images/`), border, curved/double arrows and the new object kinds; v1 files open unchanged.
    public static let currentVersion = 2
    static let maxSide = 32_768
    static let maxPixels = 100_000_000
    static let maxImageBytes = 512 << 20
    static let maxJSONBytes = 16 << 20
    static let maxObjects = 10_000

    struct Manifest: Codable {
        var formatVersion: Int
        var image: String
        var objects: String
        var width: Int
        var height: Int
        /// v2: object/backdrop pictures, `UUID string -> relative path`.
        var images: [String: String]?
    }

    struct Payload: Codable {
        var objects: [Annotation]
        var crop: CGRect?
        var background: BackdropStyle?
        var border: ImageBorder?
    }

    static let maxImages = 200

    public static func write(_ doc: EditorDocument, to url: URL) throws {
        let fm = FileManager.default
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).nshot-tmp")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: false)
        do {
            let enc = JSONEncoder()
            var files: [String: String] = [:]
            if !doc.referencedImageIDs.isEmpty { try fm.createDirectory(at: tmp.appendingPathComponent("images"), withIntermediateDirectories: false) }
            for id in doc.referencedImageIDs {
                guard let img = doc.images[id] else { continue }
                let rel = "images/\(id.uuidString).png"
                try ImageExporter.encode(img, format: .png).write(to: tmp.appendingPathComponent(rel))
                files[id.uuidString] = rel
            }
            let manifest = Manifest(formatVersion: currentVersion, image: "original.png", objects: "objects.json",
                                    width: doc.original.width, height: doc.original.height, images: files.isEmpty ? nil : files)
            try enc.encode(manifest).write(to: tmp.appendingPathComponent("manifest.json"))
            try ImageExporter.encode(doc.original, format: .png).write(to: tmp.appendingPathComponent("original.png"))
            try enc.encode(Payload(objects: doc.objects, crop: doc.crop, background: doc.background, border: doc.border))
                .write(to: tmp.appendingPathComponent("objects.json"))
            if fm.fileExists(atPath: url.path) {
                _ = try fm.replaceItemAt(url, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: url)
            }
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
    }

    public static func read(from url: URL) throws -> EditorDocument {
        let root = url.resolvingSymlinksInPath()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else { throw NShotError.notAPackage }

        let manifest: Manifest
        do { manifest = try JSONDecoder().decode(Manifest.self, from: try load(root, "manifest.json", limit: 1 << 16)) }
        catch let e as NShotError { throw e }
        catch { throw NShotError.corrupt("manifest.json") }
        guard manifest.formatVersion >= 1, manifest.formatVersion <= currentVersion else { throw NShotError.unsupportedVersion(manifest.formatVersion) }
        guard (1...maxSide).contains(manifest.width), (1...maxSide).contains(manifest.height),
              manifest.width * manifest.height <= maxPixels else { throw NShotError.tooLarge("manifest.json") }

        let imageURL = try safeURL(root, manifest.image)
        let objectsURL = try safeURL(root, manifest.objects)
        try checkSize(imageURL, limit: maxImageBytes, name: manifest.image)
        guard let src = CGImageSourceCreateWithURL(imageURL as CFURL, nil), CGImageSourceGetCount(src) == 1,
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int
        else { throw NShotError.corrupt(manifest.image) }
        // Compare before decoding so a tiny file declaring huge dimensions never allocates.
        guard w == manifest.width, h == manifest.height else { throw NShotError.sizeMismatch }
        guard let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw NShotError.corrupt(manifest.image) }

        let payload: Payload
        do { payload = try JSONDecoder().decode(Payload.self, from: try load(root, manifest.objects, limit: maxJSONBytes, url: objectsURL)) }
        catch let e as NShotError { throw e }
        catch { throw NShotError.corrupt(manifest.objects) }
        try validate(payload, width: w, height: h)

        var doc = EditorDocument(original: image)
        doc.objects = payload.objects
        doc.crop = payload.crop
        doc.background = payload.background
        doc.border = payload.border
        doc.images = try loadImages(manifest.images ?? [:], root: root)
        for id in doc.referencedImageIDs where doc.images[id] == nil { throw NShotError.corrupt("images") }
        return doc
    }

    private static func loadImages(_ files: [String: String], root: URL) throws -> [UUID: CGImage] {
        guard files.count <= maxImages else { throw NShotError.tooLarge("images") }
        var out: [UUID: CGImage] = [:]
        var total = 0
        for (key, rel) in files {
            guard let id = UUID(uuidString: key) else { throw NShotError.corrupt("images") }
            let url = try safeURL(root, rel)
            try checkSize(url, limit: maxImageBytes, name: rel)
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(src) == 1,
                  let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
                  let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
                  (1...maxSide).contains(w), (1...maxSide).contains(h), w * h <= maxPixels
            else { throw NShotError.corrupt(rel) }
            total += w * h
            guard total <= 4 * maxPixels else { throw NShotError.tooLarge("images") }
            guard let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw NShotError.corrupt(rel) }
            out[id] = img
        }
        return out
    }

    // MARK: Validation

    /// Rejects absolute paths, `..`, empty components and anything that resolves outside the package (symlinks).
    static func safeURL(_ root: URL, _ rel: String) throws -> URL {
        let parts = rel.split(separator: "/", omittingEmptySubsequences: false)
        guard !rel.isEmpty, !rel.hasPrefix("/"), !rel.contains("\0"), !rel.contains("\\"),
              !parts.contains(where: { $0.isEmpty || $0 == ".." || $0 == "." }), !rel.hasPrefix("~")
        else { throw NShotError.unsafePath(rel) }
        let url = root.appendingPathComponent(rel)
        guard url.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else { throw NShotError.unsafePath(rel) }
        return url
    }

    private static func checkSize(_ url: URL, limit: Int, name: String) throws {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path), attrs[.type] as? FileAttributeType == .typeRegular,
              let size = attrs[.size] as? Int else { throw NShotError.missingFile(name) }
        guard size <= limit else { throw NShotError.tooLarge(name) }
    }

    private static func load(_ root: URL, _ name: String, limit: Int, url: URL? = nil) throws -> Data {
        let u = try url ?? safeURL(root, name)
        try checkSize(u, limit: limit, name: name)
        guard let d = try? Data(contentsOf: u) else { throw NShotError.missingFile(name) }
        return d
    }

    private static func validate(_ p: Payload, width: Int, height: Int) throws {
        func bad(_ why: String) -> NShotError { .corrupt(why) }
        guard p.objects.count <= maxObjects else { throw NShotError.tooLarge("objects") }
        func ok(_ pt: CGPoint) -> Bool { pt.x.isFinite && pt.y.isFinite && abs(pt.x) <= 1e6 && abs(pt.y) <= 1e6 }
        var ids = Set<UUID>()
        for a in p.objects {
            guard ids.insert(a.id).inserted else { throw bad("duplicate id") }
            guard ok(a.start), ok(a.end), a.points.count <= 100_000, a.points.allSatisfy(ok) else { throw bad("coordinates") }
            guard a.text.count <= 10_000, (0...9999).contains(a.number) else { throw bad("text") }
            guard a.curve.isFinite, abs(a.curve) <= 10, a.cornerRadius.isFinite, (0...10_000).contains(a.cornerRadius),
                  a.magnification.isFinite, (1...50).contains(a.magnification) else { throw bad("shape") }
            let s = a.style
            guard s.width.isFinite, (0...500).contains(s.width), s.opacity.isFinite, (0...1).contains(s.opacity),
                  [s.color.r, s.color.g, s.color.b, s.color.a].allSatisfy({ $0.isFinite && (0...1).contains($0) })
            else { throw bad("style") }
        }
        if let c = p.crop {
            guard c.minX.isFinite, c.minY.isFinite, c.width.isFinite, c.height.isFinite, c.width >= 1, c.height >= 1,
                  c.minX >= 0, c.minY >= 0, c.maxX <= Double(width), c.maxY <= Double(height) else { throw bad("crop") }
        }
        if let b = p.border {
            guard b.width.isFinite, (0...500).contains(b.width),
                  [b.color.r, b.color.g, b.color.b, b.color.a].allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { throw bad("border") }
        }
        if let b = p.background {
            guard b.padding.isFinite, (0...2000).contains(b.padding), b.cornerRadius.isFinite, (0...2000).contains(b.cornerRadius),
                  [b.color.r, b.color.g, b.color.b, b.color.a].allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { throw bad("background") }
            if let e = b.gradientEnd {
                guard [e.r, e.g, e.b, e.a].allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { throw bad("background") }
            }
        }
    }
}
