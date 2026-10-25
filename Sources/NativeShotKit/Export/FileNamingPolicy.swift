import Foundation

/// Builds export file names from a template (EXP). Tokens: {date} {time} {type} {app} {n}.
public struct FileNamingPolicy: Sendable, Equatable {
    public var template: String
    public static let `default` = FileNamingPolicy(template: "NativeShot {date} at {time}")

    public init(template: String) { self.template = template }

    public func name(date: Date, type: String, app: String? = nil, counter: Int = 1,
                     timeZone: TimeZone = .current, ext: String) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let d = String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
        let t = String(format: "%02d.%02d.%02d", c.hour!, c.minute!, c.second!)
        let raw = template
            .replacingOccurrences(of: "{date}", with: d)
            .replacingOccurrences(of: "{time}", with: t)
            .replacingOccurrences(of: "{type}", with: type)
            .replacingOccurrences(of: "{app}", with: app ?? "")
            .replacingOccurrences(of: "{n}", with: String(counter))
        let base = Self.sanitize(raw)
        return "\(base.isEmpty ? "NativeShot" : base).\(ext)"
    }

    /// Strips path separators and control characters so a template can never escape the target folder.
    static func sanitize(_ s: String) -> String {
        let banned = CharacterSet(charactersIn: "/:\\").union(.controlCharacters).union(.newlines)
        let cleaned = String(String.UnicodeScalarView(s.unicodeScalars.filter { !banned.contains($0) }))
        var out = cleaned.trimmingCharacters(in: .whitespaces)
        while out.hasPrefix(".") { out.removeFirst() } // no hidden files / ".." tricks
        // File systems cap names at 255 UTF-8 bytes; the budget leaves room for the extension and a " 2" suffix.
        var clipped = ""
        for ch in out {
            guard clipped.utf8.count + ch.utf8.count <= 200 else { break }
            clipped.append(ch)
        }
        return clipped
    }

    /// First URL in `folder` for `name` that doesn't exist yet ("x.png", "x 2.png", …). Never overwrites.
    public static func uniqueURL(in folder: URL, name: String, exists: (URL) -> Bool = {
        FileManager.default.fileExists(atPath: $0.path)
    }) -> URL {
        let url = folder.appendingPathComponent(name)
        guard exists(url) else { return url }
        let ext = url.pathExtension, stem = url.deletingPathExtension().lastPathComponent
        var i = 2
        while true {
            let candidate = folder.appendingPathComponent("\(stem) \(i)").appendingPathExtension(ext)
            if !exists(candidate) { return candidate }
            i += 1
        }
    }
}
