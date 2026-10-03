import CoreMedia
import os

/// Turns the timestamps ScreenCaptureKit stamps on samples into the timestamps of the file.
///
/// The file starts at the first video frame: audio that arrives earlier is dropped, or the
/// picture would start late against the sound. A pause drops everything in between, and the time
/// it lasted is taken out of every later sample, so the file has no hole where the pause was.
///
/// Pure arithmetic on `CMTime`, kept apart from the stream and the writer so it can be tested.
struct RecordingClock {
    /// The source time of the first video frame; nothing is written before it.
    private(set) var origin: CMTime?
    private var pausedSince: CMTime?
    /// When the last pause ended. A sample stamped before it was captured during the pause, or
    /// before it, and only delivered late.
    private var resumedAt: CMTime?
    private(set) var pausedTotal: CMTime = .zero

    var isPaused: Bool {
        pausedSince != nil
    }

    mutating func pause(at time: CMTime) {
        guard let since = pausedSince else {
            pausedSince = time
            return
        }
        Self.logger.error("clock: pause at \(Self.seconds(time), privacy: .public) s while already paused since \(Self.seconds(since), privacy: .public) s, kept the first")
    }

    mutating func resume(at time: CMTime) {
        guard let since = pausedSince else {
            Self.logger.error("clock: resume at \(Self.seconds(time), privacy: .public) s with no pause, ignored")
            return
        }
        if time < since {
            Self.logger.error("clock: resume at \(Self.seconds(time), privacy: .public) s is before the pause at \(Self.seconds(since), privacy: .public) s")
        }
        pausedTotal = pausedTotal + (time - since)
        pausedSince = nil
        resumedAt = time
        let total = pausedTotal
        Self.logger.notice("clock: resumed after \(Self.seconds(time - since), privacy: .public) s paused, \(Self.seconds(total), privacy: .public) s in all")
    }

    /// Samples left out, by why — counted, never logged one by one: they arrive dozens a second.
    /// `dropsDescription` is the line for the take's summary.
    private(set) var droppedInvalid = 0
    private(set) var droppedBeforeStart = 0
    private(set) var droppedPaused = 0
    private(set) var droppedLate = 0
    private(set) var droppedBeforeOrigin = 0

    var dropsDescription: String {
        "\(droppedInvalid) invalid, \(droppedBeforeStart) before the first frame, \(droppedPaused) paused, \(droppedLate) captured before the resume, \(droppedBeforeOrigin) before the origin"
    }

    /// The time a sample gets in the file, or `nil` when it must not be written: before the first
    /// frame, during a pause, or — for a sample that arrived late — captured before the pause
    /// ended. Such a sample would be stamped inside the stretch already written, and a time going
    /// backwards can fail the writer and with it the whole take.
    mutating func outputTime(for source: CMTime, isVideo: Bool) -> CMTime? {
        guard source.isValid else {
            droppedInvalid += 1
            return nil
        }

        if origin == nil {
            guard isVideo, !isPaused else {
                droppedBeforeStart += 1
                return nil
            }
            origin = source
        }
        guard let origin, !isPaused else {
            droppedPaused += 1
            return nil
        }
        if let resumedAt, source < resumedAt {
            droppedLate += 1
            return nil
        }

        let output = source - origin - pausedTotal
        guard output >= .zero else {
            droppedBeforeOrigin += 1
            return nil
        }
        return output
    }

    /// How long the file is at `now`: the time since the first frame, pauses excluded.
    func duration(at now: CMTime) -> CMTime {
        guard let origin else { return .zero }
        let end = pausedSince ?? now
        let elapsed = end - origin - pausedTotal
        return elapsed >= .zero ? elapsed : .zero
    }

    private static func seconds(_ time: CMTime) -> String {
        String(format: "%.3f", time.seconds)
    }

    private static var logger: Logger {
        .pawshot("recording")
    }
}
