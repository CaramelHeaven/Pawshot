import Foundation
import Observation

/// What is happening right now, for the parts of the UI that only reflect it: the menu bar icon.
/// Nothing here survives a relaunch — that is `Settings`.
@MainActor
@Observable
final class AppState {
    static let shared = AppState()

    /// From the hotkey until the region is picked or the capture is cancelled.
    var isCapturing = false

    /// A recording in progress: what the pill and the menu bar show. `nil` when nothing records.
    var recording: RecordingStatus?

    struct RecordingStatus: Equatable {
        var elapsed: TimeInterval
        var isPaused: Bool

        /// `0:42`, `12:05`, `1:02:05` — the way a stopwatch reads.
        var elapsedText: String {
            let total = Int(elapsed)
            let hours = total / 3600
            let minutes = (total % 3600) / 60
            let seconds = total % 60
            return hours > 0
                ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
                : String(format: "%d:%02d", minutes, seconds)
        }
    }

    /// True for a moment after ⌘D put text on the clipboard: the window is already gone, and the
    /// dot on the paw is the only sign the text arrived.
    private(set) var textJustCopied = false

    @ObservationIgnored private var textCopiedReset: Task<Void, Never>?

    func flashTextCopied() {
        textJustCopied = true
        textCopiedReset?.cancel()
        textCopiedReset = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            self?.textJustCopied = false
        }
    }
}
