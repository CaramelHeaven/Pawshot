import AVFoundation
import Carbon.HIToolbox
import ImageIO
@testable import Pawshot
import XCTest

final class KeepRangesTests: XCTestCase {
    /// The owner's example: eight seconds, keep 1–2 and 4–5.
    private func example() -> KeepRanges {
        var keep = KeepRanges(duration: 8)
        keep.moveEnd(of: 0, to: 2)
        keep.moveStart(of: 0, to: 1)
        keep.add(from: 4, to: 5)
        return keep
    }

    func testOnePieceEdgesNeverCrossNorLeaveTheRecording() {
        var keep = KeepRanges(duration: 10)
        XCTAssertTrue(keep.isWhole)

        keep.moveStart(of: 0, to: -3)
        XCTAssertEqual(keep.first.start, 0)
        keep.moveEnd(of: 0, to: 42)
        XCTAssertEqual(keep.first.end, 10)

        keep.moveStart(of: 0, to: 9.9)
        XCTAssertEqual(keep.first.start, 10 - KeepRanges.minimumLength, "never closer than the minimum")
        keep.moveEnd(of: 0, to: 0)
        XCTAssertEqual(keep.first.end, 10, "the end can't come below start + minimum")
        XCTAssertFalse(keep.isWhole)
    }

    func testDraggingOverTheGreyKeepsAnotherPiece() {
        let keep = example()
        XCTAssertEqual(keep.pieces, [.init(start: 1, end: 2), .init(start: 4, end: 5)])
        XCTAssertEqual(keep.totalLength, 2)
        XCTAssertEqual(keep.gaps, [.init(start: 0, end: 1), .init(start: 2, end: 4), .init(start: 5, end: 8)])
    }

    /// A new piece stays in the grey it started in, dragged either way; it never swallows a
    /// neighbour, and a nudge too small to be a piece makes none.
    func testNewPieceStopsAtItsGap() {
        var keep = example()
        XCTAssertEqual(keep.add(from: 6, to: 1), 2, "dragged leftwards, stopped at the piece before")
        XCTAssertEqual(keep.pieces.last, .init(start: 5, end: 6))

        XCTAssertNil(keep.add(from: 1.5, to: 3), "a press on a piece is not a new piece")
        XCTAssertNil(keep.add(from: 2.5, to: 2.7), "shorter than the minimum")
    }

    func testEdgesStopAtTheNeighbours() {
        var keep = example()
        keep.moveEnd(of: 0, to: 4.5)
        XCTAssertEqual(keep.pieces[0].end, 4, "up to the next piece, not into it")
        keep.moveStart(of: 1, to: 0)
        XCTAssertEqual(keep.pieces[1].start, 4, "the neighbour can't pass the one before either")
    }

    func testTheLastPieceStays() {
        var keep = example()
        XCTAssertTrue(keep.remove(at: 0))
        XCTAssertFalse(keep.remove(at: 0), "nothing kept is not a recording")
        XCTAssertEqual(keep.pieces, [.init(start: 4, end: 5)])
    }

    /// Where a moment of the recording lands in the spliced file.
    func testTimesMoveAcrossTheCuts() {
        let keep = example()
        XCTAssertNil(keep.outputTime(forSource: 0.5), "cut")
        XCTAssertEqual(keep.outputTime(forSource: 1.5), 0.5)
        XCTAssertNil(keep.outputTime(forSource: 3), "cut")
        XCTAssertEqual(keep.outputTime(forSource: 4.5), 1.5, "the gap before it is taken out")
        XCTAssertNil(keep.outputTime(forSource: 6))
    }

    /// The way back, for the playhead while the splice plays: a time of the file to the moment of
    /// the recording it shows.
    func testFileTimesMapBackToTheRecording() throws {
        let keep = example()
        XCTAssertEqual(keep.sourceTime(forOutput: 0), 1)
        XCTAssertEqual(keep.sourceTime(forOutput: 0.5), 1.5)
        XCTAssertEqual(keep.sourceTime(forOutput: 1), 4, "the seam is the start of the next piece")
        XCTAssertEqual(keep.sourceTime(forOutput: 1.5), 4.5)
        XCTAssertEqual(keep.sourceTime(forOutput: 9), 5, "past the end is the end of the last piece")
        for source in [1.2, 1.9, 4.1, 4.7] {
            XCTAssertEqual(try keep.sourceTime(forOutput: XCTUnwrap(keep.outputTime(forSource: source))), source, accuracy: 1e-9)
        }
    }

    /// Playback jumps the grey: from a gap, or from the very end of a piece, to the next piece.
    func testPlaybackSkipsTheGrey() {
        let keep = example()
        XCTAssertEqual(keep.nextPlayableTime(after: 0.2), 1)
        XCTAssertEqual(keep.nextPlayableTime(after: 1.5), 1.5)
        XCTAssertEqual(keep.nextPlayableTime(after: 2), 4)
        XCTAssertEqual(keep.nextPlayableTime(after: 3), 4)
        XCTAssertNil(keep.nextPlayableTime(after: 5), "past the last piece")
    }

    func testStripFractionsAndTimesAgree() {
        let keep = KeepRanges(duration: 8)
        XCTAssertEqual(keep.fraction(of: 2), 0.25)
        XCTAssertEqual(keep.time(at: 0.75), 6)
        XCTAssertEqual(keep.time(at: 1.4), 8, "past the strip is the end")
    }
}

final class VideoPresetTests: XCTestCase {
    func testPresetsCycle() {
        XCTAssertEqual(VideoPreset.original.next, .fullHD)
        XCTAssertEqual(VideoPreset.fullHD.next, .gif)
        XCTAssertEqual(VideoPreset.gif.next, .original)
    }

    /// 720p means the short side, so a tall 9:16 take stays tall; a small one is never blown up.
    func testGIFSizeShrinksTheShortSideTo720() {
        XCTAssertEqual(VideoPreset.gifPixelSize(for: CGSize(width: 3840, height: 2160)), CGSize(width: 1280, height: 720))
        XCTAssertEqual(VideoPreset.gifPixelSize(for: CGSize(width: 1080, height: 1920)), CGSize(width: 720, height: 1280))
        XCTAssertEqual(VideoPreset.gifPixelSize(for: CGSize(width: 400, height: 300)), CGSize(width: 400, height: 300))
    }

    func testSizeAndTimeTexts() {
        XCTAssertTrue(VideoEditing.approximateSize(4_200_000).hasPrefix("≈ "))
        XCTAssertEqual(VideoEditing.approximateSize(0), "")
        XCTAssertNil(VideoEditing.remainingTime(elapsed: 5, progress: 0.01), "too early to tell")
        XCTAssertEqual(try XCTUnwrap(VideoEditing.remainingTime(elapsed: 10, progress: 0.25)), 30, accuracy: 0.001)
        XCTAssertEqual(VideoEditing.durationText(42.34), "0:42.3")
        XCTAssertEqual(VideoEditing.durationText(125), "2:05.0")
    }

    @MainActor
    func testPresetIsRemembered() throws {
        let suite = "PawshotTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(Settings(defaults: defaults).videoPreset, .original)
        Settings(defaults: defaults).videoPreset = .gif
        XCTAssertEqual(Settings(defaults: defaults).videoPreset, .gif)
    }
}

final class GIFWriterTests: XCTestCase {
    private func frame(red: CGFloat) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 40, height: 30, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(red: red, green: 0.2, blue: 0.4, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        return try XCTUnwrap(context.makeImage())
    }

    func testWritesALoopingAnimation() throws {
        let data = NSMutableData()
        let writer = try XCTUnwrap(GIFWriter(data: data, frameCount: 5))
        for index in 0 ..< 5 {
            try writer.add(frame(red: CGFloat(index) / 5))
        }
        XCTAssertTrue(writer.finish())

        let source = try XCTUnwrap(CGImageSourceCreateWithData(data, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 5)
        let properties = CGImageSourceCopyProperties(source, nil) as? [CFString: Any]
        let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        XCTAssertEqual(gif?[kCGImagePropertyGIFLoopCount] as? Int, 0, "0 means forever")
    }
}

/// Exports of a synthetic video written right here, so the tests need neither the screen nor a
/// fixture file: 2 seconds, 320×240, a colour that changes every frame, and optionally two sound
/// tracks — the shape of a recording with the microphone on.
final class VideoExporterTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("pawshot-video-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testTrimmedOriginalKeepsOnlyTheKeptPart() async throws {
        let source = try await SyntheticVideo.write(to: folder.appendingPathComponent("in.mov"), audioTracks: 1)
        var keep = KeepRanges(duration: 2)
        keep.moveStart(of: 0, to: 0.5)
        keep.moveEnd(of: 0, to: 1.5)
        let out = folder.appendingPathComponent("out.mp4")

        try await VideoExporter.export(source: source, keep: keep, preset: .original, to: out) { _ in }

        let duration = try await AVURLAsset(url: out).load(.duration).seconds
        XCTAssertEqual(duration, 1.0, accuracy: 0.15)
    }

    /// Two kept pieces, 0.2–0.8 and 1.2–1.8, come out as one 1.2-second file — in every format,
    /// and with the two sound tracks still mixed into one.
    func testPiecesAreSplicedEndToEnd() async throws {
        let source = try await SyntheticVideo.write(to: folder.appendingPathComponent("in.mov"), audioTracks: 2)
        var keep = KeepRanges(duration: 2)
        keep.moveEnd(of: 0, to: 0.8)
        keep.moveStart(of: 0, to: 0.2)
        XCTAssertNotNil(keep.add(from: 1.2, to: 1.8))

        for preset in [VideoPreset.original, .fullHD] {
            let out = folder.appendingPathComponent("spliced-\(preset.rawValue).mp4")
            try await VideoExporter.export(source: source, keep: keep, preset: preset, to: out) { _ in }
            let asset = AVURLAsset(url: out)
            let duration = try await asset.load(.duration).seconds
            let audio = try await asset.loadTracks(withMediaType: .audio)
            XCTAssertEqual(duration, 1.2, accuracy: 0.1, "\(preset)")
            XCTAssertEqual(audio.count, 1, "\(preset) keeps the sound mixed into one track")
        }

        let gif = folder.appendingPathComponent("spliced.gif")
        try await VideoExporter.export(source: source, keep: keep, preset: .gif, to: gif) { _ in }
        let image = try XCTUnwrap(CGImageSourceCreateWithURL(gif as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(image), 18, "nine frames from each piece, none from the cut")
    }

    /// The editor plays the export's own splice: as long as the pieces, nothing of the cut.
    @MainActor
    func testPreviewPlaysTheSplice() async throws {
        let source = try await SyntheticVideo.write(to: folder.appendingPathComponent("in.mov"), audioTracks: 2)
        var keep = KeepRanges(duration: 2)
        keep.moveEnd(of: 0, to: 0.8)
        XCTAssertNotNil(keep.add(from: 1.2, to: 1.8))

        let item = try await VideoExporter.previewItem(source: source, keep: keep)
        let duration = try await item.asset.load(.duration).seconds
        XCTAssertEqual(duration, keep.totalLength, accuracy: 0.02)
        XCTAssertEqual(item.audioMix?.inputParameters.count, 2, "both sound tracks are heard")
    }

    /// Two sound tracks — system audio and the microphone — must reach the file as one: most
    /// players only ever play the first track, and the voice would silently be missing.
    func testTwoSoundTracksComeOutMixedIntoOne() async throws {
        let source = try await SyntheticVideo.write(to: folder.appendingPathComponent("in.mov"), audioTracks: 2)
        let sourceTracks = try await AVURLAsset(url: source).loadTracks(withMediaType: .audio)
        XCTAssertEqual(sourceTracks.count, 2)

        for preset in [VideoPreset.original, .fullHD] {
            let out = folder.appendingPathComponent("\(preset.rawValue).mp4")
            try await VideoExporter.export(source: source, keep: KeepRanges(duration: 2), preset: preset, to: out) { _ in }
            let tracks = try await AVURLAsset(url: out).loadTracks(withMediaType: .audio)
            XCTAssertEqual(tracks.count, 1, "\(preset) must mix the sound into one track")
        }
    }

    func testGIFHasFifteenFramesASecond() async throws {
        let source = try await SyntheticVideo.write(to: folder.appendingPathComponent("in.mov"), audioTracks: 0)
        var keep = KeepRanges(duration: 2)
        keep.moveEnd(of: 0, to: 1)
        let out = folder.appendingPathComponent("out.gif")
        let reported = Progress()

        try await VideoExporter.export(source: source, keep: keep, preset: .gif, to: out) { value in
            reported.completedUnitCount = Int64(value * 100)
        }

        let image = try XCTUnwrap(CGImageSourceCreateWithURL(out as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(image), 15)
        XCTAssertEqual(reported.completedUnitCount, 100)
    }

    func testEstimatesAreThere() async throws {
        let source = try await SyntheticVideo.write(to: folder.appendingPathComponent("in.mov"), audioTracks: 1)
        let keep = KeepRanges(duration: 2)

        let mp4 = await VideoExporter.estimatedSize(source: source, keep: keep, preset: .original)
        let gif = await VideoExporter.estimatedSize(source: source, keep: keep, preset: .gif)
        XCTAssertGreaterThan(mp4, 0)
        XCTAssertGreaterThan(gif, 0)
    }
}

enum SyntheticVideo {
    static let size = CGSize(width: 320, height: 240)
    static let fps: Int32 = 30
    static let sampleRate = 44100.0

    static func write(to url: URL, seconds: Int = 2, audioTracks: Int) async throws -> URL {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: nil)
        writer.add(video)

        let audio = (0 ..< audioTracks).map { _ in
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
            ])
            writer.add(input)
            return input
        }

        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let frames = seconds * Int(fps)
        let audioPerFrame = Int(sampleRate) / Int(fps)
        for index in 0 ..< frames {
            let time = CMTime(value: CMTimeValue(index), timescale: fps)
            try waitUntilReady(video)
            try adaptor.append(pixelBuffer(shade: CGFloat(index) / CGFloat(frames)), withPresentationTime: time)
            for (track, input) in audio.enumerated() {
                try waitUntilReady(input)
                let start = CMTime(value: CMTimeValue(index * audioPerFrame), timescale: CMTimeScale(sampleRate))
                try input.append(tone(frames: audioPerFrame, at: start, pitch: 0.03 * Double(track + 1)))
            }
        }

        video.markAsFinished()
        audio.forEach { $0.markAsFinished() }
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? VideoExportError.unsupported }
        return url
    }

    private static func waitUntilReady(_ input: AVAssetWriterInput) throws {
        let deadline = Date().addingTimeInterval(5)
        while !input.isReadyForMoreMediaData {
            guard Date() < deadline else { throw VideoExportError.unsupported }
            usleep(1000)
        }
    }

    private static func pixelBuffer(shade: CGFloat) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA, nil, &buffer)
        guard let buffer else { throw VideoExportError.unsupported }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )
        context?.setFillColor(red: shade, green: 1 - shade, blue: 0.5, alpha: 1)
        context?.fill(CGRect(origin: .zero, size: size))
        return buffer
    }

    private static func tone(frames: Int, at time: CMTime, pitch: Double) throws -> CMSampleBuffer {
        var description = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1,
            mBitsPerChannel: 16, mReserved: 0
        )
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: &description, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format
        )

        let offset = Double(time.value)
        let samples = (0 ..< frames).map { Int16(sin((offset + Double($0)) * pitch) * 6000) }
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: frames * 2, blockAllocator: nil,
            customBlockSource: nil, offsetToData: 0, dataLength: frames * 2, flags: 0, blockBufferOut: &block
        )
        guard let block, let format else { throw VideoExportError.unsupported }
        samples.withUnsafeBytes { bytes in
            _ = CMBlockBufferReplaceDataBytes(
                with: bytes.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: frames * 2
            )
        }

        var sampleBuffer: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: frames,
            presentationTimeStamp: time, packetDescriptions: nil, sampleBufferOut: &sampleBuffer
        )
        guard let sampleBuffer else { throw VideoExportError.unsupported }
        return sampleBuffer
    }
}

@MainActor
final class VideoEditorWindowControllerTests: XCTestCase {
    /// The owner's rule for recordings is the screenshot's: closed without ⌘C or ⌘S, the take is
    /// gone — the raw file must not pile up in the temporary folder either.
    func testClosingWithoutExportThrowsTheRecordingAway() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pawshot-editor-\(UUID().uuidString).mov")
        _ = try await SyntheticVideo.write(to: url, audioTracks: 0)
        let screen = try XCTUnwrap(NSScreen.main)

        try EventTimeline().save(nextTo: url)
        let controller = VideoEditorWindowController(movieURL: url, videoSize: SyntheticVideo.size, on: screen)
        controller.show()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        controller.close()

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: EventTimeline.url(forMovie: url).path), "its timeline goes too")
    }

    /// Every change to the pieces is one step of ⌘Z, back and forward, and ⌫ removes the selected
    /// piece — but never the last one.
    func testPiecesUndoAndDelete() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pawshot-editor-\(UUID().uuidString).mov")
        _ = try await SyntheticVideo.write(to: url, audioTracks: 0)
        let screen = try XCTUnwrap(NSScreen.main)
        let controller = VideoEditorWindowController(movieURL: url, videoSize: SyntheticVideo.size, on: screen)
        defer { controller.close() }
        controller.show()
        for _ in 0 ..< 100 where controller.model.keep.duration == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        let before = controller.model.keep
        XCTAssertGreaterThan(before.duration, 1.5)

        var spliced = before
        spliced.moveEnd(of: 0, to: 0.6)
        spliced.add(from: 1.0, to: 1.6)
        controller.editKeep(spliced)
        controller.commitKeep(before: before)

        controller.piecesUndoManager.undo()
        XCTAssertEqual(controller.model.keep, before)
        controller.piecesUndoManager.redo()
        XCTAssertEqual(controller.model.keep, spliced)

        let delete = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: "\u{7F}", charactersIgnoringModifiers: "\u{7F}", isARepeat: false, keyCode: UInt16(kVK_Delete)
        ))
        controller.model.selectedPiece = 1
        XCTAssertTrue(controller.handleKey(delete))
        XCTAssertEqual(controller.model.keep.pieces.count, 1)
        controller.model.selectedPiece = 0
        XCTAssertFalse(controller.handleKey(delete), "the last piece stays")
        controller.piecesUndoManager.undo()
        XCTAssertEqual(controller.model.keep, spliced, "⌫ is a step of ⌘Z too")
    }

    /// Space plays and P changes the format, P read off the physical key: on ЙЦУКЕН it prints "з".
    func testPresetKeyWorksOnACyrillicLayout() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pawshot-editor-\(UUID().uuidString).mov")
        _ = try await SyntheticVideo.write(to: url, audioTracks: 0)
        let screen = try XCTUnwrap(NSScreen.main)
        let controller = VideoEditorWindowController(movieURL: url, videoSize: SyntheticVideo.size, on: screen)
        let before = controller.model.preset
        defer {
            Settings.shared.videoPreset = before
            controller.close()
        }
        controller.show()

        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: controller.window?.windowNumber ?? 0, context: nil,
            characters: "з", charactersIgnoringModifiers: "з", isARepeat: false, keyCode: UInt16(kVK_ANSI_P)
        ))
        controller.window?.contentView?.keyDown(with: event)

        XCTAssertEqual(controller.model.preset, before.next)
    }
}
