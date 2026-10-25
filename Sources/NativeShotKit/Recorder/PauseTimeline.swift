import CoreMedia

/// Maps capture-clock timestamps to output timestamps, removing paused spans so the movie has no gap.
/// Video defines the timeline; audio is dropped until video has resumed so tracks stay in sync.
public struct PauseTimeline: Sendable {
    private var origin: CMTime?
    private var offset: CMTime = .zero
    private var lastVideo: CMTime?
    private var resumeBoundary: CMTime?
    private var isPaused = false
    private var awaitingResume = false

    public init() {}

    public mutating func pause() { isPaused = true }

    public mutating func resume() {
        guard isPaused else { return }
        isPaused = false
        awaitingResume = lastVideo != nil
    }

    /// `frameDuration` is the nominal interval: the first frame after a pause lands one interval after the last.
    public mutating func video(_ pts: CMTime, frameDuration: CMTime) -> CMTime? {
        guard !isPaused else { return nil }
        if origin == nil { origin = pts }
        if awaitingResume, let last = lastVideo {
            offset = offset + (pts - last) - frameDuration
            resumeBoundary = pts
            awaitingResume = false
        }
        lastVideo = pts
        return pts - origin! - offset
    }

    public func audio(_ pts: CMTime) -> CMTime? {
        guard let origin, !isPaused, !awaitingResume else { return nil }
        if let b = resumeBoundary, pts < b { return nil }
        let t = pts - origin - offset
        return t >= .zero ? t : nil
    }

    /// Output time of an event (click) that happened at capture-clock `pts`; nil while paused or before the first frame.
    public func event(_ pts: CMTime) -> CMTime? { audio(pts) }
}
