import Foundation

/// UTL: `nativeshot://<command>` actions. Disabled by default; every command needs the user's
/// confirmation at run time, so no URL can capture silently.
public enum URLSchemeCommand: String, CaseIterable, Sendable {
    case region, window, display, ocr, record
    case lastRegion = "last-region", openLibrary = "open-library", pinClipboard = "pin-clipboard"

    public enum Rejection: Error, Equatable, Sendable {
        case disabled, wrongScheme, unknown, notAllowed(URLSchemeCommand), unexpectedParameters
    }

    /// Commands that grab the screen (the dialog warns about them).
    public var capturesScreen: Bool {
        switch self {
        case .region, .window, .display, .ocr, .lastRegion, .record: true
        case .openLibrary, .pinClipboard: false
        }
    }

    /// Strict on purpose: no query, fragment, user info or extra path is accepted, so the URL carries
    /// no data, only a command name.
    public static func parse(_ url: URL, enabled: Bool, allowed: Set<URLSchemeCommand>) -> Result<URLSchemeCommand, Rejection> {
        guard url.scheme?.lowercased() == "nativeshot" else { return .failure(.wrongScheme) }
        guard enabled else { return .failure(.disabled) }
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return .failure(.unknown) }
        guard c.query == nil, c.fragment == nil, c.user == nil, c.password == nil, c.port == nil,
              c.path.isEmpty || c.path == "/" else { return .failure(.unexpectedParameters) }
        guard let host = c.host?.lowercased(), let cmd = URLSchemeCommand(rawValue: host) else { return .failure(.unknown) }
        return allowed.contains(cmd) ? .success(cmd) : .failure(.notAllowed(cmd))
    }
}
