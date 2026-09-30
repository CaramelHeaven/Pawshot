import Foundation

/// The two things a take can run out of, worked out for the pill: room on the disk and the time
/// it was meant to fit into. Pure, so the rules are tests.
enum RecordingBudget {
    /// With this much recording left on the disk the pill says so. Five minutes: time to wrap up,
    /// not a reason to panic.
    static let warnsWithSecondsLeft: TimeInterval = 300
    /// The goal's bar turns in the last ten seconds, and stays turned past it.
    static let goalIsCloseWithSecondsLeft: TimeInterval = 10

    /// How long the free space lasts at the rate the file has grown so far. `nil` until there is
    /// something to go by: the file is written in parts, and the first takes a few seconds to land.
    static func secondsLeft(freeBytes: Int64, writtenBytes: Int64, elapsed: TimeInterval) -> TimeInterval? {
        guard writtenBytes > 0, elapsed > 0 else { return nil }
        let bytesPerSecond = Double(writtenBytes) / elapsed
        return Double(max(0, freeBytes)) / bytesPerSecond
    }

    static func isRunningOut(secondsLeft: TimeInterval?) -> Bool {
        secondsLeft.map { $0 < warnsWithSecondsLeft } ?? false
    }

    /// How full the goal's bar is, 0…1, and whether the end is near or passed. `nil` with no goal.
    static func goal(elapsed: TimeInterval, goal: TimeInterval) -> (fraction: Double, isClose: Bool)? {
        guard goal > 0 else { return nil }
        return (min(1, max(0, elapsed / goal)), goal - elapsed <= goalIsCloseWithSecondsLeft)
    }

    /// `38 MB` — the size the system would show for the file.
    static func sizeText(bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
