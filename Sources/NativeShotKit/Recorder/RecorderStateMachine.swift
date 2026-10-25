import Foundation

/// Recorder lifecycle:
/// idle → authorizing → configuring → countdown → recording ↔ paused → finalizing → ready.
public enum RecorderPhase: Equatable, Sendable {
    case idle, authorizing, configuring, countdown, recording, paused, finalizing, ready
    case cancelled
    /// The session failed but the user can retry straight away (permission, bad source...).
    case recoverableFailure(String)
    case fatalFailure(String)
}

public enum RecorderEvent: Sendable {
    case start, authorized, configured, countdownElapsed
    case pause, resume, stop, finalized
    case cancel, fail(String, recoverable: Bool), reset
}

public struct RecorderStateMachine: Sendable {
    public private(set) var phase: RecorderPhase = .idle
    public init() {}

    /// Returns false (state untouched) for transitions the spec does not allow. A repeated `.stop`
    /// while finalizing returns false, so the caller finalizes exactly once.
    @discardableResult
    public mutating func handle(_ event: RecorderEvent) -> Bool {
        let next: RecorderPhase?
        switch (phase, event) {
        case (.idle, .start), (.recoverableFailure, .start): next = .authorizing
        case (.authorizing, .authorized): next = .configuring
        case (.configuring, .configured): next = .countdown
        case (.countdown, .countdownElapsed): next = .recording
        case (.recording, .pause): next = .paused
        case (.paused, .resume): next = .recording
        case (.recording, .stop), (.paused, .stop): next = .finalizing
        case (.finalizing, .finalized): next = .ready
        case (.authorizing, .cancel), (.configuring, .cancel), (.countdown, .cancel),
             (.recording, .cancel), (.paused, .cancel): next = .cancelled
        case (.authorizing, .fail(let r, let rec)), (.configuring, .fail(let r, let rec)), (.countdown, .fail(let r, let rec)),
             (.recording, .fail(let r, let rec)), (.paused, .fail(let r, let rec)), (.finalizing, .fail(let r, let rec)):
            next = rec ? .recoverableFailure(r) : .fatalFailure(r)
        case (.ready, .reset), (.cancelled, .reset), (.recoverableFailure, .reset), (.fatalFailure, .reset): next = .idle
        default: next = nil
        }
        guard let next else { return false }
        phase = next
        return true
    }

    /// A session owns a stream/writer from authorizing until it finishes.
    public var isBusy: Bool {
        switch phase {
        case .idle, .ready, .cancelled, .recoverableFailure, .fatalFailure: false
        default: true
        }
    }
}
