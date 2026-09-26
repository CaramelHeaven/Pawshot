import AppKit
import Carbon.HIToolbox

/// What happened during a recording, for the effects added at export: where the cursor was, the
/// clicks, the shortcuts pressed and the moments marked for a zoom.
///
/// Times are seconds of the file — pauses already taken out. Positions are fractions of the
/// recorded area, 0…1, origin top left, so they survive any output size.
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

    var cursor: [Point] = []
    var clicks: [Point] = []
    var keys: [Keystroke] = []
    var zoomMarks: [Double] = []

    var isEmpty: Bool {
        clicks.isEmpty && keys.isEmpty && zoomMarks.isEmpty
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
        return (try? JSONDecoder().decode(EventTimeline.self, from: data)) ?? EventTimeline()
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
