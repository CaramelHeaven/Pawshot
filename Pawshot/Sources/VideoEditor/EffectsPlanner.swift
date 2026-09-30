import CoreGraphics
import Foundation

/// A stretch of the video shown zoomed in on one point.
struct ZoomSegment: Equatable {
    var start: Double
    var end: Double
    /// Timeline fraction, origin top left.
    var center: CGPoint
    /// The zoom key was held: the zoom goes where the cursor goes instead of staying where it began.
    var follows = false
}

/// A shortcut shown in the capsule at the bottom: `⌘Z ×3`.
struct KeyCaption: Equatable {
    var start: Double
    var end: Double
    var text: String
}

/// Turns the raw timeline into what gets drawn. Pure, so every rule is a test.
enum EffectsPlanner {
    /// How long one mark stays zoomed in, including the way in and out.
    static let zoomLength: Double = 2.5
    /// The way in and the way out, each.
    static let zoomRamp: Double = 0.4
    /// Marks closer than this after a segment ends extend it rather than bouncing out and back in.
    static let zoomMergeGap: Double = 0.5
    static let zoomScale: CGFloat = 2

    /// The same shortcut again within this long counts up instead of showing a new caption.
    static let keyRepeatWindow: Double = 1.0
    /// How long a caption stays after its last press.
    static let keyHold: Double = 1.2

    /// The zoom key held this long is a hold, not a tap: a tap leaves a mark, a hold zooms from
    /// the press to the release.
    static let zoomHoldAfter: TimeInterval = 0.35

    static func isZoomHold(heldFor held: TimeInterval) -> Bool {
        held > zoomHoldAfter
    }

    /// How often a held zoom looks at where the cursor went.
    static let zoomFollowStep: Double = 0.1

    /// One segment per mark and per hold, merged where they touch, cut at the end of the video,
    /// centred where the cursor was at the start of each. A mark lasts `zoomLength`; a hold lasts
    /// until its release, and the way out comes after that.
    static func zoomSegments(timeline: EventTimeline, duration: Double) -> [ZoomSegment] {
        let marks = timeline.zoomMarks.map { (start: $0, end: $0 + zoomLength, follows: false) }
        let holds = timeline.zoomHolds.map { (start: $0.start, end: $0.end + zoomRamp, follows: true) }

        var segments: [ZoomSegment] = []
        for zoom in (marks + holds).sorted(by: { $0.start < $1.start }) where zoom.start < duration {
            let end = min(duration, zoom.end)
            if let last = segments.last, zoom.start <= last.end + zoomMergeGap {
                segments[segments.count - 1].end = max(last.end, end)
                segments[segments.count - 1].follows = last.follows || zoom.follows
                continue
            }
            let center = timeline.cursorPosition(at: zoom.start) ?? CGPoint(x: 0.5, y: 0.5)
            segments.append(ZoomSegment(start: zoom.start, end: end, center: center, follows: zoom.follows))
        }
        return segments
    }

    /// Where a segment's zoom is centred between two moments of the recording, as steps in time:
    /// the one place it began for a marked zoom, the cursor's place every `zoomFollowStep` for a
    /// held one.
    static func zoomPath(
        of segment: ZoomSegment,
        from start: Double,
        to end: Double,
        timeline: EventTimeline
    ) -> [(time: Double, center: CGPoint)] {
        guard segment.follows, end > start else {
            return [(start, segment.center), (max(start, end), segment.center)]
        }
        var path: [(time: Double, center: CGPoint)] = []
        var time = start
        while time < end {
            path.append((time, timeline.cursorPosition(at: time) ?? segment.center))
            time += zoomFollowStep
        }
        path.append((end, timeline.cursorPosition(at: end) ?? segment.center))
        return path
    }

    /// Captions for the shortcuts. A repeat within a second becomes `×2`, `×3` on the same
    /// caption; a different shortcut ends the previous caption when it starts.
    static func keyCaptions(timeline: EventTimeline) -> [KeyCaption] {
        var captions: [KeyCaption] = []
        var label = ""
        var count = 0
        var lastPress = -Double.infinity

        for key in timeline.keys.sorted(by: { $0.time < $1.time }) {
            if key.label == label, key.time - lastPress <= keyRepeatWindow, !captions.isEmpty {
                count += 1
                captions[captions.count - 1].text = "\(label) ×\(count)"
                captions[captions.count - 1].end = key.time + keyHold
            } else {
                if !captions.isEmpty {
                    captions[captions.count - 1].end = min(captions[captions.count - 1].end, key.time)
                }
                label = key.label
                count = 1
                captions.append(KeyCaption(start: key.time, end: key.time + keyHold, text: key.label))
            }
            lastPress = key.time
        }
        return captions
    }
}
