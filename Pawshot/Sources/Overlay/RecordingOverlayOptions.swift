import AppKit
import Carbon.HIToolbox

/// What the overlay is picking a region for. A screenshot ends on mouse up; a recording keeps the
/// region alive to be moved, resized and started with ↩.
enum OverlayPurpose {
    case screenshot
    case recording
}

/// The proportions a recording region is held to. A cycles through them.
enum AspectLock: CaseIterable, Equatable {
    case free
    case wide
    case tall
    case square
    case classic

    /// Width over height, or `nil` for a free region.
    var ratio: CGFloat? {
        switch self {
        case .free: nil
        case .wide: 16.0 / 9.0
        case .tall: 9.0 / 16.0
        case .square: 1
        case .classic: 4.0 / 3.0
        }
    }

    var label: String? {
        switch self {
        case .free: nil
        case .wide: "16:9"
        case .tall: "9:16"
        case .square: "1:1"
        case .classic: "4:3"
        }
    }

    var next: AspectLock {
        let all = Self.allCases
        let index = all.firstIndex(of: self) ?? 0
        return all[(index + 1) % all.count]
    }
}

/// A size typed on the overlay: `1920x1080`, applied with ↩.
///
/// Digits, then a separator, then digits. `x`, `×`, `*` and a space all separate — `x` only once
/// digits are there, which is what leaves the X key free to switch 1x/2x the rest of the time.
struct SizeInput: Equatable {
    private(set) var text = ""

    var isEmpty: Bool {
        text.isEmpty
    }

    private var hasSeparator: Bool {
        text.contains("×")
    }

    /// Takes one typed character. Returns `false` for anything that isn't part of a size, so the
    /// key can mean something else.
    mutating func type(_ character: Character) -> Bool {
        if character.isASCII, character.isNumber {
            let side = hasSeparator ? text.split(separator: "×", omittingEmptySubsequences: false).last ?? "" : Substring(text)
            guard side.count < 5 else { return true }
            text.append(character)
            return true
        }

        if ["x", "X", "×", "*", " "].contains(character) {
            guard !text.isEmpty, !hasSeparator else { return false }
            text.append("×")
            return true
        }

        return false
    }

    mutating func deleteBackward() {
        if !text.isEmpty {
            text.removeLast()
        }
    }

    mutating func clear() {
        text = ""
    }

    /// The typed size once both sides are there and neither is zero.
    var size: (width: Int, height: Int)? {
        let sides = text.split(separator: "×", omittingEmptySubsequences: false)
        guard
            sides.count == 2,
            let width = Int(sides[0]), let height = Int(sides[1]),
            width > 0, height > 0
        else { return nil }
        return (width, height)
    }
}

/// The recording overlay's keys, read off the physical key like every letter in the app.
enum RecordingOverlayKey: Equatable {
    case start
    case aspect
    case scale
    case microphone
    case systemAudio

    static func action(for event: NSEvent) -> RecordingOverlayKey? {
        if event.keyCode == UInt16(kVK_Return) || event.keyCode == UInt16(kVK_ANSI_KeypadEnter) {
            return .start
        }
        switch KeyboardLayout.latinCharacter(for: event)?.lowercased() {
        case "r": return .start
        case "a": return .aspect
        case "x": return .scale
        case "m": return .microphone
        case "s": return .systemAudio
        default: return nil
        }
    }
}
