import Foundation

/// UTL: preferences as a JSON file. Only keys with a rule are ever exported or imported, and imported
/// values are checked against their rule, so a hand-edited or hostile file can't set arbitrary defaults.
public struct PreferencesBackup: Sendable {
    public enum Rule: Sendable {
        case bool
        case int(ClosedRange<Int>)
        case double(ClosedRange<Double>)
        case string(allowed: Set<String>?, maxLength: Int)
        /// A file-system path: personal data, left out unless the user opts in.
        case path
    }

    public struct Rejection: Sendable, Equatable {
        public var key: String
        public var reason: String
    }

    public struct Imported: Sendable {
        public var accepted: [String: JSONValue]
        public var rejected: [Rejection]
    }

    /// Minimal Sendable JSON scalar (the preferences here are only bool, number or string).
    public enum JSONValue: Sendable, Equatable, Codable {
        case bool(Bool), number(Double), string(String)

        public init(from d: Decoder) throws {
            let c = try d.singleValueContainer()
            if let v = try? c.decode(Bool.self) { self = .bool(v) }
            else if let v = try? c.decode(Double.self) { self = .number(v) }
            else { self = .string(try c.decode(String.self)) }
        }

        public func encode(to e: Encoder) throws {
            var c = e.singleValueContainer()
            switch self {
            case .bool(let v): try c.encode(v)
            case .number(let v): try c.encode(v)
            case .string(let v): try c.encode(v)
            }
        }

        public var any: Any {
            switch self {
            case .bool(let v): v
            case .number(let v): v
            case .string(let v): v
            }
        }
    }

    public static let formatVersion = 1
    private struct File: Codable {
        var app: String
        var version: Int
        var preferences: [String: JSONValue]
    }

    public let rules: [String: Rule]
    public init(rules: [String: Rule]) { self.rules = rules }

    /// Keys whose value is personal and needs the user's review before leaving the Mac.
    public func sensitiveKeys(in values: [String: Any]) -> [String] {
        values.keys.filter { if case .path = rules[$0] { true } else { false } }.sorted()
    }

    /// Serializes known keys only. Paths are omitted unless `includeSensitive`.
    public func export(_ values: [String: Any], includeSensitive: Bool) throws -> Data {
        var out: [String: JSONValue] = [:]
        for (k, rule) in rules {
            guard let v = values[k] else { continue }
            if case .path = rule, !includeSensitive { continue }
            if let j = Self.json(v) { out[k] = j }
        }
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(File(app: "NativeShot", version: Self.formatVersion, preferences: out))
    }

    /// Bad values are listed in `rejected`; it throws only when the file is not one of ours.
    public func validate(_ data: Data) throws -> Imported {
        guard data.count < 1_000_000, let f = try? JSONDecoder().decode(File.self, from: data), f.app == "NativeShot" else {
            throw CocoaError(.fileReadCorruptFile)
        }
        guard f.version <= Self.formatVersion else { throw CocoaError(.fileReadUnsupportedScheme) }
        var accepted: [String: JSONValue] = [:], rejected: [Rejection] = []
        for (k, v) in f.preferences.sorted(by: { $0.key < $1.key }) {
            guard let rule = rules[k] else { rejected.append(.init(key: k, reason: "clave desconocida")); continue }
            if let why = Self.problem(v, rule) { rejected.append(.init(key: k, reason: why)) } else { accepted[k] = v }
        }
        return Imported(accepted: accepted, rejected: rejected)
    }

    private static func json(_ v: Any) -> JSONValue? {
        switch v {
        case let b as Bool: .bool(b)
        case let n as NSNumber: .number(n.doubleValue)
        case let s as String: .string(s)
        default: nil
        }
    }

    private static func problem(_ v: JSONValue, _ rule: Rule) -> String? {
        switch (rule, v) {
        case (.bool, .bool): nil
        case (.int(let r), .number(let n)): n == n.rounded() && r.contains(Int(exactly: n) ?? Int.min) ? nil : "fuera de rango"
        case (.double(let r), .number(let n)): r.contains(n) ? nil : "fuera de rango"
        case (.string(let allowed, let max), .string(let s)):
            s.count > max ? "demasiado largo" : (allowed.map { $0.contains(s) } ?? true) ? nil : "valor no permitido"
        case (.path, .string(let s)):
            s.hasPrefix("/") && s.count < 1024 && !s.contains("\0") ? nil : "ruta no válida"
        default: "tipo incorrecto"
        }
    }
}
