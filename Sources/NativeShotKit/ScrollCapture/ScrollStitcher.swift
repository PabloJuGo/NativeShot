import Foundation

public enum ScrollAddResult: Equatable, Sendable {
    case first
    /// Frame joined; `rows` new rows were appended.
    case appended(rows: Int, confidence: Double)
    /// Nothing moved (or the document ended): frame ignored.
    case still
    case scrolledBack
    /// Frame NOT joined. The stitched result so far is untouched and still valid.
    case rejected(ScrollRejection)
    /// SCR-006 memory ceiling reached; the frame was not joined.
    case limitReached
}

/// Accumulates scroll frames into height-limited tiles. Only joins it is confident about are applied,
/// so the output is either correct or incomplete, never silently corrupt.
public struct ScrollStitcher: Sendable {
    public let config: ScrollConfig
    /// Horizontal sessions are stitched transposed (columns as rows) and flipped back on output.
    public let axis: ScrollAxis
    private var last: (frame: ScrollFrame, sig: RowSignatures)?
    private var tiles: [(data: [UInt8], rows: Int)] = []
    private var started = false
    /// Row of `last` up to which page content is already stored (may exceed the visible body after scrolling back).
    private var committedEnd = 0
    // shortcut: one footer height from the latest join; if it shrinks mid-session some footer rows may stay in the body. Track per-session max if seen in practice.
    private var bottomBand = 0
    private var bytes = 0
    public private(set) var totalRows = 0
    public private(set) var acceptedFrames = 0
    public private(set) var rejectedFrames = 0

    public init(config: ScrollConfig = ScrollConfig(), axis: ScrollAxis = .vertical) { self.config = config; self.axis = axis }

    private func oriented(_ f: ScrollFrame) -> ScrollFrame { axis == .horizontal ? f.transposed() : f }

    public mutating func add(_ input: ScrollFrame) -> ScrollAddResult {
        let frame = oriented(input)
        guard let prev = last else {
            last = (frame, RowSignatures(frame))
            acceptedFrames = 1
            return .first
        }
        guard frame.width == prev.frame.width, frame.height == prev.frame.height, frame.bytesPerPixel == prev.frame.bytesPerPixel else {
            rejectedFrames += 1
            return .rejected(.sizeMismatch)
        }
        let sig = RowSignatures(frame)
        switch ScrollAligner.align(prev.sig, sig, config) {
        case .identical:
            return .still
        case .rejected(let r):
            rejectedFrames += 1
            return .rejected(r)
        case .scrolledBack(let s, _, _, let bottom):
            committedEnd += s
            bottomBand = bottom
            last = (frame, sig)
            return .scrolledBack
        case .shifted(let s, let confidence, let top, let bottom):
            let h = frame.height
            var added = 0
            if !started {
                let n = h - bottom
                guard fits(n, frame) else { return .limitReached }
                append(prev.frame, rows: 0..<n)
                committedEnd = n
                started = true
                added += n
            }
            let start = max(top, committedEnd - s)
            let end = h - bottom
            // A frame's last rows are often not page content (rounded window corners, fade masks). Re-take the
            // newest committed rows from this frame, where they now sit higher up, so no seam shows at each join.
            // Only when the committed end is visible in this frame (after scrolling back it can lie below it).
            if start == committedEnd - s, start <= end {
                let redo = min(config.edgeRows, start - top, totalRows)
                if redo > 0 { overwriteTail(frame, rows: (start - redo)..<start) }
            }
            if start < end {
                guard fits(end - start, frame) else { return .limitReached }
                append(frame, rows: start..<end)
                committedEnd = end
                added += end - start
            } else {
                committedEnd -= s
            }
            bottomBand = bottom
            last = (frame, sig)
            acceptedFrames += 1
            return .appended(rows: added, confidence: confidence)
        }
    }

    /// Replaces the last `rows.count` stored rows with `rows` of `f`.
    private mutating func overwriteTail(_ f: ScrollFrame, rows: Range<Int>) {
        let rb = f.rowBytes
        var remaining = rows.count, src = rows.upperBound, t = tiles.count - 1
        while remaining > 0, t >= 0 {
            let tailEnd = tiles[t].rows, n = min(remaining, tailEnd)
            tiles[t].data.replaceSubrange(((tailEnd - n) * rb)..<(tailEnd * rb), with: f.data[((src - n) * rb)..<(src * rb)])
            remaining -= n; src -= n; t -= 1
        }
    }

    private func fits(_ rows: Int, _ f: ScrollFrame) -> Bool { bytes + rows * f.rowBytes <= config.maxTotalBytes }

    private mutating func append(_ f: ScrollFrame, rows: Range<Int>) {
        let rb = f.rowBytes
        var r = rows.lowerBound
        while r < rows.upperBound {
            if tiles.isEmpty || tiles[tiles.count - 1].rows >= config.maxSegmentHeight { tiles.append(([], 0)) }
            let t = tiles.count - 1
            let n = min(rows.upperBound - r, config.maxSegmentHeight - tiles[t].rows)
            tiles[t].data.append(contentsOf: f.data[(r * rb)..<((r + n) * rb)])
            tiles[t].rows += n
            r += n
        }
        bytes += rows.count * rb
        totalRows += rows.count
    }

    /// Total rows the final image will have, including the fixed footer.
    public var height: Int { totalRows + (started ? bottomBand : 0) }

    /// The stitched tiles in order, with the sticky footer closing the last one. A single frame comes back as is.
    public func finish() -> [ScrollFrame] { stitched().map(oriented) } // transposing back is its own inverse

    private func stitched() -> [ScrollFrame] {
        guard let last else { return [] }
        guard started else { return [last.frame] }
        let f = last.frame
        var out = tiles.map { ScrollFrame(width: f.width, height: $0.rows, bytesPerPixel: f.bytesPerPixel, data: $0.data) }
        if bottomBand > 0 {
            let rb = f.rowBytes
            let footer = f.data[((f.height - bottomBand) * rb)...]
            let l = out.count - 1
            out[l] = ScrollFrame(width: f.width, height: out[l].height + bottomBand, bytesPerPixel: f.bytesPerPixel, data: out[l].data + footer)
        }
        return out
    }

    /// Last `maxRows` rows (footer included) for the live preview; cheap, copies only that slice.
    public func tail(maxRows: Int) -> ScrollFrame? { rawTail(maxRows: maxRows).map(oriented) }

    private func rawTail(maxRows: Int) -> ScrollFrame? {
        guard maxRows > 0, let f = last?.frame else { return nil } // a zero-height frame would trap
        guard started, let t = tiles.last else { return f }
        let rb = f.rowBytes
        let footer = bottomBand > 0 ? Array(f.data[((f.height - bottomBand) * rb)...]) : []
        let take = max(0, min(t.rows, maxRows - bottomBand))
        let body = t.data[((t.rows - take) * rb)...]
        return ScrollFrame(width: f.width, height: take + bottomBand, bytesPerPixel: f.bytesPerPixel, data: Array(body) + footer)
    }
}
