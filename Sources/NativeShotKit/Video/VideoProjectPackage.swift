import Foundation

public enum VideoProjectError: Error, Equatable, Sendable, LocalizedError {
    case notAPackage
    case missingFile(String)
    case unsafePath(String)
    case unsupportedVersion(Int)
    case missingSource(String)
    case invalid(String)
    case corrupt(String)

    public var errorDescription: String? {
        switch self {
        case .notAPackage: String(localized: "El proyecto no es un paquete .nshotvideo válido.")
        case .missingFile(let f): String(localized: "Falta el archivo «\(f)» del proyecto.")
        case .unsafePath(let p): String(localized: "El proyecto contiene una ruta no permitida: \(p)")
        case .unsupportedVersion(let v): String(localized: "El proyecto usa una versión de formato no compatible (\(v)).")
        case .missingSource(let p): String(localized: "No se encuentra el vídeo original del proyecto (\(p)). Puede que se haya eliminado de la biblioteca.")
        case .invalid(let why): String(localized: "El proyecto contiene valores no válidos: \(why)")
        case .corrupt(let f): String(localized: "El proyecto está dañado: \(f)")
        }
    }
}

/// `.nshotvideo` is a directory: `manifest.json` (version, library-relative source path, source duration) and
/// `project.json` (the edit). Opening treats it as untrusted input.
public enum VideoProjectPackage {
    public static let currentVersion = 1
    static let maxJSONBytes = 8 << 20

    struct Manifest: Codable {
        var formatVersion: Int
        /// Relative to the library root, e.g. `originals/<uuid>/source.mp4`.
        var source: String
        var sourceDuration: Double
        var project: String
    }

    /// Where periodic autosaves of the project for `source` go: `<library>/autosave/<source folder>.nshotvideo`.
    public static func autosaveURL(libraryRoot: URL, source: URL) -> URL {
        libraryRoot.appendingPathComponent("autosave", isDirectory: true)
            .appendingPathComponent(source.deletingLastPathComponent().lastPathComponent + ".nshotvideo", isDirectory: true)
    }

    public struct Opened: Sendable {
        public var project: VideoProject
        public var sourceURL: URL
        public var sourceDuration: Double
    }

    /// `source` must live inside `libraryRoot`; otherwise the project could not be reopened portably.
    public static func write(_ project: VideoProject, source: URL, sourceDuration: Double, libraryRoot: URL, to url: URL) throws {
        let rootPath = libraryRoot.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        let srcPath = source.standardizedFileURL.resolvingSymlinksInPath().path
        guard srcPath.hasPrefix(rootPath) else { throw VideoProjectError.unsafePath(source.lastPathComponent) }
        let manifest = Manifest(formatVersion: currentVersion, source: String(srcPath.dropFirst(rootPath.count)),
                                sourceDuration: sourceDuration, project: "project.json")
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).nshotvideo-tmp")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: false)
        do {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(manifest).write(to: tmp.appendingPathComponent("manifest.json"))
            try enc.encode(project).write(to: tmp.appendingPathComponent("project.json"))
            if fm.fileExists(atPath: url.path) { _ = try fm.replaceItemAt(url, withItemAt: tmp) } else { try fm.moveItem(at: tmp, to: url) }
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
    }

    public static func read(from url: URL, libraryRoot: URL) throws -> Opened {
        let root = url.resolvingSymlinksInPath()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else { throw VideoProjectError.notAPackage }

        let manifest: Manifest
        do { manifest = try JSONDecoder().decode(Manifest.self, from: try load(root, "manifest.json")) }
        catch let e as VideoProjectError { throw e }
        catch { throw VideoProjectError.corrupt("manifest.json") }
        guard manifest.formatVersion >= 1, manifest.formatVersion <= currentVersion else { throw VideoProjectError.unsupportedVersion(manifest.formatVersion) }
        guard manifest.project == "project.json" else { throw VideoProjectError.unsafePath(manifest.project) }

        let project: VideoProject
        do { project = try JSONDecoder().decode(VideoProject.self, from: try load(root, manifest.project)) }
        catch let e as VideoProjectError { throw e }
        catch { throw VideoProjectError.corrupt(manifest.project) }
        try project.validate(sourceDuration: manifest.sourceDuration)

        let lib = libraryRoot.resolvingSymlinksInPath()
        let sourceURL: URL
        do { sourceURL = try NShotPackage.safeURL(lib, manifest.source) } catch { throw VideoProjectError.unsafePath(manifest.source) }
        guard FileManager.default.fileExists(atPath: sourceURL.path) else { throw VideoProjectError.missingSource(manifest.source) }
        return Opened(project: project, sourceURL: sourceURL, sourceDuration: manifest.sourceDuration)
    }

    private static func load(_ root: URL, _ name: String) throws -> Data {
        let u = root.appendingPathComponent(name)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: u.path), attrs[.type] as? FileAttributeType == .typeRegular,
              let size = attrs[.size] as? Int else { throw VideoProjectError.missingFile(name) }
        guard size <= maxJSONBytes, let d = try? Data(contentsOf: u) else { throw VideoProjectError.corrupt(name) }
        return d
    }
}
