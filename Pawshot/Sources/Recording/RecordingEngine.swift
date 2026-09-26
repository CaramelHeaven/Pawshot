import AVFoundation
import CoreMedia
import os
import ScreenCaptureKit

enum RecordingError: LocalizedError {
    case writerFailed(Error?)
    case noFrames
    case displayNotFound
    case windowNotFound

    var errorDescription: String? {
        switch self {
        case let .writerFailed(error): String(localized: "The recording couldn't be written. \(error?.localizedDescription ?? "")")
        case .noFrames: String(localized: "Nothing was recorded — the stream stopped before the first frame.")
        case .displayNotFound: String(localized: "The display to record is no longer connected.")
        case .windowNotFound: String(localized: "The window to record has closed.")
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
    }

    private static let logger = Logger(subsystem: "com.caramelheaven.pawshot", category: "recording")

    let outputURL: URL
    private let queue = DispatchQueue(label: "com.caramelheaven.pawshot.recording", qos: .userInitiated)
    private var stream: SCStream?
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let systemAudioInput: AVAssetWriterInput?
    private let microphoneInput: AVAssetWriterInput?

    private var clock = RecordingClock()
    private var lastFrame: CMSampleBuffer?
    private var lastFrameTime: CMTime = .zero
    private var isFinishing = false

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

        let stream = SCStream(filter: filter, configuration: streamConfiguration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if configuration.capturesSystemAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        }
        if configuration.capturesMicrophone {
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
        }
        self.stream = stream
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
        try await stream?.startCapture()
    }

    func pause() {
        queue.async { self.clock.pause(at: Self.now) }
    }

    func resume() {
        queue.async { self.clock.resume(at: Self.now) }
    }

    /// Seconds in the file so far, pauses excluded.
    var duration: TimeInterval {
        queue.sync { clock.duration(at: Self.now).seconds }
    }

    var isPaused: Bool {
        queue.sync { clock.isPaused }
    }

    /// Ends the recording and returns the finished file.
    func stop() async throws -> URL {
        try? await stream?.stopCapture()

        let hasFrames = await withCheckedContinuation { continuation in
            queue.async {
                self.isFinishing = true
                self.extendLastFrame(to: self.clock.duration(at: Self.now))
                self.videoInput.markAsFinished()
                self.systemAudioInput?.markAsFinished()
                self.microphoneInput?.markAsFinished()
                continuation.resume(returning: self.clock.origin != nil)
            }
        }

        guard hasFrames else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: outputURL)
            throw RecordingError.noFrames
        }

        await writer.finishWriting()
        guard writer.status == .completed else {
            throw RecordingError.writerFailed(writer.error)
        }
        return outputURL
    }

    /// Throws the take away: stops, and deletes whatever was written.
    func cancel() async {
        try? await stream?.stopCapture()
        await withCheckedContinuation { continuation in
            queue.async {
                self.isFinishing = true
                continuation.resume()
            }
        }
        writer.cancelWriting()
        try? FileManager.default.removeItem(at: outputURL)
    }

    // MARK: - Samples

    func stream(_: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !isFinishing, sampleBuffer.isValid else { return }

        switch type {
        case .screen:
            // ScreenCaptureKit also delivers "nothing changed" and "blank" frames; only complete
            // frames carry a picture.
            guard Self.isCompleteFrame(sampleBuffer),
                  let time = clock.outputTime(for: sampleBuffer.presentationTimeStamp, isVideo: true),
                  let retimed = sampleBuffer.retimed(to: time)
            else { return }
            if videoInput.isReadyForMoreMediaData {
                videoInput.append(retimed)
            }
            lastFrame = sampleBuffer
            lastFrameTime = time

        case .audio:
            append(sampleBuffer, to: systemAudioInput)

        case .microphone:
            append(sampleBuffer, to: microphoneInput)

        @unknown default:
            break
        }
    }

    private func append(_ sampleBuffer: CMSampleBuffer, to input: AVAssetWriterInput?) {
        guard
            let input,
            let time = clock.outputTime(for: sampleBuffer.presentationTimeStamp, isVideo: false),
            let retimed = sampleBuffer.retimed(to: time),
            input.isReadyForMoreMediaData
        else { return }
        input.append(retimed)
    }

    /// ScreenCaptureKit sends a frame only when something on screen changes. A recording that ends
    /// on a still screen would otherwise stop at the last change and lose its tail against the
    /// sound — so the last picture is repeated at the moment the recording stops.
    private func extendLastFrame(to end: CMTime) {
        guard
            let lastFrame,
            end > lastFrameTime + CMTime(value: 1, timescale: 60),
            let repeated = lastFrame.retimed(to: end),
            videoInput.isReadyForMoreMediaData
        else { return }
        videoInput.append(repeated)
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
