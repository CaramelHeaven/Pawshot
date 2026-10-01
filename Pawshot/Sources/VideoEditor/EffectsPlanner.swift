import CoreGraphics
import Foundation

/// A shortcut shown in the capsule at the bottom: `⌘Z ×3`.
struct KeyCaption: Equatable {
    var start: Double
    var end: Double
    var text: String
}

/// Turns the raw timeline into what gets drawn. Pure, so every rule is a test.
enum EffectsPlanner {
    /// The same shortcut again within this long counts up instead of showing a new caption.
    static let keyRepeatWindow: Double = 1.0
    /// How long a caption stays after its last press.
    static let keyHold: Double = 1.2

    /// The spotlight's hole, as a share of the video's shorter side, and how dark the rest gets.
    static let spotlightRadius: CGFloat = 0.16
    static let spotlightDim: CGFloat = 0.55
    /// The spotlight's hole has to stay on the cursor, so it looks at it every frame of 30.
    static let spotlightStep: Double = 1.0 / 30
    /// The way in and out of a spotlight and of a hidden stretch.
    static let effectFade: Double = 0.15

    /// How strong the blur of a hidden stretch is: a fortieth of the video's longer side, enough
    /// to melt text of any size a screen shows.
    static func blurRadius(for videoSize: CGSize) -> CGFloat {
        max(videoSize.width, videoSize.height) / 40
    }

    /// Hidden stretches in order, with the ones whose ways in and out would overlap joined into
    /// one. Two animations of the same blur that overlap don't add up: the later one wins, and
    /// its way in would thin out the end of the stretch before it. Joined, the gap between them
    /// stays hidden too — more hidden, never less.
    static func joinedStretches(_ stretches: [EventTimeline.Span]) -> [EventTimeline.Span] {
        stretches.sorted { $0.start < $1.start }.reduce(into: []) { joined, next in
            if let last = joined.last, next.start - effectFade <= last.end + effectFade {
                joined[joined.count - 1].end = max(last.end, next.end)
            } else {
                joined.append(next)
            }
        }
    }

    /// Where the cursor was from `start` to `end`, a point every `step` and one at the end;
    /// `fallback` while no cursor was recorded.
    static func cursorPath(
        from start: Double,
        to end: Double,
        timeline: EventTimeline,
        step: Double,
        fallback: CGPoint
    ) -> [(time: Double, point: CGPoint)] {
        let steps = max(1, Int(((end - start) / step - 1e-9).rounded(.up)))
        var path = (0 ..< steps).map { index -> (time: Double, point: CGPoint) in
            let time = start + Double(index) * step
            return (time, timeline.cursorPosition(at: time) ?? fallback)
        }
        path.append((max(start, end), timeline.cursorPosition(at: end) ?? fallback))
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
