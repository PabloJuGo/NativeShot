import Foundation

public enum VideoCommand: Sendable {
    case split(at: Double)
    case deleteRange(from: Double, to: Double)
    case deleteSegment(UUID)
    case trimStart(to: Double)
    case trimEnd(to: Double)
    case addZoom(ZoomKeyframe)
    case updateZoom(ZoomKeyframe)
    case removeZoom(UUID)
    /// Replaces the auto-generated keyframes and keeps the manual ones.
    case setAutoZooms([ZoomKeyframe])
    case setAudio(index: Int, AudioTrackSettings)
    case setSpeed(Double)
    case addMute(MuteRange)
    case removeMute(UUID)
    case addCaption(VideoCaption)
    case updateCaption(VideoCaption)
    case removeCaption(UUID)
    case setCrop(NormalizedRect)
    case setAudioSelection(AudioSelection)
    /// 0 = off ... 1.
    case setFollow(Double)
}

/// Project plus undo/redo. Each command is applied to a copy and the previous project is kept as its inverse:
/// the project is a few KB of value types, so snapshots are cheaper and safer than hand-written inverses.
public struct VideoEditHistory: Sendable {
    public private(set) var project: VideoProject
    private var undoStack: [VideoProject] = []
    private var redoStack: [VideoProject] = []
    static let maxDepth = 200

    public init(project: VideoProject) { self.project = project }
    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    /// Returns false (nothing changes, nothing recorded) when the command is invalid or has no effect.
    @discardableResult
    public mutating func apply(_ command: VideoCommand, sourceDuration: Double) -> Bool {
        var p = project
        let ok: Bool
        switch command {
        case .split(let t): ok = p.split(at: t)
        case .deleteRange(let a, let b): ok = p.deleteRange(from: a, to: b)
        case .deleteSegment(let id):
            if let s = p.segments.first(where: { $0.id == id }) { ok = p.deleteRange(from: s.start, to: s.end) } else { ok = false }
        case .trimStart(let t): ok = p.deleteRange(from: 0, to: t)
        case .trimEnd(let t): ok = p.deleteRange(from: t, to: sourceDuration)
        case .addZoom(let k):
            ok = p.zooms.allSatisfy { $0.id != k.id } && k.rect.isValid
            if ok { p.zooms.append(k); p.zooms.sort { $0.time < $1.time } }
        case .updateZoom(let k):
            if let i = p.zooms.firstIndex(where: { $0.id == k.id }), k.rect.isValid {
                p.zooms[i] = k; p.zooms.sort { $0.time < $1.time }; ok = true
            } else { ok = false }
        case .removeZoom(let id):
            ok = p.zooms.contains { $0.id == id }
            p.zooms.removeAll { $0.id == id }
        case .setAutoZooms(let ks):
            p.zooms = (p.zooms.filter { !$0.auto } + ks).sorted { $0.time < $1.time }
            ok = true
        case .setAudio(let i, let s):
            ok = p.audio.indices.contains(i) && (0...4).contains(s.gain) && s.fadeIn >= 0 && s.fadeOut >= 0
            if ok { p.audio[i] = s }
        case .setSpeed(let v):
            ok = VideoProject.speedRange.contains(v)
            if ok { p.speed = v }
        case .addMute(let m):
            ok = m.isValid && m.end <= sourceDuration + 0.05 && p.mutes.count < 512 && p.mutes.allSatisfy { $0.id != m.id }
            if ok { p.mutes.append(m); p.mutes.sort { $0.start < $1.start } }
        case .removeMute(let id):
            ok = p.mutes.contains { $0.id == id }
            p.mutes.removeAll { $0.id == id }
        case .addCaption(let c):
            ok = c.isValid && p.captions.count < 200 && p.captions.allSatisfy { $0.id != c.id }
            if ok { p.captions.append(c); p.captions.sort { $0.start < $1.start } }
        case .updateCaption(let c):
            if let i = p.captions.firstIndex(where: { $0.id == c.id }), c.isValid {
                p.captions[i] = c; p.captions.sort { $0.start < $1.start }; ok = true
            } else { ok = false }
        case .removeCaption(let id):
            ok = p.captions.contains { $0.id == id }
            p.captions.removeAll { $0.id == id }
        case .setCrop(let r):
            ok = r.isValid
            if ok { p.crop = r }
        case .setAudioSelection(let a):
            ok = true
            p.audioSelection = a
        case .setFollow(let v):
            ok = v.isFinite && (0...1).contains(v)
            if ok { p.followIntensity = v }
        }
        guard ok, p != project else { return false }
        undoStack.append(project)
        if undoStack.count > Self.maxDepth { undoStack.removeFirst() }
        redoStack.removeAll()
        project = p
        return true
    }

    @discardableResult
    public mutating func undo() -> Bool {
        guard let prev = undoStack.popLast() else { return false }
        redoStack.append(project); project = prev
        return true
    }

    @discardableResult
    public mutating func redo() -> Bool {
        guard let next = redoStack.popLast() else { return false }
        undoStack.append(project); project = next
        return true
    }
}
