import Foundation

public enum CaptureMode: String, Sendable, CaseIterable, Codable {
    case region, window, display, scrolling, textRecognition
}

/// Capture lifecycle: idle → preparing → selecting → capturing → processing → ready,
/// with cancelled/failed returning to idle.
public enum CapturePhase: Equatable, Sendable {
    case idle, preparing, selecting, capturing, processing, ready
    case cancelled
    case failed(String)
}

public enum CaptureEvent: Sendable {
    case begin, overlayShown, selectionConfirmed, pixelsReceived, artifactStored
    case cancel, fail(String), reset
}

public struct CaptureStateMachine: Sendable {
    public private(set) var phase: CapturePhase = .idle
    public init() {}

    /// Returns false (and leaves state untouched) for transitions the spec does not allow.
    @discardableResult
    public mutating func handle(_ event: CaptureEvent) -> Bool {
        let next: CapturePhase?
        switch (phase, event) {
        case (.idle, .begin): next = .preparing
        case (.preparing, .overlayShown): next = .selecting
        case (.preparing, .selectionConfirmed): next = .capturing // fullscreen: no interactive selection
        case (.selecting, .selectionConfirmed): next = .capturing
        case (.capturing, .pixelsReceived): next = .processing
        case (.processing, .artifactStored): next = .ready
        case (.preparing, .cancel), (.selecting, .cancel): next = .cancelled
        case (.idle, .fail), (.ready, .fail), (.cancelled, .fail): next = nil
        case (_, .fail(let reason)): next = .failed(reason)
        case (.ready, .reset), (.cancelled, .reset), (.failed, .reset): next = .idle
        default: next = nil
        }
        guard let next else { return false }
        phase = next
        return true
    }

    public var isBusy: Bool {
        switch phase {
        case .idle, .ready, .cancelled, .failed: false
        default: true
        }
    }
}
