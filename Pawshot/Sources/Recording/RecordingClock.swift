import CoreMedia

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
    private(set) var pausedTotal: CMTime = .zero

    var isPaused: Bool {
        pausedSince != nil
    }

    mutating func pause(at time: CMTime) {
        guard pausedSince == nil else { return }
        pausedSince = time
    }

    mutating func resume(at time: CMTime) {
        guard let since = pausedSince else { return }
        pausedTotal = pausedTotal + (time - since)
        pausedSince = nil
    }

    /// The time a sample gets in the file, or `nil` when it must not be written: before the first
    /// frame, during a pause, or — for a frame that arrived late — earlier than the pause ended.
    mutating func outputTime(for source: CMTime, isVideo: Bool) -> CMTime? {
        guard source.isValid else { return nil }

        if origin == nil {
            guard isVideo, !isPaused else { return nil }
            origin = source
        }
        guard let origin, !isPaused else { return nil }

        let output = source - origin - pausedTotal
        return output >= .zero ? output : nil
    }

    /// How long the file is at `now`: the time since the first frame, pauses excluded.
    func duration(at now: CMTime) -> CMTime {
        guard let origin else { return .zero }
        let end = pausedSince ?? now
        let elapsed = end - origin - pausedTotal
        return elapsed >= .zero ? elapsed : .zero
    }
}
