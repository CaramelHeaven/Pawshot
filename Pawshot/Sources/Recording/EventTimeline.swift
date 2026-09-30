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

    private static var logger: Logger {
        .pawshot("recording")
    }

    var isEmpty: Bool {
        clicks.isEmpty && keys.isEmpty && !hasZooms
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

    static func load(nextTo movie: URL) -> EventTimeline {
        guard let data = try? Data(contentsOf: url(forMovie: movie)) else { return EventTimeline() }
        do {
            return try JSONDecoder().decode(EventTimeline.self, from: data)
        } catch {
            logger.error("timeline not read: \(String(describing: error), privacy: .public)")
            return EventTimeline()
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
