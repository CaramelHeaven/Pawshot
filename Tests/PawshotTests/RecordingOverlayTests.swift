import AppKit
import Carbon.HIToolbox
@testable import Pawshot
import XCTest

final class RecordingRegionGeometryTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
    private let region = CGRect(x: 100, y: 100, width: 400, height: 300)

    func testHandlesPreferCornersThenEdgesThenInside() {
        XCTAssertEqual(SelectionGeometry.handle(at: CGPoint(x: 103, y: 96), of: region), .topLeft)
        XCTAssertEqual(SelectionGeometry.handle(at: CGPoint(x: 300, y: 104), of: region), .top)
        XCTAssertEqual(SelectionGeometry.handle(at: CGPoint(x: 505, y: 402), of: region), .bottomRight)
        XCTAssertEqual(SelectionGeometry.handle(at: CGPoint(x: 97, y: 250), of: region), .left)
        XCTAssertEqual(SelectionGeometry.handle(at: CGPoint(x: 300, y: 250), of: region), .inside)
        XCTAssertNil(SelectionGeometry.handle(at: CGPoint(x: 600, y: 250), of: region), "outside starts a new one")
    }

    func testCornerResizeKeepsTheOppositeCorner() {
        let resized = SelectionGeometry.resized(
            region, dragging: .bottomRight, to: CGPoint(x: 700, y: 500), aspect: nil, within: bounds
        )
        XCTAssertEqual(resized, CGRect(x: 100, y: 100, width: 600, height: 400))
    }

    func testEdgeResizeMovesOnlyThatEdgeAndStopsAtTheScreen() {
        let left = SelectionGeometry.resized(region, dragging: .left, to: CGPoint(x: -50, y: 999), aspect: nil, within: bounds)
        XCTAssertEqual(left, CGRect(x: 0, y: 100, width: 500, height: 300))
    }

    /// Dragged past the opposite edge, the region flips instead of turning negative.
    func testEdgeDraggedPastItsOppositeFlips() {
        let flipped = SelectionGeometry.resized(region, dragging: .right, to: CGPoint(x: 50, y: 0), aspect: nil, within: bounds)
        XCTAssertEqual(flipped, CGRect(x: 50, y: 100, width: 50, height: 300))
    }

    func testEdgeResizeWithAspectGrowsTheOtherSideAroundItsMiddle() {
        let wide = SelectionGeometry.resized(
            region, dragging: .right, to: CGPoint(x: 420, y: 0), aspect: 16.0 / 9.0, within: bounds
        )
        XCTAssertEqual(wide.width / wide.height, 16.0 / 9.0, accuracy: 0.001)
        XCTAssertEqual(wide.minX, 100)
        XCTAssertEqual(wide.midY, region.midY, accuracy: 0.001)
    }

    func testDragWithAspectHoldsTheProportionsAndStaysInside() {
        let square = SelectionGeometry.rect(
            from: CGPoint(x: 900, y: 700), to: CGPoint(x: 2000, y: 650), aspect: 1, within: bounds
        )
        XCTAssertEqual(square.width, square.height)
        XCTAssertTrue(bounds.contains(square))
        XCTAssertEqual(square, CGRect(x: 900, y: 650, width: 50, height: 50))
    }

    func testMoveStopsAtTheEdgeWithoutShrinking() {
        let moved = SelectionGeometry.moved(region, by: CGSize(width: 900, height: -500), within: bounds)
        XCTAssertEqual(moved, CGRect(x: 600, y: 0, width: 400, height: 300))
    }

    /// Cycling the proportions must not eat the region: the area stays, the middle stays.
    func testApplyingAspectKeepsAreaAndMiddle() {
        let wide = SelectionGeometry.applying(aspect: 16.0 / 9.0, to: region, within: bounds)
        XCTAssertEqual(wide.width * wide.height, region.width * region.height, accuracy: 1)
        XCTAssertEqual(wide.midX, region.midX, accuracy: 0.001)
        XCTAssertEqual(wide.width / wide.height, 16.0 / 9.0, accuracy: 0.001)

        let back = SelectionGeometry.applying(aspect: 4.0 / 3.0, to: wide, within: bounds)
        XCTAssertEqual(back.width, region.width, accuracy: 0.5)
    }

    func testTypedSizeIsInPixelsOfTheFile() throws {
        let exact = try XCTUnwrap(SelectionGeometry.exactRect(
            pixelWidth: 1280, pixelHeight: 720, outputScale: 2, around: CGPoint(x: 950, y: 400), within: bounds
        ))
        XCTAssertEqual(exact.size, CGSize(width: 640, height: 360))
        XCTAssertEqual(exact.maxX, 1000, "pushed back inside rather than cut")

        XCTAssertNil(SelectionGeometry.exactRect(
            pixelWidth: 3840, pixelHeight: 2160, outputScale: 2, around: .zero, within: bounds
        ), "a size bigger than the display is a promise that can't be kept")
    }

    func testBarGoesUnderThenAboveThenInside() {
        let bar = CGSize(width: 300, height: 36)
        XCTAssertEqual(SelectionGeometry.barOrigin(under: region, barSize: bar, bounds: bounds).y, 412)

        let low = CGRect(x: 100, y: 500, width: 400, height: 290)
        XCTAssertEqual(SelectionGeometry.barOrigin(under: low, barSize: bar, bounds: bounds).y, 500 - 12 - 36)

        let full = SelectionGeometry.barOrigin(under: bounds, barSize: bar, bounds: bounds)
        XCTAssertEqual(full.y, 800 - 24 - 36)
        XCTAssertEqual(full.x, 350)
    }
}

final class RecordingOverlayOptionsTests: XCTestCase {
    func testAspectCyclesBackToFree() {
        var aspect = AspectLock.free
        var labels: [String?] = []
        for _ in AspectLock.allCases {
            aspect = aspect.next
            labels.append(aspect.label)
        }
        XCTAssertEqual(labels, ["16:9", "9:16", "1:1", "4:3", nil])
    }

    func testSizeIsTypedAsDigitsSeparatorDigits() {
        var input = SizeInput()
        XCTAssertFalse(input.type("x"), "x before any digit is the 1x/2x key")
        for character in "1920x1080" {
            XCTAssertTrue(input.type(character))
        }
        XCTAssertEqual(input.text, "1920×1080")
        XCTAssertEqual(input.size?.width, 1920)
        XCTAssertEqual(input.size?.height, 1080)

        XCTAssertFalse(input.type("x"), "only one separator")
        input.deleteBackward()
        XCTAssertEqual(input.size?.height, 108)
    }

    func testHalfTypedSizeIsNoSize() {
        var input = SizeInput()
        for character in "1920 " {
            _ = input.type(character)
        }
        XCTAssertNil(input.size)
        XCTAssertFalse(input.type("q"))
    }

    private func key(keyCode: Int, characters: String) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: UInt16(keyCode)
        ))
    }

    /// On ЙЦУКЕН the keys print ф, ч, ь, ы, к — the actions must not care.
    func testKeysAreReadOffThePhysicalKey() throws {
        XCTAssertEqual(try RecordingOverlayKey.action(for: key(keyCode: kVK_ANSI_A, characters: "ф")), .aspect)
        XCTAssertEqual(try RecordingOverlayKey.action(for: key(keyCode: kVK_ANSI_X, characters: "ч")), .scale)
        XCTAssertEqual(try RecordingOverlayKey.action(for: key(keyCode: kVK_ANSI_M, characters: "ь")), .microphone)
        XCTAssertEqual(try RecordingOverlayKey.action(for: key(keyCode: kVK_ANSI_S, characters: "ы")), .systemAudio)
        XCTAssertEqual(try RecordingOverlayKey.action(for: key(keyCode: kVK_ANSI_R, characters: "к")), .start)
        XCTAssertEqual(try RecordingOverlayKey.action(for: key(keyCode: kVK_Return, characters: "\r")), .start)
        XCTAssertNil(try RecordingOverlayKey.action(for: key(keyCode: kVK_Space, characters: " ")))
    }
}

final class SignalWatchTests: XCTestCase {
    /// A quiet room is not a dead microphone.
    func testQuietRoomIsASignal() {
        var watch = SignalWatch()
        let quietRoom: Float = 0.000_5 // about −66 dBFS
        for step in 0 ... 40 {
            XCTAssertFalse(watch.feed(quietRoom, at: Double(step) * 0.1))
        }
    }

    func testDigitalSilenceForAMomentAndAHalfIsDead() {
        var watch = SignalWatch()
        XCTAssertFalse(watch.feed(0.1, at: 0))
        XCTAssertFalse(watch.feed(0, at: 1.0))
        XCTAssertTrue(watch.feed(0, at: 1.6))
        XCTAssertFalse(watch.feed(0.1, at: 1.7), "the signal coming back clears it")
    }

    func testMeterMapsDecibelsOntoTheBars() {
        XCTAssertEqual(SignalWatch.meterLevel(rms: 0), 0)
        XCTAssertEqual(SignalWatch.meterLevel(rms: 1), 1)
        XCTAssertEqual(SignalWatch.meterLevel(rms: 0.001), 0, accuracy: 0.001, "−60 dBFS reads as empty")
    }
}

@MainActor
final class RecordingSelectionViewTests: XCTestCase {
    private final class Spy: SelectionViewDelegate {
        var selected: [(CGRect, CGWindowID?)] = []
        var toggled: [RecordingOverlayKey] = []
        var cancelled = 0

        func selectionView(_: SelectionView, didSelect rect: CGRect, windowID: CGWindowID?) {
            selected.append((rect, windowID))
        }

        func selectionViewDidCancel(_: SelectionView) {
            cancelled += 1
        }

        func selectionView(_: SelectionView, didToggle option: RecordingOverlayKey) {
            toggled.append(option)
        }

        func selectionView(_: SelectionView, didSwitchTo _: SelectionView.Mode) {}
    }

    private func mouse(_ type: NSEvent.EventType, at point: CGPoint, in view: NSView) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: CGPoint(x: point.x, y: view.bounds.height - point.y),
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1
        ))
    }

    private func key(_ characters: String, keyCode: Int) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: UInt16(keyCode)
        ))
    }

    private func makeView() -> (SelectionView, Spy) {
        let view = SelectionView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        view.purpose = .recording
        view.scale = 2
        let spy = Spy()
        view.delegate = spy
        return (view, spy)
    }

    private func drag(_ view: SelectionView, from start: CGPoint, to end: CGPoint) throws {
        try view.mouseDown(with: mouse(.leftMouseDown, at: start, in: view))
        try view.mouseDragged(with: mouse(.leftMouseDragged, at: end, in: view))
        try view.mouseUp(with: mouse(.leftMouseUp, at: end, in: view))
    }

    /// A screenshot ends on mouse up; a recording region stays, and ↩ starts it.
    func testMouseUpKeepsTheRegionAndReturnStarts() throws {
        let (view, spy) = makeView()
        try drag(view, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 250))
        XCTAssertTrue(spy.selected.isEmpty, "nothing starts on mouse up")

        try view.keyDown(with: key("\r", keyCode: kVK_Return))

        XCTAssertEqual(spy.selected.first?.0, CGRect(x: 100, y: 100, width: 200, height: 150))
        XCTAssertNil(spy.selected.first?.1)
    }

    func testDraggingTheInsideMovesTheRegion() throws {
        let (view, spy) = makeView()
        try drag(view, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 250))
        try drag(view, from: CGPoint(x: 200, y: 170), to: CGPoint(x: 250, y: 190))
        try view.keyDown(with: key("r", keyCode: kVK_ANSI_R))

        XCTAssertEqual(spy.selected.first?.0, CGRect(x: 150, y: 120, width: 200, height: 150))
    }

    func testReturnWithoutARegionRecordsTheGhost() throws {
        let (view, spy) = makeView()
        view.ghost = CGRect(x: 10, y: 20, width: 300, height: 200)

        try view.keyDown(with: key("\r", keyCode: kVK_Return))

        XCTAssertEqual(spy.selected.first?.0, view.ghost)
    }

    func testTypedSizeBecomesTheRegion() throws {
        let (view, spy) = makeView()
        try view.mouseMoved(with: mouse(.mouseMoved, at: CGPoint(x: 400, y: 300), in: view))
        for (character, code) in [("6", kVK_ANSI_6), ("4", kVK_ANSI_4), ("0", kVK_ANSI_0), ("x", kVK_ANSI_X),
                                  ("4", kVK_ANSI_4), ("8", kVK_ANSI_8), ("0", kVK_ANSI_0)]
        {
            try view.keyDown(with: key(character, keyCode: code))
        }
        try view.keyDown(with: key("\r", keyCode: kVK_Return))
        XCTAssertTrue(spy.selected.isEmpty, "the first ↩ applies the size, it doesn't start")
        XCTAssertTrue(spy.toggled.isEmpty, "the x between the numbers is not the 1x/2x key")

        try view.keyDown(with: key("\r", keyCode: kVK_Return))
        XCTAssertEqual(spy.selected.first?.0, CGRect(x: 240, y: 180, width: 320, height: 240))
    }

    func testAspectKeyReshapesTheRegion() throws {
        let (view, spy) = makeView()
        try drag(view, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 400, y: 400))
        try view.keyDown(with: key("a", keyCode: kVK_ANSI_A))
        try view.keyDown(with: key("\r", keyCode: kVK_Return))

        let region = try XCTUnwrap(spy.selected.first?.0)
        XCTAssertEqual(region.width / region.height, 16.0 / 9.0, accuracy: 0.001)
        XCTAssertEqual(view.aspect, .wide)
    }

    func testSoundAndScaleKeysGoToTheDelegate() throws {
        let (view, spy) = makeView()
        try view.keyDown(with: key("m", keyCode: kVK_ANSI_M))
        try view.keyDown(with: key("s", keyCode: kVK_ANSI_S))
        try view.keyDown(with: key("x", keyCode: kVK_ANSI_X))

        XCTAssertEqual(spy.toggled, [.microphone, .systemAudio, .scale])
        XCTAssertFalse(view.nativeResolution, "X switched to 1x")
    }

    /// Esc with a size half typed clears the typing first; the second Esc cancels.
    func testEscapeCascadesThroughTheTypedSize() throws {
        let (view, spy) = makeView()
        try view.keyDown(with: key("1", keyCode: kVK_ANSI_1))
        view.cancelOperation(nil)
        XCTAssertEqual(spy.cancelled, 0)

        view.cancelOperation(nil)
        XCTAssertEqual(spy.cancelled, 1)
    }
}
