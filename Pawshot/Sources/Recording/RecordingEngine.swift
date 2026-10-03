import AVFoundation
import CoreMedia
import os
import ScreenCaptureKit

enum RecordingError: LocalizedError {
    case writerFailed(Error?)
    case noFrames
    case displayNotFound
    case windowNotFound
    case notRunning

    var errorDescription: String? {
        switch self {
        case let .writerFailed(error): String(localized: "The recording couldn't be written. \(error?.localizedDescription ?? "")")
        case .noFrames: String(localized: "Nothing was recorded — the stream stopped before the first frame.")
        case .displayNotFound: String(localized: "The display to record is no longer connected.")
        case .windowNotFound: String(localized: "The window to record has closed.")
        case .notRunning: String(localized: "The recording isn't running.")
        }
    }
}

/// One recording: a ScreenCaptureKit stream feeding an `AVAssetWriter`.
///
/// Not `SCRecordingOutput`: that one can't pause, can't take anything drawn on top, and Apple has
/// confirmed it writes broken files once the microphone is on (forum thread 805892). Here the
/// samples arrive on one serial queue, get their timestamps rewritten by `RecordingClock`, and go
/// into a `.mov` with HEVC video and separate AAC tracks for the system audio and the microphone.
///
/// The file is written in fragments every 5 seconds, so a crash or a stream that dies on its own
/// (another thing Apple's forums report) costs at most the last few seconds, not the take.
///
/// Every mutable property is touched only on `queue`, which is what makes `@unchecked Sendable`
/// true rather than hopeful.
final class RecordingEngine: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    struct Configuration: Sendable {
        /// The part of the display to record, in the display's own points, origin top left.
        /// `nil` records the whole display — or the whole window, for a window filter.
        var sourceRect: CGRect?
        var pixelWidth: Int
        var pixelHeight: Int
        var framesPerSecond = 60
        var capturesSystemAudio: Bool
        var capturesMicrophone: Bool
        /// The microphone to record, by its unique id; `nil` takes the system's default.
        var microphoneDeviceID: String?
    }

    private static var logger: Logger {
        .pawshot("recording")
    }

    let outputURL: URL
    private let queue = DispatchQueue(label: "com.caramelheaven.pawshot.recording", qos: .userInitiated)
    private var stream: SCStream?
    /// Kept to change `sourceRect` on a running stream (`moveSource`).
    private var streamConfiguration: SCStreamConfiguration?
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let systemAudioInput: AVAssetWriterInput?
    private let microphoneInput: AVAssetWriterInput?

    private var clock = RecordingClock()
    private var microphoneIsMuted = false
    private var mutedBuffersDropped = 0
    private var lastFrame: CMSampleBuffer?
    private var lastFrameTime: CMTime = .zero
    private var isFinishing = false
    /// For the stop line in the log; on `queue`, like the rest.
    private var framesWritten = 0
    private var framesDropped = 0
    private var audioDropped = 0
    private var appendFailures = 0
    /// A sample whose timing couldn't be copied: dropped, counted for the take's summary.
    private var retimeFailures = 0
    /// Samples the clock had no place for — inside a pause, or before the first frame.
    private var samplesOutsideClock = 0
    /// What happened to the last frame at stop, for the summary.
    private var lastFrameRepeat = "not asked"

    /// Told when the system ends the stream on its own: a display unplugged, access revoked.
    var onUnexpectedStop: (@MainActor @Sendable (Error) -> Void)?

    /// Not for the main thread: creating the writer and the stream there trips AVFoundation's
    /// "may lead to UI unresponsiveness" check. `RecordingController.makeEngine` calls it off it.
    init(filter: SCContentFilter, configuration: Configuration, outputURL: URL) throws {
        self.outputURL = outputURL

        writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        writer.movieFragmentInterval = CMTime(seconds: 5, preferredTimescale: 600)

        let fps = configuration.framesPerSecond
        let pixels = Double(configuration.pixelWidth * configuration.pixelHeight)
        // About 0.12 bit per pixel per frame: crisp text on screen content, within the hardware
        // encoder's comfort zone from a small region up to a 5K display.
        let bitRate = min(80_000_000, max(4_000_000, pixels * Double(fps) * 0.12))
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: configuration.pixelWidth,
            AVVideoHeightKey: configuration.pixelHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitRate,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps * 2,
            ],
        ])
        videoInput.expectsMediaDataInRealTime = true
        writer.add(videoInput)

        systemAudioInput = configuration.capturesSystemAudio ? Self.audioInput(channels: 2) : nil
        microphoneInput = configuration.capturesMicrophone ? Self.audioInput(channels: 1) : nil
        for input in [systemAudioInput, microphoneInput].compactMap(\.self) {
            writer.add(input)
        }

        super.init()

        let streamConfiguration = SCStreamConfiguration()
        streamConfiguration.width = configuration.pixelWidth
        streamConfiguration.height = configuration.pixelHeight
        if let sourceRect = configuration.sourceRect {
            streamConfiguration.sourceRect = sourceRect
        }
        streamConfiguration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        streamConfiguration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        streamConfiguration.queueDepth = 6
        streamConfiguration.showsCursor = true
        streamConfiguration.capturesAudio = configuration.capturesSystemAudio
        streamConfiguration.excludesCurrentProcessAudio = true
        streamConfiguration.sampleRate = 48000
        streamConfiguration.channelCount = 2
        streamConfiguration.captureMicrophone = configuration.capturesMicrophone
        if configuration.capturesMicrophone, let device = configuration.microphoneDeviceID {
            streamConfiguration.microphoneCaptureDeviceID = device
        }

        let stream = SCStream(filter: filter, configuration: streamConfiguration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if configuration.capturesSystemAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        }
        if configuration.capturesMicrophone {
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
        }
        self.stream = stream
        self.streamConfiguration = streamConfiguration
    }

    private static func audioInput(channels: Int) -> AVAssetWriterInput {
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: channels == 1 ? 96000 : 160_000,
        ])
        input.expectsMediaDataInRealTime = true
        return input
    }

    // MARK: - Control

    func start() async throws {
        guard writer.startWriting() else {
            throw RecordingError.writerFailed(writer.error)
        }
        // Samples are retimed to start at zero, so the session starts there too.
        writer.startSession(atSourceTime: .zero)
        let started = Date()
        try await stream?.startCapture()
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        Self.logger.notice("stream started in \(elapsed, privacy: .public) ms")
    }

    func pause() {
        queue.async { self.clock.pause(at: Self.now) }
    }

    /// Points the running stream at another part of the display, same size — the region moved
    /// while the take is paused. `rect` is in the display's own points, origin top left, like
    /// `Configuration.sourceRect`. Throws what ScreenCaptureKit says when it won't have it; the
    /// stream then still shows the old part.
    ///
    /// Whether ScreenCaptureKit takes a new `sourceRect` on a live stream is not something the
    /// agent could try; this is the one call to find out with, and the caller logs the answer.
    func moveSource(to rect: CGRect) async throws {
        // Not a silent success: the caller would move everything else for a stream that didn't.
        guard let stream, let configuration = streamConfiguration else { throw RecordingError.notRunning }
        let previous = configuration.sourceRect
        configuration.sourceRect = rect
        do {
            try await stream.updateConfiguration(configuration)
        } catch {
            configuration.sourceRect = previous
            throw error
        }
    }

    /// The microphone's track goes silent — a cough, a word to someone in the room — and comes
    /// back. The track keeps its length: silence is written, not a gap.
    func setMicrophoneMuted(_ muted: Bool) {
        queue.async { self.microphoneIsMuted = muted }
    }

    var recordsMicrophone: Bool {
        microphoneInput != nil
    }

    /// Turns a buffer of PCM into silence in place. `false` when its bytes can't be written —
    /// then the buffer is left out rather than let through.
    static func silence(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let data = CMSampleBufferGetDataBuffer(sampleBuffer) else { return false }
        let length = CMBlockBufferGetDataLength(data)
        return CMBlockBufferFillDataBytes(with: 0, blockBuffer: data, offsetIntoDestination: 0, dataLength: length)
            == kCMBlockBufferNoErr
    }

    func resume() {
        queue.async { self.clock.resume(at: Self.now) }
    }

    /// The picture being recorded right now, as it goes into the file — for a frame copied out
    /// of a take. `nil` before the first frame has arrived.
    func snapshot() async -> CGImage? {
        // Only the reference is taken on the queue the frames arrive on; turning a 5K frame into
        // a picture there would hold them up, and they would be missing from the video.
        let frame: FrameBox? = await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.lastFrame?.imageBuffer.map(FrameBox.init))
            }
        }
        guard let frame else { return nil }
        let image = CIImage(cvPixelBuffer: frame.buffer)
        return Self.snapshotContext.createCGImage(image, from: image.extent)
    }

    /// A frame's pixels handed out of the queue. The buffer is retained and never written again:
    /// the stream hands out a fresh one for every frame.
    private struct FrameBox: @unchecked Sendable {
        let buffer: CVPixelBuffer
    }

    private static let snapshotContext = CIContext()

    /// Seconds in the file so far, pauses excluded.
    var duration: TimeInterval {
        queue.sync { clock.duration(at: Self.now).seconds }
    }

    var isPaused: Bool {
        queue.sync { clock.isPaused }
    }

    /// Seconds in the file so far, or `nil` while paused — one hop onto the sample queue where
    /// `isPaused` and `duration` take two. The cursor and the ticker ask many times a second.
    var durationIfRunning: TimeInterval? {
        queue.sync { clock.isPaused ? nil : clock.duration(at: Self.now).seconds }
    }

    /// Both at once, in one hop: what the ticker shows.
    var status: (duration: TimeInterval, isPaused: Bool) {
        queue.sync { (clock.duration(at: Self.now).seconds, clock.isPaused) }
    }

    /// Ends the recording and returns the finished file.
    func stop() async throws -> URL {
        await stopCapture()

        let (hasFrames, counts): (Bool, String) = await withCheckedContinuation { continuation in
            queue.async {
                self.isFinishing = true
                self.extendLastFrame(to: self.clock.duration(at: Self.now))
                self.videoInput.markAsFinished()
                self.systemAudioInput?.markAsFinished()
                self.microphoneInput?.markAsFinished()
                let counts = "\(self.framesWritten) frames written, \(self.framesDropped) dropped (writer busy), \(self.audioDropped) audio dropped, \(self.mutedBuffersDropped) muted buffers left out, append failures \(self.appendFailures), retime failures \(self.retimeFailures), samples outside the clock \(self.samplesOutsideClock) (\(self.clock.dropsDescription)), last frame at stop: \(self.lastFrameRepeat)"
                continuation.resume(returning: (self.clock.origin != nil, counts))
            }
        }

        guard hasFrames else {
            Self.logger.error("recording stopped with no frames: \(counts, privacy: .public)")
            writer.cancelWriting()
            removeOutput()
            throw RecordingError.noFrames
        }

        await writer.finishWriting()
        let status = Self.describe(writer.status)
        Self.logger.notice("recording stopped: \(counts, privacy: .public), writer status \(status, privacy: .public)")
        guard writer.status == .completed else {
            throw RecordingError.writerFailed(writer.error)
        }
        return outputURL
    }

    /// Throws the take away: stops, and deletes whatever was written.
    func cancel() async {
        await stopCapture()
        await withCheckedContinuation { continuation in
            queue.async {
                self.isFinishing = true
                continuation.resume()
            }
        }
        writer.cancelWriting()
        removeOutput()
    }

    private func stopCapture() async {
        do {
            try await stream?.stopCapture()
        } catch {
            Self.logger.error("stream stop failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func removeOutput() {
        do {
            try FileManager.default.removeItem(at: outputURL)
        } catch CocoaError.fileNoSuchFile {
            // `cancelWriting` already took it.
        } catch {
            Self.logger.error("recording file not removed: \(String(describing: error), privacy: .public)")
        }
    }

    private static func describe(_ status: AVAssetWriter.Status) -> String {
        switch status {
        case .unknown: "unknown"
        case .writing: "writing"
        case .completed: "completed"
        case .failed: "failed"
        case .cancelled: "cancelled"
        @unknown default: "\(status.rawValue)"
        }
    }

    // MARK: - Samples

    func stream(_: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !isFinishing, sampleBuffer.isValid else { return }

        switch type {
        case .screen:
            // ScreenCaptureKit also delivers "nothing changed" and "blank" frames; only complete
            // frames carry a picture.
            guard Self.isCompleteFrame(sampleBuffer) else { return }
            guard let time = clock.outputTime(for: sampleBuffer.presentationTimeStamp, isVideo: true) else {
                samplesOutsideClock += 1
                return
            }
            guard let retimed = sampleBuffer.retimed(to: time) else {
                retimeFailures += 1
                return
            }
            if !videoInput.isReadyForMoreMediaData {
                framesDropped += 1
            } else if videoInput.append(retimed) {
                framesWritten += 1
            } else {
                appendFailures += 1
            }
            lastFrame = sampleBuffer
            lastFrameTime = time

        case .audio:
            append(sampleBuffer, to: systemAudioInput)

        case .microphone:
            if microphoneIsMuted, !Self.silence(sampleBuffer) {
                // Bytes that can't be zeroed are not written at all: a gap, but never the cough.
                mutedBuffersDropped += 1
                return
            }
            append(sampleBuffer, to: microphoneInput)

        @unknown default:
            break
        }
    }

    private func append(_ sampleBuffer: CMSampleBuffer, to input: AVAssetWriterInput?) {
        guard let input else { return }
        guard let time = clock.outputTime(for: sampleBuffer.presentationTimeStamp, isVideo: false) else {
            samplesOutsideClock += 1
            return
        }
        guard let retimed = sampleBuffer.retimed(to: time) else {
            retimeFailures += 1
            return
        }
        guard input.isReadyForMoreMediaData else {
            audioDropped += 1
            return
        }
        if !input.append(retimed) {
            appendFailures += 1
        }
    }

    /// ScreenCaptureKit sends a frame only when something on screen changes. A recording that ends
    /// on a still screen would otherwise stop at the last change and lose its tail against the
    /// sound — so the last picture is repeated at the moment the recording stops.
    private func extendLastFrame(to end: CMTime) {
        guard let lastFrame else {
            lastFrameRepeat = "no frame to repeat"
            return
        }
        guard end > lastFrameTime + CMTime(value: 1, timescale: 60) else {
            lastFrameRepeat = "not needed"
            return
        }
        guard let repeated = lastFrame.retimed(to: end) else {
            lastFrameRepeat = "FAILED: couldn't retime the last frame"
            return
        }
        guard videoInput.isReadyForMoreMediaData else {
            lastFrameRepeat = "FAILED: writer busy"
            return
        }
        lastFrameRepeat = videoInput.append(repeated) ? "repeated" : "FAILED: append refused"
    }

    private static func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]],
            let rawStatus = attachments.first?[.status] as? Int,
            let status = SCFrameStatus(rawValue: rawStatus)
        else { return false }
        return status == .complete
    }

    private static var now: CMTime {
        CMClockGetTime(CMClockGetHostTimeClock())
    }

    // MARK: - SCStreamDelegate

    func stream(_: SCStream, didStopWithError error: Error) {
        // The error comes over XPC from replayd and has been seen to be freed under us; take its
        // description now rather than holding on to it (forum thread 775307).
        let description = error.localizedDescription
        Self.logger.error("stream stopped on its own: \(description, privacy: .public)")
        let stopped = RecordingError.writerFailed(NSError(
            domain: "Pawshot.Recording",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: description]
        ))
        let handler = onUnexpectedStop
        Task { @MainActor in handler?(stopped) }
    }
}

private extension CMSampleBuffer {
    /// A copy whose first sample lands at `time`, every later sample in the buffer shifted by the
    /// same amount — an audio buffer carries many samples, and their spacing has to survive.
    func retimed(to time: CMTime) -> CMSampleBuffer? {
        let shift = time - presentationTimeStamp
        guard var timings = try? sampleTimingInfos() else { return nil }
        for index in timings.indices {
            timings[index].presentationTimeStamp = timings[index].presentationTimeStamp + shift
            if timings[index].decodeTimeStamp.isValid {
                timings[index].decodeTimeStamp = timings[index].decodeTimeStamp + shift
            }
        }
        return try? CMSampleBuffer(copying: self, withNewTiming: timings)
    }
}
