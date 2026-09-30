import AppKit
import AVFoundation
import Carbon.HIToolbox
import CoreImage
@testable import Pawshot
import XCTest

/// What a key held during a take does to the video: a spotlight around the cursor, a stretch
/// hidden under a blur, the microphone silent — and the word the pill has for someone talking
/// into a microphone that is off.
final class HeldEffectsTests: XCTestCase {
    private let videoSize = CGSize(width: 800, height: 600)

    // MARK: - The timeline

    func testHeldStretchesSurviveTheFileAndOlderFilesHaveNone() throws {
        var timeline = EventTimeline()
        timeline.spotlights = [EventTimeline.Span(start: 1, end: 4)]
        timeline.blurs = [EventTimeline.Span(start: 6, end: 9)]
        let decoded = try JSONDecoder().decode(EventTimeline.self, from: JSONEncoder().encode(timeline))
        XCTAssertEqual(decoded, timeline)

        let old = try JSONDecoder().decode(EventTimeline.self, from: Data(#"{"clicks":[]}"#.utf8))
        XCTAssertTrue(old.spotlights.isEmpty)
        XCTAssertTrue(old.blurs.isEmpty)
    }

    func testAHeldStretchIsSomethingToDraw() {
        var timeline = EventTimeline()
        timeline.blurs = [EventTimeline.Span(start: 6, end: 9)]
        XCTAssertFalse(timeline.isEmpty)
        XCTAssertFalse(EffectsOptions().isEmpty(for: timeline))
        XCTAssertTrue(EffectsOptions(blurs: false).isEmpty(for: timeline), "switched off in the editor, the stretch is plain again")

        timeline = EventTimeline()
        timeline.spotlights = [EventTimeline.Span(start: 1, end: 4)]
        XCTAssertFalse(EffectsOptions().isEmpty(for: timeline))
        XCTAssertTrue(EffectsOptions(spotlights: false).isEmpty(for: timeline))
    }

    // MARK: - Where the cursor went

    func testTheCursorPathIsSampledInSteps() {
        var timeline = EventTimeline()
        timeline.cursor = [.init(time: 0, x: 0.1, y: 0.1), .init(time: 1.05, x: 0.9, y: 0.5)]

        let path = EffectsPlanner.cursorPath(from: 1, to: 2, timeline: timeline, step: 0.1, fallback: .zero)
        XCTAssertEqual(path.first?.point, CGPoint(x: 0.1, y: 0.1))
        XCTAssertEqual(path[1].point, CGPoint(x: 0.9, y: 0.5))
        XCTAssertEqual(try XCTUnwrap(path.last?.time), 2, accuracy: 0.001)
        XCTAssertEqual(path.count, 11)
    }

    func testWithNoCursorRecordedThePathStaysAtTheFallback() {
        let path = EffectsPlanner.cursorPath(
            from: 1, to: 2, timeline: EventTimeline(), step: 0.5, fallback: CGPoint(x: 0.5, y: 0.5)
        )
        XCTAssertEqual(Set(path.map(\.point.x)), [0.5])
    }

    // MARK: - The layer tree

    private func build(_ timeline: EventTimeline, keep: KeepRanges = KeepRanges(duration: 30)) throws -> CALayer {
        let video = CALayer()
        _ = EffectsLayerBuilder.build(
            timeline: timeline, options: EffectsOptions(), videoSize: videoSize, keep: keep, videoLayer: video
        )
        return try XCTUnwrap(video.superlayer)
    }

    /// The spotlight is a dark sheet with a hole that travels with the cursor, and it sits over
    /// the video but under the click rings.
    func testASpotlightIsADimSheetWithAHoleThatFollowsTheCursor() throws {
        var timeline = EventTimeline()
        timeline.cursor = [.init(time: 0, x: 0.25, y: 0.25), .init(time: 3, x: 0.75, y: 0.5)]
        timeline.spotlights = [EventTimeline.Span(start: 2, end: 5)]
        timeline.clicks = [.init(time: 2.5, x: 0.5, y: 0.5)]

        let content = try build(timeline)
        let sheets = try XCTUnwrap(content.sublayers?.compactMap { $0 as? CAShapeLayer }.filter { $0.animation(forKey: "spotlight") != nil })
        XCTAssertEqual(sheets.count, 1)
        let sheet = sheets[0]
        XCTAssertEqual(sheet.bounds.size, CGSize(width: 1600, height: 1200), "twice the video, so it covers it wherever the hole goes")
        XCTAssertEqual(sheet.fillRule, .evenOdd)

        let group = try XCTUnwrap(sheet.animation(forKey: "spotlight") as? CAAnimationGroup)
        XCTAssertEqual(group.beginTime, 2)
        XCTAssertEqual(group.duration, 3, accuracy: 0.001)
        let move = try XCTUnwrap(group.animations?.compactMap { $0 as? CAKeyframeAnimation }.first { $0.keyPath == "position" })
        let points = try XCTUnwrap(move.values as? [NSValue]).map(\.pointValue)
        // Layer coordinates count from the bottom: y 0.25 from the top is 450 of 600.
        XCTAssertEqual(points.first, CGPoint(x: 200, y: 450))
        XCTAssertEqual(points.last, CGPoint(x: 600, y: 300))

        let order = try XCTUnwrap(content.sublayers)
        let sheetIndex = try XCTUnwrap(order.firstIndex { $0 === sheet })
        let ringIndex = try XCTUnwrap(order.firstIndex { $0.animation(forKey: "click") != nil })
        XCTAssertLessThan(sheetIndex, ringIndex, "a click inside the spotlight still shows its ring")
    }

    /// A stretch is hidden from a moment before its start to a moment after its end: the way in
    /// and the way out lie outside it, so nothing of the stretch itself is ever half sharp.
    func testAHiddenStretchIsBlurredFromEdgeToEdge() throws {
        var timeline = EventTimeline()
        timeline.blurs = [EventTimeline.Span(start: 6, end: 9)]

        let content = try build(timeline)
        let filters = try XCTUnwrap(content.filters as? [CIFilter])
        XCTAssertEqual(filters.last?.name, "hide")

        let key = try XCTUnwrap(content.animationKeys()?.first { $0.hasPrefix("blur-") })
        let blur = try XCTUnwrap(content.animation(forKey: key) as? CAKeyframeAnimation)
        XCTAssertEqual(blur.keyPath, "filters.hide.inputRadius")
        XCTAssertEqual(blur.beginTime, 6 - EffectsPlanner.effectFade, accuracy: 0.001)
        XCTAssertEqual(blur.duration, 3 + 2 * EffectsPlanner.effectFade, accuracy: 0.001)
        let radii = try XCTUnwrap(blur.values as? [NSNumber]).map(\.doubleValue)
        XCTAssertEqual(radii, [0, 20, 20, 0], "a fortieth of the longer side")
        let full = try XCTUnwrap(blur.keyTimes?[1].doubleValue) * blur.duration
        XCTAssertEqual(full, EffectsPlanner.effectFade, accuracy: 0.001, "fully hidden by the time the stretch begins")
    }

    func testAPlainTakeGetsNoFilter() throws {
        var timeline = EventTimeline()
        timeline.clicks = [.init(time: 1, x: 0.5, y: 0.5)]
        XCTAssertNil(try build(timeline).filters, "a filter costs every frame; a take with nothing hidden doesn't pay for it")
    }

    // MARK: - The microphone

    /// Speech, not a key press: half a second of voice in a row, give or take the gaps between
    /// words, is talking. A click of the keyboard is a twentieth of that.
    func testTalkingIsToldFromTyping() {
        var speech = SpeechWatch()
        var heard = false
        for step in 0 ..< 40 where !heard {
            // Words with short gaps: four steps loud, one quiet.
            heard = speech.feed(level: step % 5 == 4 ? 0.1 : 0.7, at: Double(step) * 0.025)
        }
        XCTAssertTrue(heard)

        var typing = SpeechWatch()
        var fired = false
        for step in 0 ..< 400 {
            // A keystroke every quarter of a second, one step long.
            fired = fired || typing.feed(level: step % 10 == 0 ? 0.8 : 0.05, at: Double(step) * 0.025)
        }
        XCTAssertFalse(fired)
    }

    func testTalkingIsSaidOnce() {
        var speech = SpeechWatch()
        var times = 0
        for step in 0 ..< 400 where speech.feed(level: 0.7, at: Double(step) * 0.025) {
            times += 1
        }
        XCTAssertEqual(times, 1)
    }

    /// A muted stretch keeps its place in the track: the samples are there, and they are zeros.
    func testAMutedBufferIsSilenceOfTheSameLength() throws {
        var description = AudioStreamBasicDescription(
            mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1,
            mBitsPerChannel: 16, mReserved: 0
        )
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: &description, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format
        )
        let samples = [Int16](repeating: 1234, count: 480)
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: 960, blockAllocator: nil,
            customBlockSource: nil, offsetToData: 0, dataLength: 960, flags: 0, blockBufferOut: &block
        )
        let data = try XCTUnwrap(block)
        samples.withUnsafeBytes { bytes in
            _ = CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: data, offsetIntoDestination: 0, dataLength: 960)
        }
        var buffer: CMSampleBuffer?
        try CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: data, formatDescription: XCTUnwrap(format), sampleCount: 480,
            presentationTimeStamp: .zero, packetDescriptions: nil, sampleBufferOut: &buffer
        )
        let sampleBuffer = try XCTUnwrap(buffer)

        XCTAssertTrue(RecordingEngine.silence(sampleBuffer))

        XCTAssertEqual(CMSampleBufferGetNumSamples(sampleBuffer), 480)
        var read = [Int16](repeating: 7, count: 480)
        read.withUnsafeMutableBytes { bytes in
            _ = CMBlockBufferCopyDataBytes(data, atOffset: 0, dataLength: 960, destination: bytes.baseAddress!)
        }
        XCTAssertEqual(Set(read), [0])
    }

    // MARK: - The keys

    /// ⌃⌘ and a key under the left hand: the right one is on the mouse, and ⌃⌘ is the pair the
    /// fewest apps use. The owner asked for something easier than the ⇧⌘ digits.
    func testTheHeldKeysSitUnderTheLeftHand() {
        XCTAssertEqual(HotKeyBinding.spotlightDefault.displayString, "⌃⌘A")
        XCTAssertEqual(HotKeyBinding.blurDefault.displayString, "⌃⌘B")
        XCTAssertEqual(HotKeyBinding.muteDefault.displayString, "⌃⌘V")
        XCTAssertEqual(HotKeyBinding.badTakeDefault.displayString, "⌃⌘X")
    }
}

/// The pixels of a real export: a tree that builds without an error can still draw nothing.
final class HeldEffectsRenderTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("pawshot-held-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    private func frame(of url: URL, at seconds: Double) async throws -> NSBitmapImageRep {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let (image, _) = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
        return NSBitmapImageRep(cgImage: image)
    }

    private func brightness(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> CGFloat {
        let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
        return ((color?.redComponent ?? -3) + (color?.greenComponent ?? 0) + (color?.blueComponent ?? 0)) / 3
    }

    /// Black and white stripes eight pixels wide: sharp, every pixel is one or the other; hidden,
    /// they melt into grey — to the very edge of the frame, with no dark rim around it.
    func testTheExportHidesAStretchAndOnlyThatStretch() async throws {
        let source = try await SyntheticVideo.write(to: folder.appendingPathComponent("in.mov"), audioTracks: 0, stripes: true)
        var timeline = EventTimeline()
        timeline.blurs = [EventTimeline.Span(start: 0.8, end: 1.4)]
        let out = folder.appendingPathComponent("out.mp4")

        try await VideoExporter.export(
            source: source, keep: KeepRanges(duration: 2), preset: .original, to: out,
            timeline: timeline, effects: EffectsOptions()
        ) { _ in }

        let sharp = try await frame(of: out, at: 0.3)
        let hidden = try await frame(of: out, at: 1.1)
        // The middles of a white, a black, a black, a white and a white stripe.
        let points = [(60, 120), (100, 60), (163, 120), (204, 180), (250, 90)]
        let before = points.map { brightness(sharp, $0.0, $0.1) }
        XCTAssertLessThan(try XCTUnwrap(before.min()), 0.15, "outside the stretch black is black: \(before)")
        XCTAssertGreaterThan(try XCTUnwrap(before.max()), 0.85, "and white is white: \(before)")

        let during = points.map { brightness(hidden, $0.0, $0.1) }
        let lowest = try XCTUnwrap(during.min())
        let highest = try XCTUnwrap(during.max())
        XCTAssertLessThan(highest - lowest, 0.1, "inside the stretch the stripes melt into one grey: \(during)")
        XCTAssertTrue(lowest > 0.3 && highest < 0.95, "a grey, not black and not white: \(during)")

        // Blurred with nothing beyond the frame, the last stripe would sink well below the
        // middle of the picture; with the edge carried on outwards it stays level with it.
        let rim = brightness(hidden, 317, 120)
        XCTAssertGreaterThan(rim, lowest - 0.08, "the blur must not darken the edge of the frame: \(rim) against \(during)")
    }

    /// A zone marked before the take is blurred from the first frame to the last, and only it.
    /// Black and white stripes again: sharp, every pixel is one or the other; blurred, grey.
    func testTheExportBlursAMarkedZoneThroughoutAndNothingElse() async throws {
        let source = try await SyntheticVideo.write(to: folder.appendingPathComponent("in.mov"), audioTracks: 0, stripes: true)
        var timeline = EventTimeline()
        timeline.masks = [EventTimeline.Mask(x: 0.55, y: 0, width: 0.45, height: 1)]
        let out = folder.appendingPathComponent("out.mp4")

        try await VideoExporter.export(
            source: source, keep: KeepRanges(duration: 2), preset: .original, to: out,
            timeline: timeline, effects: EffectsOptions()
        ) { _ in }

        for time in [0.0, 1.0] {
            let rep = try await frame(of: out, at: time)
            // Outside the zone: a white and a black stripe, as sharp as the source.
            let sharp = [brightness(rep, 60, 120), brightness(rep, 100, 60)]
            XCTAssertGreaterThan(sharp[0], 0.85, "at \(time) s outside the zone white is white: \(sharp)")
            XCTAssertLessThan(sharp[1], 0.15, "at \(time) s outside the zone black is black: \(sharp)")
            // Inside: a white and a black stripe melt into one grey.
            let inside = [brightness(rep, 204, 180), brightness(rep, 212, 120)]
            XCTAssertLessThan(abs(inside[0] - inside[1]), 0.12, "at \(time) s inside the zone the stripes melt: \(inside)")
        }
    }

    /// The video is one flat colour: with the spotlight on, it stays that colour around the
    /// cursor and is darker everywhere else.
    func testTheExportDimsEverythingButTheCursor() async throws {
        let source = try await SyntheticVideo.write(to: folder.appendingPathComponent("in.mov"), audioTracks: 0)
        var timeline = EventTimeline()
        timeline.cursor = [.init(time: 0, x: 0.25, y: 0.5)]
        timeline.spotlights = [EventTimeline.Span(start: 0.6, end: 1.6)]
        let out = folder.appendingPathComponent("out.mp4")

        try await VideoExporter.export(
            source: source, keep: KeepRanges(duration: 2), preset: .original, to: out,
            timeline: timeline, effects: EffectsOptions()
        ) { _ in }

        let lit = try await frame(of: out, at: 1.1)
        let atCursor = brightness(lit, 80, 120)
        let farAway = brightness(lit, 280, 120)
        XCTAssertGreaterThan(atCursor, farAway * 1.6, "around the cursor \(atCursor), far from it \(farAway)")
        XCTAssertLessThan(atCursor, 0.8, "the picture under the hole is the video's own colour, not a blank frame: \(atCursor)")

        let plain = try await frame(of: out, at: 0.2)
        XCTAssertEqual(brightness(plain, 80, 120), brightness(plain, 280, 120), accuracy: 0.05, "before the key was held nothing is dimmed")
    }
}
