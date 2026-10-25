import Foundation

/// UTL: manual update check against a GitHub releases feed. This file only parses and compares; the
/// request itself is made by the app, once, when the user asks. No identifiers are sent.
public enum UpdateCheck {
    public struct Release: Sendable, Equatable {
        public var tag: String
        public var url: URL
    }

    /// `https://github.com/owner/repo[.git][/…]` → the releases/latest API endpoint. nil for anything else.
    public static func latestReleaseEndpoint(repository: String) -> URL? {
        guard let u = URL(string: repository.trimmingCharacters(in: .whitespacesAndNewlines)), u.scheme == "https",
              u.host?.lowercased() == "github.com" else { return nil }
        let parts = u.pathComponents.filter { $0 != "/" }
        guard parts.count >= 2 else { return nil }
        let repo = parts[1].hasSuffix(".git") ? String(parts[1].dropLast(4)) : parts[1]
        let ok = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        guard [parts[0], repo].allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy(ok.contains) }) else { return nil }
        return URL(string: "https://api.github.com/repos/\(parts[0])/\(repo)/releases/latest")
    }

    public static func parseLatest(_ data: Data) -> Release? {
        struct R: Decodable { var tag_name: String; var html_url: String; var draft: Bool? }
        guard let r = try? JSONDecoder().decode(R.self, from: data), r.draft != true,
              let url = URL(string: r.html_url), url.scheme == "https" else { return nil }
        return Release(tag: r.tag_name, url: url)
    }

    /// Numeric dotted comparison. "v1.0.0-rc1" is 1.0.0 with a pre-release mark: it sorts before 1.0.0.
    public static func isNewer(_ tag: String, than current: String) -> Bool {
        let (a, ap) = parts(tag), (b, bp) = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return !ap && bp
    }

    private static func parts(_ v: String) -> ([Int], Bool) {
        var s = v.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        let core = s.split(separator: "-", maxSplits: 1).first.map(String.init) ?? s
        return (core.split(separator: ".").map { Int($0) ?? 0 }, s.contains("-"))
    }
}
