import AppKit
import AVFoundation
import Combine
import UniformTypeIdentifiers
import NativeShotKit

private struct Unchecked<T>: @unchecked Sendable { let v: T }

/// State of one video editing window. Edits go through `VideoEditHistory`; every change rebuilds the very
/// composition the exporter uses, so the preview shows the final result.
@MainActor
final class VideoEditorModel: ObservableObject {
    let sourceURL: URL
    let libraryRoot: URL
    let sourceDuration: Double
    let videoSize: CGSize
    let audioTrackCount: Int
    let clicks: [VideoClickEvent]?
    /// The recording has pointer samples (or at least clicks), so cursor follow can work.
    let hasCursorTrack: Bool
    let player = AVPlayer()

    @Published private(set) var history: VideoEditHistory
    @Published private(set) var dirty = false
    @Published var playhead = 0.0 // source seconds
    @Published private(set) var isPlaying = false
    @Published var selectedSegment: UUID?
    @Published var selectedCaption: UUID?
    @Published var selectedZoom: UUID? { didSet { if (oldValue == nil) != (selectedZoom == nil) { rebuild() } } }
    @Published private(set) var thumbnails: [NSImage] = []
    @Published private(set) var exportPhase: ExportPhase?
    @Published private(set) var exportProgress = 0.0
    @Published var showExportSheet = false
    var projectURL: URL?
    weak var window: NSWindow?
    var isScrubbing = false

    var project: VideoProject { history.project }
    private var rebuildTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    private var observer: Any?
    private var autosaveTask: Task<Void, Never>?
    private var lastAutosaved: VideoProject?
    private var bag = Set<AnyCancellable>()

    static func load(source: URL, libraryRoot: URL, project: VideoProject?, projectURL: URL? = nil) async throws -> VideoEditorModel {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw VideoComposerError.noVideoTrack }
        let duration = try await asset.load(.duration).seconds
        let size = try await track.load(.naturalSize)
        let audio = try await asset.loadTracks(withMediaType: .audio).count
        let m = VideoEditorModel(source: source, root: libraryRoot, duration: duration, size: size, audio: audio,
                                 project: project ?? VideoProject(duration: duration))
        m.projectURL = projectURL
        return m
    }

    private init(source: URL, root: URL, duration: Double, size: CGSize, audio: Int, project: VideoProject) {
        sourceURL = source; libraryRoot = root; sourceDuration = duration; videoSize = size; audioTrackCount = audio
        clicks = VideoClickEvents.load(from: VideoClickEvents.sidecarURL(forSource: source))
        hasCursorTrack = VideoClickEvents.loadCursor(from: VideoClickEvents.sidecarURL(forSource: source)) != nil
        history = VideoEditHistory(project: project)
        player.publisher(for: \.timeControlStatus).receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.isPlaying = $0 != .paused }.store(in: &bag)
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, !self.isScrubbing, self.isPlaying else { return }
                self.playhead = self.project.timeMap.sourceTime(forOutput: t.seconds)
            }
        }
        rebuild()
        generateThumbnails()
        autosaveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                self?.autosave()
            }
        }
    }

    /// Called when the window closes (a nonisolated deinit cannot touch the observer token). Closing means the
    /// project was saved or the user chose to discard it, so the autosave is no longer needed; a crash leaves it behind.
    func shutdown() {
        autosaveTask?.cancel()
        try? FileManager.default.removeItem(at: autosaveURL)
        player.pause()
        if let observer { player.removeTimeObserver(observer) }
        observer = nil
        player.replaceCurrentItem(with: nil)
        rebuildTask?.cancel()
    }

    // MARK: Autosave

    var autosaveURL: URL { VideoProjectPackage.autosaveURL(libraryRoot: libraryRoot, source: sourceURL) }

    /// Every 30 s while there are unsaved edits, into `<library>/autosave/`, never over the user's own project file.
    private func autosave() {
        guard dirty, project != lastAutosaved, !isExporting else { return }
        let p = project, src = sourceURL, d = sourceDuration, root = libraryRoot, url = autosaveURL
        Task {
            if (try? await Task.detached { try VideoProjectPackage.write(p, source: src, sourceDuration: d, libraryRoot: root, to: url) }.value) != nil {
                lastAutosaved = p
            }
        }
    }

    /// An autosave was restored: the edits exist only in memory until the user saves.
    func markRestored() { dirty = true }

    // MARK: Playback

    var outputDuration: Double { project.timeMap.outputDuration }

    func togglePlay() {
        if isPlaying { player.pause(); return }
        if player.currentTime().seconds >= outputDuration - 0.05 { seek(to: project.segments.first?.start ?? 0) }
        player.play()
    }

    /// `exact` is false while dragging the playhead so scrubbing stays responsive.
    func seek(to source: Double, exact: Bool = true) {
        let s = project.timeMap.snapToKept(min(max(source, 0), sourceDuration))
        playhead = s
        let t = CMTime(seconds: project.timeMap.outputTime(forSource: s) ?? 0, preferredTimescale: 600)
        let tol = exact ? CMTime.zero : CMTime(value: 1, timescale: 15)
        player.seek(to: t, toleranceBefore: tol, toleranceAfter: tol)
    }

    // MARK: Editing

    @discardableResult
    func apply(_ command: VideoCommand) -> Bool {
        guard history.apply(command, sourceDuration: sourceDuration) else { NSSound.beep(); return false }
        didChange()
        return true
    }

    func undo() { if history.undo() { didChange() } }
    func redo() { if history.redo() { didChange() } }

    private func didChange() {
        dirty = true
        let ids = Set(project.segments.map(\.id))
        if let s = selectedSegment, !ids.contains(s) { selectedSegment = nil }
        if let z = selectedZoom, !project.zooms.contains(where: { $0.id == z }) { selectedZoom = nil }
        if let c = selectedCaption, !project.captions.contains(where: { $0.id == c }) { selectedCaption = nil }
        playhead = project.timeMap.snapToKept(playhead)
        rebuild()
    }

    func split() { apply(.split(at: playhead)) }
    func trimStart() { apply(.trimStart(to: playhead)) }
    func trimEnd() { apply(.trimEnd(to: playhead)) }

    func deleteSelection() {
        if let z = selectedZoom { apply(.removeZoom(z)) }
        else if let s = selectedSegment { apply(.deleteSegment(s)) }
        else { NSSound.beep() }
    }

    func addZoom() {
        let k = ZoomKeyframe(time: playhead, rect: NormalizedRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        if apply(.addZoom(k)) { selectedZoom = k.id; selectedSegment = nil }
    }

    /// Output frame after the crop mask: what the preview and the export show.
    var outputSize: CGSize { project.croppedSize(of: videoSize) }

    /// Mutes the selected segment, or 3 s from the playhead when none is selected.
    func addMute() {
        let r = project.segments.first { $0.id == selectedSegment }.map { ($0.start, $0.end) } ?? (playhead, min(playhead + 3, sourceDuration))
        apply(.addMute(MuteRange(start: r.0, end: r.1)))
    }

    func addCaption() {
        let c = VideoCaption(start: playhead, end: min(playhead + 3, sourceDuration), text: String(localized: "Texto"))
        if apply(.addCaption(c)) { selectedCaption = c.id }
    }

    func suggestZooms() {
        guard let clicks else { return }
        apply(.setAutoZooms(AutoZoom.suggest(clicks: clicks, duration: sourceDuration)))
    }

    // MARK: Preview

    private func rebuild() {
        rebuildTask?.cancel()
        let project = project, asset = AVURLAsset(url: sourceURL)
        // While a keyframe is selected the preview shows the whole frame so its rectangle can be edited on top.
        let zoom = selectedZoom == nil
        let wasPlaying = isPlaying, source = playhead
        rebuildTask = Task {
            guard let c = try? await VideoComposer.build(project: project, asset: asset, applyZoom: zoom), !Task.isCancelled else { return }
            let item = AVPlayerItem(asset: c.composition)
            item.videoComposition = c.videoComposition
            item.audioMix = c.audioMix
            item.audioTimePitchAlgorithm = .spectral
            player.replaceCurrentItem(with: item)
            await player.seek(to: CMTime(seconds: project.timeMap.outputTime(forSource: source) ?? 0, preferredTimescale: 600),
                              toleranceBefore: .zero, toleranceAfter: .zero)
            if wasPlaying, !Task.isCancelled { player.play() }
        }
    }

    private func generateThumbnails() {
        let url = sourceURL, duration = sourceDuration
        Task {
            let frames = await Task.detached(priority: .utility) { () -> [Unchecked<CGImage>] in
                let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                gen.appliesPreferredTrackTransform = true
                gen.maximumSize = CGSize(width: 240, height: 135)
                gen.requestedTimeToleranceBefore = .positiveInfinity; gen.requestedTimeToleranceAfter = .positiveInfinity
                let n = 32
                var out: [Unchecked<CGImage>] = []
                for i in 0..<n {
                    let t = CMTime(seconds: duration * (Double(i) + 0.5) / Double(n), preferredTimescale: 600)
                    if let cg = try? await gen.image(at: t).image { out.append(Unchecked(v: cg)) }
                }
                return out
            }.value
            thumbnails = frames.map { NSImage(cgImage: $0.v, size: .zero) }
        }
    }

    // MARK: Project

    func saveProject() {
        func write(_ url: URL) {
            let p = project, src = sourceURL, d = sourceDuration, root = libraryRoot
            Task {
                do {
                    try await Task.detached { try VideoProjectPackage.write(p, source: src, sourceDuration: d, libraryRoot: root, to: url) }.value
                    projectURL = url
                    dirty = false
                    try? FileManager.default.removeItem(at: autosaveURL)
                    Toast.show(String(localized: "Proyecto guardado"), symbol: "checkmark.circle")
                } catch { Toast.show(error.localizedDescription, symbol: "exclamationmark.triangle") }
            }
        }
        if let projectURL { write(projectURL); return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "nshotvideo", conformingTo: .package) ?? .package]
        panel.directoryURL = Prefs.saveFolderURL
        panel.nameFieldStringValue = FileNamingPolicy.default.name(date: Date(), type: "videoproject", ext: "nshotvideo")
        if let window {
            Task { if await panel.beginSheetModal(for: window) == .OK, let url = panel.url { write(url) } }
        } else if panel.runModal() == .OK, let url = panel.url { write(url) }
    }

    // MARK: Export

    func export(preset: ExportPreset, options: ExportOptions = .init()) {
        guard exportTask == nil, preset.isValid, options.isValid else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [options.container == .mov ? .quickTimeMovie : .mpeg4Movie]
        panel.directoryURL = Prefs.saveFolderURL
        panel.nameFieldStringValue = FileNamingPolicy.default.name(date: Date(), type: "recording", ext: options.container.fileExtension)
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        let p = project, src = sourceURL
        player.pause()
        exportPhase = .queued; exportProgress = 0
        exportTask = Task {
            do {
                let used = try await VideoExporter.export(project: p, source: src, preset: preset, options: options, to: dest) { [weak self] phase, fraction in
                    Task { @MainActor in
                        guard let self, self.exportTask != nil else { return }
                        self.exportPhase = phase; self.exportProgress = fraction
                    }
                }
                Toast.show(options.codec == .hevc && used == .h264 ? String(localized: "Vídeo exportado en H.264: este Mac no admite HEVC")
                                                                  : String(localized: "Vídeo exportado"), symbol: "checkmark.circle")
                NSWorkspace.shared.activateFileViewerSelecting([dest])
            } catch VideoExportError.cancelled {
                Toast.show(String(localized: "Exportación cancelada"), symbol: "xmark.circle")
            } catch {
                Toast.show(error.localizedDescription, symbol: "exclamationmark.triangle")
            }
            exportTask = nil
            exportPhase = nil
            showExportSheet = false
        }
    }

    func cancelExport() { exportTask?.cancel() }
    var isExporting: Bool { exportTask != nil }
}
