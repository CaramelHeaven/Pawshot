import CoreGraphics
import CoreMedia
import Foundation

/// The parts of a recording that are kept: the pairs of orange brackets on the film strip.
///
/// A recording starts as one piece from end to end. Dragging over the grey adds another; the
/// pieces go out one after another, butted together, and everything between them is cut. Pure
/// arithmetic in seconds, apart from AVFoundation, so the rules can be tested: pieces stay in
/// order, never overlap, never leave the recording, never get shorter than `minimumLength`, and
/// the last one can't be removed.
struct KeepRanges: Equatable {
    struct Piece: Equatable {
        var start: TimeInterval
        var end: TimeInterval

        var length: TimeInterval {
            end - start
        }
    }

    static let minimumLength: TimeInterval = 0.5

    let duration: TimeInterval
    private(set) var pieces: [Piece]

    init(duration: TimeInterval) {
        self.duration = max(0, duration)
        pieces = [Piece(start: 0, end: self.duration)]
    }

    /// The length of the file that comes out: the pieces, butted together.
    var totalLength: TimeInterval {
        pieces.reduce(0) { $0 + $1.length }
    }

    /// Nothing cut off: the file can go out untouched.
    var isWhole: Bool {
        pieces.count == 1 && pieces[0].start <= 0 && pieces[0].end >= duration
    }

    var first: Piece {
        pieces[0]
    }

    mutating func moveStart(of index: Int, to time: TimeInterval) {
        guard pieces.indices.contains(index) else { return }
        let lower = index > 0 ? pieces[index - 1].end : 0
        let upper = pieces[index].end - Self.minimumLength
        pieces[index].start = min(max(lower, time), max(lower, upper))
    }

    mutating func moveEnd(of index: Int, to time: TimeInterval) {
        guard pieces.indices.contains(index) else { return }
        let lower = pieces[index].start + Self.minimumLength
        let upper = index < pieces.count - 1 ? pieces[index + 1].start : duration
        pieces[index].end = max(min(upper, time), min(upper, lower))
    }

    /// A new piece over the grey between `from` and `to`, in either order. It starts in the gap
    /// `from` is in and stops at that gap's edge — pieces never swallow each other. Returns the
    /// new piece's index, or `nil` when `from` isn't in a gap or the piece would be too short.
    @discardableResult
    mutating func add(from: TimeInterval, to: TimeInterval) -> Int? {
        guard let gap = gap(containing: from) else { return nil }
        let low = max(gap.start, min(from, to))
        let high = min(gap.end, max(from, to))
        guard high - low >= Self.minimumLength else { return nil }

        let index = pieces.firstIndex { $0.start >= high } ?? pieces.count
        pieces.insert(Piece(start: low, end: high), at: index)
        return index
    }

    /// Removes a piece; the last one stays — a recording with nothing kept is not a recording.
    @discardableResult
    mutating func remove(at index: Int) -> Bool {
        guard pieces.count > 1, pieces.indices.contains(index) else { return false }
        pieces.remove(at: index)
        return true
    }

    /// The piece `time` falls in, its end included.
    func piece(containing time: TimeInterval) -> Int? {
        pieces.firstIndex { $0.start <= time && time <= $0.end }
    }

    /// The grey stretch around `time`: between the neighbouring pieces, or the edges of the
    /// recording. `nil` inside a piece.
    func gap(containing time: TimeInterval) -> (start: TimeInterval, end: TimeInterval)? {
        guard time >= 0, time <= duration, piece(containing: time) == nil else { return nil }
        let before = pieces.last { $0.end <= time }?.end ?? 0
        let after = pieces.first { $0.start >= time }?.start ?? duration
        return (before, after)
    }

    /// The grey stretches between and around the pieces — what gets cut.
    var gaps: [Piece] {
        var result: [Piece] = []
        var cursor: TimeInterval = 0
        for piece in pieces {
            if piece.start > cursor {
                result.append(Piece(start: cursor, end: piece.start))
            }
            cursor = piece.end
        }
        if duration > cursor {
            result.append(Piece(start: cursor, end: duration))
        }
        return result
    }

    /// Where playback goes from `time`: `time` itself inside a piece, the start of the next piece
    /// in a gap, `nil` past the last piece.
    func nextPlayableTime(after time: TimeInterval) -> TimeInterval? {
        if let index = piece(containing: time), time < pieces[index].end {
            return time
        }
        return pieces.first { $0.start > time }?.start
    }

    /// The time a moment of the recording lands at in the finished file, or `nil` when it was cut.
    func outputTime(forSource time: TimeInterval) -> TimeInterval? {
        var elapsed: TimeInterval = 0
        for piece in pieces {
            if time < piece.start {
                return nil
            }
            if time < piece.end {
                return elapsed + (time - piece.start)
            }
            elapsed += piece.length
        }
        return nil
    }

    /// The moment of the recording a time of the finished file shows — the way back from
    /// `outputTime(forSource:)`. Past the end it is the end of the last piece.
    func sourceTime(forOutput time: TimeInterval) -> TimeInterval {
        var elapsed: TimeInterval = 0
        for piece in pieces {
            if time < elapsed + piece.length {
                return piece.start + max(0, time - elapsed)
            }
            elapsed += piece.length
        }
        return pieces.last?.end ?? 0
    }

    var timeRanges: [CMTimeRange] {
        pieces.map {
            CMTimeRange(
                start: CMTime(seconds: $0.start, preferredTimescale: 600),
                end: CMTime(seconds: $0.end, preferredTimescale: 600)
            )
        }
    }

    /// Where a time sits along the strip, 0…1.
    func fraction(of time: TimeInterval) -> CGFloat {
        duration > 0 ? CGFloat(time / duration) : 0
    }

    /// The time at a fraction of the strip.
    func time(at fraction: CGFloat) -> TimeInterval {
        duration * TimeInterval(min(max(0, fraction), 1))
    }
}

/// What the video leaves the editor as. P cycles through them, and the choice is remembered.
enum VideoPreset: String, CaseIterable {
    /// The recording as it is — HEVC, the display's resolution.
    case original
    /// H.264 at 1080p at most: plays everywhere, a fraction of the size.
    case fullHD
    /// A looping GIF, 720p at most, 15 frames a second.
    case gif

    var next: VideoPreset {
        let all = Self.allCases
        let index = all.firstIndex(of: self) ?? 0
        return all[(index + 1) % all.count]
    }

    var title: String {
        switch self {
        case .original: "Original · HEVC"
        case .fullHD: "1080p · H.264"
        case .gif: "GIF · 720p"
        }
    }

    var fileExtension: String {
        self == .gif ? "gif" : "mp4"
    }

    static let gifFramesPerSecond = 15
    static let gifShortSide: CGFloat = 720

    /// A GIF's frame size: the short side down to 720 pixels, never up, the proportions kept.
    static func gifPixelSize(for source: CGSize) -> CGSize {
        let shortSide = min(source.width, source.height)
        guard shortSide > 0 else { return .zero }
        let scale = min(1, gifShortSide / shortSide)
        return CGSize(width: (source.width * scale).rounded(), height: (source.height * scale).rounded())
    }
}

enum VideoEditing {
    /// "≈ 4.2 MB" — an estimate, and it says so.
    static func approximateSize(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return "≈ " + formatter.string(fromByteCount: bytes)
    }

    /// Time left from how long it has taken so far, or `nil` before there is anything to go on.
    static func remainingTime(elapsed: TimeInterval, progress: Double) -> TimeInterval? {
        guard progress > 0.02, progress < 1, elapsed > 0.5 else { return nil }
        return elapsed * (1 - progress) / progress
    }

    /// `0:42.3` — a trimmed length is worth its tenths.
    static func durationText(_ seconds: TimeInterval) -> String {
        let tenths = Int((max(0, seconds) * 10).rounded())
        return String(format: "%d:%02d.%d", tenths / 600, (tenths / 10) % 60, tenths % 10)
    }
}
