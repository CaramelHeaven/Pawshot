import CoreGraphics
import Foundation

/// A stretch of the video shown zoomed in on one point.
struct ZoomSegment: Equatable {
    var start: Double
    var end: Double
    /// Timeline fraction, origin top left.
    var center: CGPoint
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

    /// One segment per mark, merged where they touch, cut at the end of the video, centred where
    /// the cursor was at the first mark of each.
    static func zoomSegments(timeline: EventTimeline, duration: Double) -> [ZoomSegment] {
        var segments: [ZoomSegment] = []
        for mark in timeline.zoomMarks.sorted() where mark < duration {
            let end = min(duration, mark + zoomLength)
            if let last = segments.last, mark <= last.end + zoomMergeGap {
                segments[segments.count - 1].end = max(last.end, end)
                continue
            }
            let center = timeline.cursorPosition(at: mark) ?? CGPoint(x: 0.5, y: 0.5)
            segments.append(ZoomSegment(start: mark, end: end, center: center))
        }
        return segments
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
