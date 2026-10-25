import AVFoundation
import NativeShotKit

extension Library {
    /// Moves a finished recording from recovery/ into the library (atomic rename, same volume) and indexes it.
    func addVideo(id: UUID, from temp: URL, info: MovieInfo) async throws -> URL {
        let rel = "originals/\(id.uuidString)/source.mp4"
        let keep = UserDefaults.standard.bool(forKey: Prefs.keepHistory)
        // Without history a recording still has to land somewhere the user can find it: the save folder.
        let dest = keep ? root.appendingPathComponent(rel)
            : FileNamingPolicy.uniqueURL(in: Prefs.saveFolderURL,
                                         name: FileNamingPolicy.default.name(date: Date(), type: "recording", ext: "mp4"))
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: temp, to: dest)
        if keep, let store {
            try await store.insert(StoredArtifact(id: id, type: .video, width: info.width, height: info.height,
                                                  format: "mp4", originalPath: rel, byteSize: info.byteSize))
            await Self.writePoster(of: dest, to: Thumbnails.url(for: id, root: root))
            await refresh()
        }
        return dest
    }

    /// Library thumbnail of a recording: a frame one second in (or the first one for very short clips).
    static func writePoster(of video: URL, to thumb: URL) async {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: video))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: Thumbnails.maxPixel, height: Thumbnails.maxPixel)
        let oneSecond = CMTime(seconds: 1, preferredTimescale: 600)
        var img = try? await gen.image(at: oneSecond).image
        if img == nil { img = try? await gen.image(at: .zero).image } // clips shorter than a second
        guard let img else { return }
        try? Thumbnails.write(img, to: thumb)
    }
}
