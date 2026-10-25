import Foundation

/// UTL: local diagnostic report. Holds only settings, counts and states: never pixels, file names,
/// recognized text or personal paths.
public struct DiagnosticReport: Codable, Sendable, Equatable {
    public var app: String
    public var macOS: String
    public var locale: String
    public var permissions: [String: String]
    public var preferences: [String: String]
    public var shortcuts: [String: String]
    public var counts: [String: Int]

    public init(app: String, macOS: String, locale: String, permissions: [String: String] = [:],
                preferences: [String: String] = [:], shortcuts: [String: String] = [:], counts: [String: Int] = [:]) {
        self.app = app; self.macOS = macOS; self.locale = locale; self.permissions = permissions
        self.preferences = preferences; self.shortcuts = shortcuts; self.counts = counts
    }

    /// Every string value goes through `redact`, so a path slipped into a preference cannot leak the user name.
    public func json(home: String = NSHomeDirectory()) throws -> Data {
        var copy = self
        func clean(_ d: [String: String]) -> [String: String] { d.mapValues { Diagnostics.redact($0, home: home) } }
        copy.permissions = clean(permissions); copy.preferences = clean(preferences); copy.shortcuts = clean(shortcuts)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(copy)
    }
}

public enum Diagnostics {
    /// Replaces the home directory (and any other `/Users/<name>` prefix) with `~`.
    public static func redact(_ s: String, home: String = NSHomeDirectory()) -> String {
        var out = s
        if home.count > 1 { out = out.replacingOccurrences(of: home, with: "~") }
        return out.replacingOccurrences(of: "/Users/[^/\\s\"]+", with: "~", options: .regularExpression)
    }
}
