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

    /// Filled on the audio thread.
    private let lock = NSLock()
    private var kept: [AVAudioPCMBuffer] = []
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

        lock.withLock {
            kept = []
            buffer = EchoBuffer(seconds: Self.seconds, sampleRate: format.sampleRate)
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
    /// reused.
    private func keep(_ incoming: AVAudioPCMBuffer) {
        lock.withLock {
            let count = buffer.take(Int(incoming.frameLength))
            guard count > 0,
                  let copy = AVAudioPCMBuffer(pcmFormat: incoming.format, frameCapacity: AVAudioFrameCount(count)),
                  let from = incoming.floatChannelData, let to = copy.floatChannelData
            else { return }
            copy.frameLength = AVAudioFrameCount(count)
            for channel in 0 ..< Int(incoming.format.channelCount) {
                to[channel].update(from: from[channel], count: count)
            }
            kept.append(copy)
        }
    }

    // MARK: - Playing back

    private func play() {
        listener?.inputNode.removeTap(onBus: 0)
        listener?.stop()
        listener = nil

        let buffers = lock.withLock { kept }
        let frames = buffers.reduce(0) { $0 + Int($1.frameLength) }
        guard let format = buffers.first?.format, frames > 0 else {
            Self.logger.error("mic echo: nothing was heard to play back")
            notify(.idle)
            return
        }

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
        for (index, chunk) in buffers.enumerated() {
            if index == buffers.count - 1 {
                node.scheduleBuffer(chunk, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                    self?.queue.async { self?.finishPlayback(run: thisRun) }
                }
            } else {
                node.scheduleBuffer(chunk)
            }
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
        if let listener {
            listener.inputNode.removeTap(onBus: 0)
            listener.stop()
        }
        listener = nil
        player?.stop()
        player = nil
        lock.withLock { kept = [] }
    }

    private func notify(_ phase: Phase) {
        let onPhase = onPhase
        Task { @MainActor in onPhase(phase) }
    }
}
