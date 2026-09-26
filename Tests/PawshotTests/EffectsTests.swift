import AVFoundation
import Carbon.HIToolbox
@testable import Pawshot
import XCTest

final class EventTimelineTests: XCTestCase {
    func testCursorPositionIsTheLastSampleNotAfterTheTime() {
        var timeline = EventTimeline()
        timeline.cursor = [
            .init(time: 0, x: 0.1, y: 0.1),
            .init(time: 1, x: 0.5, y: 0.5),
            .init(time: 2, x: 0.9, y: 0.2),
        ]
        XCTAssertEqual(timeline.cursorPosition(at: 1.5), CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(timeline.cursorPosition(at: 2), CGPoint(x: 0.9, y: 0.2))
        XCTAssertEqual(timeline.cursorPosition(at: 99), CGPoint(x: 0.9, y: 0.2))
        XCTAssertEqual(timeline.cursorPosition(at: -1), CGPoint(x: 0.1, y: 0.1), "before the first: the first")
        XCTAssertNil(EventTimeline().cursorPosition(at: 1))
    }

    func testTimelineTravelsNextToTheMovie() throws {
        let movie = FileManager.default.temporaryDirectory.appendingPathComponent("pawshot-\(UUID().uuidString).mov")
        var timeline = EventTimeline()
        timeline.clicks = [.init(time: 1.5, x: 0.25, y: 0.75)]
        timeline.keys = [.init(time: 2, label: "⌘Z")]
        timeline.zoomMarks = [3]

        try timeline.save(nextTo: movie)
        defer { try? FileManager.default.removeItem(at: EventTimeline.url(forMovie: movie)) }

        XCTAssertEqual(EventTimeline.url(forMovie: movie).lastPathComponent, movie.deletingPathExtension().lastPathComponent + ".events.json")
        XCTAssertEqual(EventTimeline.load(nextTo: movie), timeline)
    }

    func testMissingTimelineIsAnEmptyOne() {
        let movie = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).mov")
        XCTAssertTrue(EventTimeline.load(nextTo: movie).isEmpty)
    }
}

final class KeystrokeLabelTests: XCTestCase {
    func testOnlyShortcutsWithCommandOptionOrControl() {
        XCTAssertEqual(KeystrokeLabel.label(keyCode: UInt16(kVK_ANSI_Z), flags: [.command], latin: "z"), "⌘Z")
        XCTAssertEqual(KeystrokeLabel.label(keyCode: UInt16(kVK_ANSI_4), flags: [.command, .shift], latin: "4"), "⇧⌘4")
        XCTAssertNil(KeystrokeLabel.label(keyCode: UInt16(kVK_ANSI_A), flags: [], latin: "a"), "typing stays private")
        XCTAssertNil(KeystrokeLabel.label(keyCode: UInt16(kVK_ANSI_A), flags: [.shift], latin: "a"), "⇧ alone is typing")
    }

    func testNamedKeysGetTheirSymbols() {
        XCTAssertEqual(KeystrokeLabel.label(keyCode: UInt16(kVK_LeftArrow), flags: [.option, .command], latin: nil), "⌥⌘←")
        XCTAssertEqual(KeystrokeLabel.label(keyCode: UInt16(kVK_Return), flags: [.command], latin: "\r"), "⌘↩")
    }
}

final class EffectsGeometryTests: XCTestCase {
    func testMouseIsStoredAsAFractionFromTheTopLeft() {
        let area = CGRect(x: 100, y: 200, width: 400, height: 300)
        XCTAssertEqual(SelectionGeometry.normalized(mouse: CGPoint(x: 100, y: 500), in: area), CGPoint(x: 0, y: 0))
        XCTAssertEqual(SelectionGeometry.normalized(mouse: CGPoint(x: 300, y: 275), in: area), CGPoint(x: 0.5, y: 0.75))
        XCTAssertNil(SelectionGeometry.normalized(mouse: CGPoint(x: 99, y: 300), in: area), "outside the video")
    }

    func testLayerPointsHaveTheirOriginAtTheBottom() {
        XCTAssertEqual(SelectionGeometry.layerPoint(CGPoint(x: 0.25, y: 0), in: CGSize(width: 400, height: 200)), CGPoint(x: 100, y: 200))
    }

    /// A zoom on a corner must not slide an empty edge into the frame: the centre is pulled in.
    func testZoomNeverShowsBeyondTheEdge() {
        let size = CGSize(width: 400, height: 200)
        XCTAssertEqual(SelectionGeometry.zoomOffset(center: CGPoint(x: 200, y: 100), scale: 2, size: size), .zero)
        let corner = SelectionGeometry.zoomOffset(center: CGPoint(x: 0, y: 0), scale: 2, size: size)
        XCTAssertEqual(corner, CGPoint(x: 200, y: 100), "clamped to the quarter point")
    }
}

final class EffectsPlannerTests: XCTestCase {
    func testZoomMarksBecomeSegmentsThatMergeWhenClose() {
        var timeline = EventTimeline()
        timeline.cursor = [.init(time: 0, x: 0.2, y: 0.3), .init(time: 5, x: 0.8, y: 0.7)]
        timeline.zoomMarks = [1, 3.5, 9, 9.2]

        let segments = EffectsPlanner.zoomSegments(timeline: timeline, duration: 10)

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].start, 1)
        XCTAssertEqual(segments[0].end, 6, "3.5 lands inside 1…3.5+gap: one segment to 3.5+2.5")
        XCTAssertEqual(segments[0].center, CGPoint(x: 0.2, y: 0.3), "centred where the cursor was at the first mark")
        XCTAssertEqual(segments[1].end, 10, "cut at the end of the video")
        XCTAssertEqual(segments[1].center, CGPoint(x: 0.8, y: 0.7))
    }

    func testRepeatedShortcutCountsUp() {
        var timeline = EventTimeline()
        timeline.keys = [
            .init(time: 1, label: "⌘Z"), .init(time: 1.4, label: "⌘Z"), .init(time: 1.9, label: "⌘Z"),
            .init(time: 2.3, label: "⌘S"),
            .init(time: 5, label: "⌘S"),
        ]

        let captions = EffectsPlanner.keyCaptions(timeline: timeline)

        XCTAssertEqual(captions.map(\.text), ["⌘Z ×3", "⌘S", "⌘S"])
        XCTAssertEqual(captions[0].end, 2.3, "a different shortcut ends the previous caption")
        XCTAssertEqual(captions[1].end, 2.3 + EffectsPlanner.keyHold, accuracy: 0.001)
    }

    func testNothingToDrawMeansNoEffects() {
        var timeline = EventTimeline()
        XCTAssertTrue(EffectsOptions().isEmpty(for: timeline))
        timeline.clicks = [.init(time: 1, x: 0.5, y: 0.5)]
        XCTAssertFalse(EffectsOptions().isEmpty(for: timeline))
        XCTAssertTrue(EffectsOptions(clicks: false).isEmpty(for: timeline))
    }

    func testBuilderPutsOneRingPerVisibleClickAndAZoomOnTheContent() {
        var timeline = EventTimeline()
        timeline.clicks = [.init(time: 0.5, x: 0.5, y: 0.5), .init(time: 1.5, x: 0.2, y: 0.2), .init(time: 9, x: 0.1, y: 0.1)]
        timeline.zoomMarks = [1]
        let video = CALayer()

        let root = EffectsLayerBuilder.build(
            timeline: timeline, options: EffectsOptions(),
            videoSize: CGSize(width: 320, height: 240), keep: KeepRanges(duration: 2),
            videoLayer: video
        )

        XCTAssertEqual(root.bounds.size, CGSize(width: 320, height: 240), "the video's own size, no margins")
        let content = try? XCTUnwrap(video.superlayer)
        let rings = content?.sublayers?.filter { $0.animation(forKey: "click") != nil }
        XCTAssertEqual(rings?.count, 2, "the click at 9 s is past the end")
        XCTAssertEqual(content?.animationKeys()?.count, 1, "one zoom segment")
    }

    /// With pieces cut out, a click in the cut is gone and a click after a seam moves up by the
    /// length of the cut.
    func testClicksFollowTheirPieceAcrossTheCut() throws {
        var keep = KeepRanges(duration: 2)
        keep.moveEnd(of: 0, to: 1)
        keep.add(from: 1.5, to: 2)
        var timeline = EventTimeline()
        timeline.clicks = [.init(time: 1.2, x: 0.5, y: 0.5), .init(time: 1.6, x: 0.5, y: 0.5)]
        let video = CALayer()

        _ = EffectsLayerBuilder.build(
            timeline: timeline, options: EffectsOptions(), videoSize: CGSize(width: 320, height: 240),
            keep: keep, videoLayer: video
        )

        let rings = try XCTUnwrap(video.superlayer?.sublayers?.compactMap { $0.animation(forKey: "click") })
        XCTAssertEqual(rings.count, 1, "the click at 1.2 s was cut")
        XCTAssertEqual(try XCTUnwrap(rings.first).beginTime, 1.1, accuracy: 0.001, "1.6 s lands at 1.0 + 0.1")
    }

    /// A zoom crossing a seam is cut at the edge of each piece instead of running on over the
    /// next piece's picture.
    func testAZoomAcrossASeamSplitsAtTheEdge() {
        var keep = KeepRanges(duration: 2)
        keep.moveEnd(of: 0, to: 1)
        keep.add(from: 1.5, to: 2)

        let spans = EffectsLayerBuilder.spans(from: 0.8, to: 1.8, in: keep)

        XCTAssertEqual(spans.count, 2)
        XCTAssertEqual(spans[0].start, 0.8, accuracy: 0.001)
        XCTAssertEqual(spans[0].end, 1.0, accuracy: 0.001)
        XCTAssertEqual(spans[1].start, 1.0, accuracy: 0.001)
        XCTAssertEqual(spans[1].end, 1.3, accuracy: 0.001)
    }
}

/// Renders a real spliced export with a click and looks at the pixels — the same kind of trap as
/// the upside-down screenshot: a tree that builds without an error can still draw nothing, or draw
/// it at the wrong moment once pieces are cut out.
final class EffectsRenderTests: XCTestCase {
    func testExportDrawsTheClickRingWhereItsPieceLands() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pawshot-fx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let source = try await SyntheticVideo.write(to: folder.appendingPathComponent("in.mov"), audioTracks: 1)
        var timeline = EventTimeline()
        // Kept: 0–0.6 and 0.8–2. The click at 1.0 s of the recording lands at 0.8 s of the file.
        timeline.clicks = [.init(time: 1.0, x: 0.5, y: 0.5)]
        var keep = KeepRanges(duration: 2)
        keep.moveEnd(of: 0, to: 0.6)
        keep.add(from: 0.8, to: 2)
        XCTAssertEqual(try XCTUnwrap(keep.outputTime(forSource: 1.0)), 0.8, accuracy: 0.001)
        let out = folder.appendingPathComponent("out.mp4")

        try await VideoExporter.export(
            source: source, keep: keep, preset: .original, to: out,
            timeline: timeline, effects: EffectsOptions()
        ) { _ in }

        let asset = AVURLAsset(url: out)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let size = try await track.load(.naturalSize)
        XCTAssertEqual(size.width, SyntheticVideo.size.width, accuracy: 2)
        XCTAssertEqual(size.height, SyntheticVideo.size.height, accuracy: 2)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let (frame, _) = try await generator.image(at: CMTime(seconds: 0.9, preferredTimescale: 600))
        let rep = NSBitmapImageRep(cgImage: frame)

        // Somewhere on the circle around the click the ring is orange: lots of red, little blue.
        let center = CGPoint(x: SyntheticVideo.size.width / 2, y: SyntheticVideo.size.height / 2)
        var orange = false
        for radius in stride(from: 4.0, through: 22.0, by: 1.0) {
            for angle in stride(from: 0.0, to: 2 * Double.pi, by: Double.pi / 8) {
                let x = Int(center.x + radius * cos(angle))
                let y = Int(center.y + radius * sin(angle))
                if let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                   color.redComponent > 0.75, color.blueComponent < 0.4, color.greenComponent < 0.7
                {
                    orange = true
                }
            }
        }
        XCTAssertTrue(orange, "the click ring is drawn around the click")
    }
}
