import AVFoundation
import os

/// How much of the microphone the echo test keeps: a plain counter, so the cut is a test.
struct EchoBuffer: Equatable {
    let capacity: Int
    private(set) var frames = 0

    /// `seconds` of sound at `sampleRate`.
    init(seconds: Double, sampleRate: Double) {
        capacity = Int((seconds * sampleRate).rounded())
    }

    var isFull: Bool {
        frames >= capacity
    }

    /// How many of `incoming` frames still fit — all of them, or the few that fill it — and
    /// counts them in.
    mutating func take(_ incoming: Int) -> Int {
        let kept = max(0, min(incoming, capacity - frames))
        frames += kept
        return kept
    }
}

/// The microphone check on the recording overlay: three seconds of talking, then the same three
/// seconds played back. Enough to hear at once whether it is the right microphone and whether it
/// hisses. Listening and playing never overlap — the speakers would feed the microphone.
///
/// Like the level meter it runs only with access already granted; the overlay never asks for it.
/// Both engines live on the class's own queue.
final class MicrophoneEcho: @unchecked Sendable {
    enum Phase: Equatable {
        case idle
        case listening
        case playing
    }

    static let seconds = 3.0

    private static var logger: Logger {
        .pawshot("recording")
    }

    private let queue = DispatchQueue(label: "com.caramelheaven.pawshot.mic-echo")
    private let deviceUID: String?
    private let onPhase: @MainActor @Sendable (Phase) -> Void

    /// Touched only on `queue`.
    private var listener: AVAudioEngine?
    private var player: AVAudioEngine?
    /// Bumped by every start and cancel, so a timer of an earlier run does nothing.
    private var run = 0

    /// Watches the listener for a device plugged in or out: the engine stops by itself then.
    private var configurationObserver: NSObjectProtocol?

    /// Filled on the audio thread, into a buffer made once before listening starts: nothing is
    /// allocated there.
    private let lock = NSLock()
    private var recorded: AVAudioPCMBuffer?
    private var buffer = EchoBuffer(seconds: MicrophoneEcho.seconds, sampleRate: 48000)

    init(deviceUID: String?, onPhase: @escaping @MainActor @Sendable (Phase) -> Void) {
        self.deviceUID = deviceUID
        self.onPhase = onPhase
    }

    func start() {
        queue.async { self.listen() }
    }

    /// Stops whatever is going on. Safe when nothing is.
    func cancel() {
        queue.async {
            self.run += 1
            let wasBusy = self.listener != nil || self.player != nil
            self.tearDown()
            if wasBusy {
                Self.logger.notice("mic echo cancelled")
            }
            self.notify(.idle)
        }
    }

    // MARK: - Listening

    private func listen() {
        guard listener == nil, player == nil else {
            Self.logger.notice("mic echo not started: one is already running")
            return
        }
        run += 1
        let thisRun = run

        let engine = AVAudioEngine()
        let input = engine.inputNode
        if let deviceUID, let deviceID = MicrophoneDevices.audioDeviceID(forUID: deviceUID) {
            do {
                try input.auAudioUnit.setDeviceID(deviceID)
            } catch {
                Self.logger.error("mic echo: the picked microphone was not taken (\(String(describing: error), privacy: .public)): using the default")
            }
        }
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            Self.logger.error("mic echo: no input device (0 Hz format)")
            notify(.idle)
            return
        }
        // The copy below is channel by channel over 32-bit floats — what an input tap hands out.
        // Anything else is refused rather than read past its end.
        guard format.commonFormat == .pcmFormatFloat32, !format.isInterleaved else {
            Self.logger.error("mic echo: the input's format is not separate float channels (\(format.commonFormat.rawValue, privacy: .public), interleaved \(format.isInterleaved, privacy: .public)): not checked")
            notify(.idle)
            return
        }
        let counter = EchoBuffer(seconds: Self.seconds, sampleRate: format.sampleRate)
        guard let storage = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(counter.capacity)) else {
            Self.logger.error("mic echo: no room for \(counter.capacity, privacy: .public) frames")
            notify(.idle)
            return
        }
        lock.withLock {
            recorded = storage
            buffer = counter
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] incoming, _ in
            self?.keep(incoming)
        }
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            Self.logger.error("mic echo: listening did not start: \(String(describing: error), privacy: .public)")
            notify(.idle)
            return
        }
        listener = engine
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            queue.async {
                guard self.run == thisRun, self.listener != nil else { return }
                Self.logger.error("mic echo: the microphone changed while listening: stopped")
                self.run += 1
                self.tearDown()
                self.notify(.idle)
            }
        }
        let rate = Int(format.sampleRate)
        let channels = Int(format.channelCount)
        Self.logger.notice("mic echo: listening for \(Int(Self.seconds), privacy: .public) s (\(rate, privacy: .public) Hz, \(channels, privacy: .public) ch)")
        notify(.listening)

        queue.asyncAfter(deadline: .now() + Self.seconds) { [weak self] in
            guard let self, run == thisRun else { return }
            play()
        }
    }

    /// Runs on the audio thread: a copy of what came in, because the buffer handed to a tap is
    /// reused. Appended to the one buffer made before listening.
    private func keep(_ incoming: AVAudioPCMBuffer) {
        lock.withLock {
            guard let recorded, let from = incoming.floatChannelData, let to = recorded.floatChannelData,
                  incoming.format.channelCount == recorded.format.channelCount
            else { return }
            let offset = buffer.frames
            let count = buffer.take(Int(incoming.frameLength))
            guard count > 0 else { return }
            for channel in 0 ..< Int(recorded.format.channelCount) {
                (to[channel] + offset).update(from: from[channel], count: count)
            }
            recorded.frameLength = AVAudioFrameCount(offset + count)
        }
    }

    // MARK: - Playing back

    private func play() {
        listener?.inputNode.removeTap(onBus: 0)
        listener?.stop()
        listener = nil

        removeConfigurationObserver()
        let heard = lock.withLock { () -> AVAudioPCMBuffer? in
            defer { recorded = nil }
            return recorded
        }
        let frames = Int(heard?.frameLength ?? 0)
        guard let heard, frames > 0 else {
            Self.logger.error("mic echo: nothing was heard to play back")
            notify(.idle)
            return
        }
        let format = heard.format

        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
        } catch {
            Self.logger.error("mic echo: playback did not start: \(String(describing: error), privacy: .public)")
            notify(.idle)
            return
        }
        player = engine

        let thisRun = run
        node.scheduleBuffer(heard, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            self?.queue.async { self?.finishPlayback(run: thisRun) }
        }
        node.play()
        Self.logger.notice("mic echo: playing back \(frames, privacy: .public) frames")
        notify(.playing)
    }

    /// The last chunk has been heard. A run that was cancelled meanwhile has nothing to finish.
    private func finishPlayback(run finished: Int) {
        guard run == finished else { return }
        tearDown()
        Self.logger.notice("mic echo: played back")
        notify(.idle)
    }

    private func tearDown() {
        removeConfigurationObserver()
        if let listener {
            listener.inputNode.removeTap(onBus: 0)
            listener.stop()
        }
        listener = nil
        player?.stop()
        player = nil
        lock.withLock { recorded = nil }
    }

    private func removeConfigurationObserver() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        configurationObserver = nil
    }

    private func notify(_ phase: Phase) {
        let onPhase = onPhase
        Task { @MainActor in onPhase(phase) }
    }
}
