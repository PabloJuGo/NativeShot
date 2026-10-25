import os

/// Intervals for Instruments (Points of Interest / os_signpost), subsystem `app.nativeshot.NativeShot`,
/// category `Rendimiento`. Measures the critical paths of the performance targets (B-02, B-03, editor entry).
/// Open intervals are keyed by name, so a begin and an end can live in different files.
enum Signposts {
    private static let signposter = OSSignposter(subsystem: "app.nativeshot.NativeShot", category: "Rendimiento")
    private static let open = OSAllocatedUnfairLock<[String: OSSignpostIntervalState]>(initialState: [:])

    static func begin(_ name: StaticString) {
        let state = signposter.beginInterval(name)
        open.withLock { $0[name.description] = state }
    }

    /// No-op when the interval was never opened (e.g. the capture was cancelled before reaching the end point).
    static func end(_ name: StaticString) {
        guard let state = open.withLock({ $0.removeValue(forKey: name.description) }) else { return }
        signposter.endInterval(name, state)
    }
}
