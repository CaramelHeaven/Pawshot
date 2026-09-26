import AVFoundation
import os

/// Decides when a microphone has gone dead: nothing at all for 1.5 seconds.
///
/// "Nothing" means digital silence, not a quiet room — a working microphone in a silent room still
/// hears itself at around −60…−70 dBFS, while a muted or vanished one delivers zeros. The
/// threshold sits far below any real room, so a pause in speech is never mistaken for a dead mic.
struct SignalWatch {
    static let silenceThreshold: Float = 0.000_01
    static let patience: TimeInterval = 1.5

    private var lastSignal: TimeInterval?

    /// Feeds one level (RMS, 0…1) taken at `time` (seconds). Returns whether the microphone reads
    /// as dead now.
    mutating func feed(_ rms: Float, at time: TimeInterval) -> Bool {
        if lastSignal == nil || rms > Self.silenceThreshold {
            lastSignal = time
        }
        return time - (lastSignal ?? time) >= Self.patience
    }

    /// Level for a meter, 0…1: −50 dBFS and below reads as empty, 0 dBFS as full.
    static func meterLevel(rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let decibels = 20 * log10(rms)
        return min(1, max(0, (decibels + 50) / 50))
    }
}

/// The live microphone level on the recording overlay, so a dead mic shows before the take and
/// not after it.
///
/// Runs only while the overlay is up, the microphone is on and access is already granted — it
/// never triggers the permission prompt. `AVAudioEngine` is created and started on its own queue,
/// the same reason the recording engine stays off the main thread.
final class MicrophoneLevelMeter: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.caramelheaven.pawshot", category: "recording")

    private let queue = DispatchQueue(label: "com.caramelheaven.pawshot.level-meter")
    /// Touched only on `queue`.
    private var engine: AVAudioEngine?
    /// Fed from the audio thread, hence the lock rather than the queue.
    private let watch = OSAllocatedUnfairLock(initialState: SignalWatch())
    private let started = Date()

    /// Called on the main actor with the meter level (0…1) and whether the mic reads as dead.
    private let onLevel: @MainActor @Sendable (Float, Bool) -> Void

    init(onLevel: @escaping @MainActor @Sendable (Float, Bool) -> Void) {
        self.onLevel = onLevel
    }

    func start() {
        queue.async { self.startOnQueue() }
    }

    func stop() {
        queue.async {
            self.engine?.inputNode.removeTap(onBus: 0)
            self.engine?.stop()
            self.engine = nil
        }
    }

    private func startOnQueue() {
        guard engine == nil else { return }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)

        // No input device at all: installing a tap on a zero-rate format crashes, and "dead" is
        // exactly the right thing to show.
        guard format.sampleRate > 0, format.channelCount > 0 else {
            report(level: 0, dead: true)
            return
        }

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.report(rms: Self.rms(of: buffer))
        }
        do {
            try engine.start()
            self.engine = engine
        } catch {
            Self.logger.error("level meter not started: \(error.localizedDescription, privacy: .public)")
            input.removeTap(onBus: 0)
            report(level: 0, dead: true)
        }
    }

    /// Runs on the audio thread, once per buffer.
    private func report(rms: Float) {
        let time = Date().timeIntervalSince(started)
        let dead = watch.withLock { $0.feed(rms, at: time) }
        report(level: SignalWatch.meterLevel(rms: rms), dead: dead)
    }

    private func report(level: Float, dead: Bool) {
        let onLevel = onLevel
        Task { @MainActor in onLevel(level, dead) }
    }

    private static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for index in 0 ..< Int(buffer.frameLength) {
            sum += channel[index] * channel[index]
        }
        return (sum / Float(buffer.frameLength)).squareRoot()
    }
}
