import Foundation

/// What can go wrong with a take that the overlay can already know about, worked out for the line
/// it shows above the toolbar: a microphone that delivers nothing, a shortcut of the take that
/// macOS still holds, a disk with little room. Pure, so the rules are tests; the overlay only
/// gathers the facts and shows the result.
enum RecordingPreflight {
    /// Under this much free space the overlay warns before the take. Not derived from anything:
    /// the rate of a take is unknown until it runs (`RecordingBudget` works it out from the file
    /// as it grows), so this is a round number, a few minutes of a 5K take at its heaviest.
    static let lowDiskBytes: Int64 = 5_000_000_000

    /// One shortcut of ours that macOS takes first.
    struct Taken: Equatable {
        /// What the shortcut does, already in the interface's words.
        let action: String
        let shortcut: String
        /// The system item to untick, as System Settings names it.
        let item: String
    }

    enum Problem: Equatable {
        /// Zones to hide drawn on the region, and a window or the whole screen picked to record:
        /// they would not be hidden — they are counted from a region the take doesn't have.
        case zonesIgnored(Int)
        case microphoneSilent
        case shortcutsTaken([Taken])
        case lowDisk(freeBytes: Int64)

        var message: String {
            switch self {
            case let .zonesIgnored(count):
                String(localized: "Zones to hide work for a region only: \(count) won't be hidden in this take")
            case .microphoneSilent:
                String(localized: "The microphone is on and hears nothing")
            case let .shortcutsTaken(taken):
                if let first = taken.first {
                    String(localized: "macOS takes \(first.shortcut) (\(first.action)): untick “\(first.item)” in Keyboard Shortcuts")
                        + (taken.count > 1 ? String(localized: " and \(taken.count - 1) more") : "")
                } else {
                    ""
                }
            case let .lowDisk(freeBytes):
                String(localized: "Only \(RecordingBudget.sizeText(bytes: freeBytes)) free on the disk")
            }
        }

        /// The same in English and without the words a person would translate: for the log.
        var logDescription: String {
            switch self {
            case let .zonesIgnored(count):
                "\(count) zone(s) to hide ignored outside region mode"
            case .microphoneSilent:
                "microphone on and silent (the meter hears digital silence)"
            case let .shortcutsTaken(taken):
                "shortcuts taken: " + taken.map { "\($0.shortcut) by \($0.item)" }.joined(separator: ", ")
            case let .lowDisk(freeBytes):
                "low disk: \(freeBytes) B free, under \(RecordingPreflight.lowDiskBytes) B"
            }
        }
    }

    /// In the order they are worth reading — what would show what it shouldn't comes first.
    /// `freeBytes` is `nil` when it couldn't be read: no warning then, and whoever read it has
    /// logged why. `ignoredZones` is how many zones a window or whole-screen take would leave out.
    static func problems(
        microphoneIsOn: Bool,
        microphoneIsSilent: Bool,
        taken: [Taken],
        freeBytes: Int64?,
        ignoredZones: Int = 0
    ) -> [Problem] {
        var problems: [Problem] = []
        if ignoredZones > 0 {
            problems.append(.zonesIgnored(ignoredZones))
        }
        if microphoneIsOn, microphoneIsSilent {
            problems.append(.microphoneSilent)
        }
        if !taken.isEmpty {
            problems.append(.shortcutsTaken(taken))
        }
        if let freeBytes, freeBytes < lowDiskBytes {
            problems.append(.lowDisk(freeBytes: freeBytes))
        }
        return problems
    }

    /// Which of the take's shortcuts the system still holds. A cleared one (`nil`) has nothing to
    /// take, and each system item is named once per shortcut it takes.
    static func taken(
        bindings: [(action: String, binding: HotKeyBinding?)],
        by system: SystemScreenshotShortcuts
    ) -> [Taken] {
        bindings.compactMap { entry in
            guard let binding = entry.binding, let item = system.conflict(with: binding) else { return nil }
            return Taken(action: entry.action, shortcut: binding.displayString, item: item.name)
        }
    }
}
