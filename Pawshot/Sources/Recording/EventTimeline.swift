import AppKit
import Carbon.HIToolbox
import os

/// What happened during a recording, for the effects added at export and for the editor: where
/// the cursor was, the clicks, the shortcuts pressed, the zooms — marked with a tap or held — and
/// the stretches marked as a bad take.
///
/// Times are seconds of the file — pauses already taken out. Positions are fractions of the
/// recorded area, 0…1, origin top left, so they survive any output size.
///
/// The file has no version. What is added later is read as empty when it is missing
/// (`init(from:)` below): a synthesized decoder would refuse the whole file for one absent key,
/// and a recording made by an older build would lose its clicks to a newer one.
struct EventTimeline: Codable, Equatable {
    struct Point: Codable, Equatable {
        var time: Double
        var x: Double
        var y: Double
    }

    struct Keystroke: Codable, Equatable {
        var time: Double
        var label: String
    }

    /// A zone hidden in the video, as fractions of the recorded area: 0…1, origin top left, like
    /// the cursor. Drawn before the take it has no start and no end — hidden from the first frame
    /// to the last. A region moved on a pause closes it at that moment and opens it again from
    /// there, counted from the new region, so it stays over the same part of the screen.
    struct Mask: Codable, Equatable {
        var x: Double
        var y: Double
        var width: Double
        var height: Double
        /// Seconds of the file; `nil` — from the first frame, to the last.
        var start: Double?
        var end: Double?
    }

    /// From one moment of the file to another.
    struct Span: Codable, Equatable {
        var start: Double
        var end: Double
    }

    var cursor: [Point] = []
    var clicks: [Point] = []
    var keys: [Keystroke] = []
    /// A tap of the zoom key: the export zooms in there for `EffectsPlanner.zoomLength`.
    var zoomMarks: [Double] = []
    /// The zoom key held: zoomed in from the press to the release, following the cursor.
    var zoomHolds: [Span] = []
    /// Stretches marked as a bad take while recording: the editor opens with them cut out.
    var badTakes: [Span] = []
    /// The spotlight key held: everything but a circle around the cursor is dimmed.
    var spotlights: [Span] = []
    /// The blur key held: the whole picture is hidden — a password being typed.
    var blurs: [Span] = []
    /// Zones blurred from the first frame to the last: a tab bar, a mailbox, a token.
    var masks: [Mask] = []

    private static var logger: Logger {
        .pawshot("recording")
    }

    var isEmpty: Bool {
        clicks.isEmpty && keys.isEmpty && !hasZooms && spotlights.isEmpty && blurs.isEmpty && masks.isEmpty
    }

    var hasZooms: Bool {
        !zoomMarks.isEmpty || !zoomHolds.isEmpty
    }

    /// What a "bad take" mark at `time` cuts: the `length` seconds before it — not before the
    /// take began, and never back into a stretch already marked, so a second press cuts only
    /// what came after the first. `nil` when that leaves less than a piece can be.
    static func badTake(endingAt time: Double, after earlier: [Span], length: Double = 10) -> Span? {
        let start = max(0, time - length, earlier.map(\.end).max() ?? 0)
        guard time - start >= KeepRanges.minimumLength else { return nil }
        return Span(start: start, end: time)
    }

    /// Where the cursor was at `time`: the last sample at or before it, or the first one.
    func cursorPosition(at time: Double) -> CGPoint? {
        guard !cursor.isEmpty else { return nil }
        // Samples arrive in time order, so the last one not after `time` is found by bisection.
        var low = 0
        var high = cursor.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if cursor[middle].time <= time {
                low = middle
            } else {
                high = middle - 1
            }
        }
        let sample = cursor[low]
        return CGPoint(x: sample.x, y: sample.y)
    }

    /// The timeline lives next to the raw recording and goes away with it.
    static func url(forMovie movie: URL) -> URL {
        movie.deletingPathExtension().appendingPathExtension("events.json")
    }

    func save(nextTo movie: URL) throws {
        try JSONEncoder().encode(self).write(to: Self.url(forMovie: movie), options: .atomic)
    }

    /// What reading the timeline next to a recording came to. A take always writes one, so
    /// "missing" is a failure as much as "unreadable" — told apart only for the log.
    enum Reading: Equatable {
        case read(EventTimeline)
        case missing
        case unreadable
    }

    static func read(nextTo movie: URL) -> Reading {
        let file = url(forMovie: movie)
        guard FileManager.default.fileExists(atPath: file.path) else {
            logger.error("timeline not read: no file next to the recording")
            return .missing
        }
        do {
            let data = try Data(contentsOf: file)
            return try .read(JSONDecoder().decode(EventTimeline.self, from: data))
        } catch {
            logger.error("timeline not read: \(String(describing: error), privacy: .public)")
            return .unreadable
        }
    }
}

extension EventTimeline {
    /// Every array is optional in the file, see the type's comment.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cursor = try container.decodeIfPresent([Point].self, forKey: .cursor) ?? []
        clicks = try container.decodeIfPresent([Point].self, forKey: .clicks) ?? []
        keys = try container.decodeIfPresent([Keystroke].self, forKey: .keys) ?? []
        zoomMarks = try container.decodeIfPresent([Double].self, forKey: .zoomMarks) ?? []
        zoomHolds = try container.decodeIfPresent([Span].self, forKey: .zoomHolds) ?? []
        badTakes = try container.decodeIfPresent([Span].self, forKey: .badTakes) ?? []
        spotlights = try container.decodeIfPresent([Span].self, forKey: .spotlights) ?? []
        blurs = try container.decodeIfPresent([Span].self, forKey: .blurs) ?? []
        masks = try container.decodeIfPresent([Mask].self, forKey: .masks) ?? []
    }
}

extension EventTimeline.Mask {
    init(fractions: CGRect, start: Double? = nil, end: Double? = nil) {
        self.init(x: fractions.minX, y: fractions.minY, width: fractions.width, height: fractions.height, start: start, end: end)
    }

    var fractions: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    /// Hidden from the first frame to the last.
    var isWholeTake: Bool {
        start == nil && end == nil
    }
}

extension EventTimeline {
    /// The region moved on a pause at `time`, from `old` to `new` (global points, origin top left,
    /// the same size): every zone still open stays over the same part of the screen. It is closed
    /// at `time` and opened again from `time` with its place counted from the new region, cut to
    /// it; a zone the new region no longer holds at all is dropped, and counted. Zones closed
    /// before are history and stay as they are.
    static func masks(
        _ masks: [Mask],
        afterMovingFrom old: CGRect,
        to new: CGRect,
        at time: Double
    ) -> (masks: [Mask], dropped: Int) {
        var result: [Mask] = []
        var dropped = 0
        for mask in masks {
            let isOpen = (mask.start ?? 0) <= time && mask.end.map { $0 > time } ?? true
            guard isOpen else {
                result.append(mask)
                continue
            }
            // Hidden where it was until the move — unless it opened at this very moment.
            if (mask.start ?? 0) < time {
                var closed = mask
                closed.end = time
                result.append(closed)
            }
            let onScreen = SelectionGeometry.zone(fromFractions: mask.fractions, in: old)
            if let moved = SelectionGeometry.zoneFractions(of: onScreen, in: new) {
                result.append(Mask(fractions: moved, start: time, end: mask.end))
            } else {
                dropped += 1
            }
        }
        return (result, dropped)
    }
}

/// How a pressed shortcut is written on screen: `⌘⇧4`, `⌥⌘←`.
///
/// Only combinations with ⌘, ⌥ or ⌃ — plain typing stays private and would bury the shortcuts
/// anyway. The letter comes off the physical key, the same as every key in the app.
enum KeystrokeLabel {
    static func label(keyCode: UInt16, flags: NSEvent.ModifierFlags, latin: String?) -> String? {
        let modifiers = flags.intersection([.command, .option, .control, .shift])
        guard !modifiers.intersection([.command, .option, .control]).isEmpty else { return nil }
        guard let key = name(ofKeyCode: keyCode) ?? latin.map({ $0.uppercased() }), !key.isEmpty else { return nil }
        return HotKeyBinding(keyCode: UInt32(keyCode), modifiers: modifiers, label: key).displayString
    }

    private static func name(ofKeyCode keyCode: UInt16) -> String? {
        switch Int(keyCode) {
        case kVK_Return: "↩"
        case kVK_Tab: "⇥"
        case kVK_Space: "Space"
        case kVK_Delete: "⌫"
        case kVK_ForwardDelete: "⌦"
        case kVK_Escape: "⎋"
        case kVK_LeftArrow: "←"
        case kVK_RightArrow: "→"
        case kVK_UpArrow: "↑"
        case kVK_DownArrow: "↓"
        default: nil
        }
    }
}
