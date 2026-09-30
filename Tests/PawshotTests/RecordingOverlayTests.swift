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

    /// The corner brackets are drawn with 16 pt arms: pressing anywhere on an arm takes the
    /// corner, not the edge the arm lies on.
    func testTheWholeBracketArmGrabsTheCorner() {
        XCTAssertEqual(SelectionGeometry.handle(at: CGPoint(x: 114, y: 97), of: region), .topLeft)
        XCTAssertEqual(SelectionGeometry.handle(at: CGPoint(x: 503, y: 386), of: region), .bottomRight)
    }

    /// A press a little outside the line still takes the edge instead of wiping the region.
    func testAPressJustOutsideTheLineStillGrabsTheEdge() {
        XCTAssertEqual(SelectionGeometry.handle(at: CGPoint(x: 91, y: 250), of: region), .left)
        XCTAssertEqual(SelectionGeometry.handle(at: CGPoint(x: 300, y: 409), of: region), .bottom)
    }

    /// On a small region the zones shrink, so its middle can still be grabbed to move it.
    func testTheMiddleOfASmallRegionStaysReachable() {
        let small = CGRect(x: 100, y: 100, width: 12, height: 12)
        XCTAssertEqual(SelectionGeometry.handle(at: CGPoint(x: 106, y: 106), of: small), .inside)
    }

    // MARK: - The cursor

    func testTheCursorSaysWhatAPressWouldDo() {
        func cursor(_ point: CGPoint, grabbed: SelectionGeometry.Handle? = nil, overBar: Bool = false) -> SelectionView.CursorKind {
            SelectionView.cursorKind(at: point, selection: region, purpose: .recording, mode: .region, overBar: overBar, grabbed: grabbed)
        }
        XCTAssertEqual(cursor(CGPoint(x: 100, y: 250)), .resize(.left))
        XCTAssertEqual(cursor(CGPoint(x: 300, y: 250)), .openHand)
        XCTAssertEqual(cursor(CGPoint(x: 700, y: 250)), .crosshair)
        XCTAssertEqual(cursor(CGPoint(x: 300, y: 250), overBar: true), .arrow)
        XCTAssertEqual(cursor(CGPoint(x: 700, y: 250), grabbed: .right), .resize(.right), "the grabbed edge's cursor, wherever the drag is")
        XCTAssertEqual(cursor(CGPoint(x: 700, y: 250), grabbed: .inside), .closedHand)
        XCTAssertEqual(
            SelectionView.cursorKind(at: CGPoint(x: 100, y: 250), selection: region, purpose: .screenshot, mode: .region, overBar: false, grabbed: nil),
            .crosshair,
            "a screenshot region has no handles"
        )
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

    /// Down is +Y: the overlay counts from the top.
    func testArrowsAreStepsInViewCoordinates() throws {
        XCTAssertEqual(try RecordingOverlayKey.arrow(for: key(keyCode: kVK_LeftArrow, characters: "\u{F702}")), CGSize(width: -1, height: 0))
        XCTAssertEqual(try RecordingOverlayKey.arrow(for: key(keyCode: kVK_DownArrow, characters: "\u{F701}")), CGSize(width: 0, height: 1))
        XCTAssertNil(try RecordingOverlayKey.arrow(for: key(keyCode: kVK_ANSI_A, characters: "a")))
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

    private func mouse(
        _ type: NSEvent.EventType,
        at point: CGPoint,
        in view: NSView,
        modifiers: NSEvent.ModifierFlags = []
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: CGPoint(x: point.x, y: view.bounds.height - point.y),
            modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1
        ))
    }

    private func key(_ characters: String, keyCode: Int, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
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

    private func drag(
        _ view: SelectionView,
        from start: CGPoint,
        to end: CGPoint,
        modifiers: NSEvent.ModifierFlags = []
    ) throws {
        try view.mouseDown(with: mouse(.leftMouseDown, at: start, in: view, modifiers: modifiers))
        try view.mouseDragged(with: mouse(.leftMouseDragged, at: end, in: view, modifiers: modifiers))
        try view.mouseUp(with: mouse(.leftMouseUp, at: end, in: view, modifiers: modifiers))
    }

    /// What ↩ would record now.
    private func recorded(_ view: SelectionView, _ spy: Spy) throws -> CGRect? {
        try view.keyDown(with: key("\r", keyCode: kVK_Return))
        return spy.selected.last?.0
    }

    /// A window of another app, 300 × 300 with its middle at (550, 350).
    private let otherWindow = CapturedWindow(frame: CGRect(x: 400, y: 200, width: 300, height: 300), ownerPID: 1, windowID: 7)

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

    /// An edge is dragged through the view, not only through the geometry.
    func testDraggingTheRightEdgeWidensTheRegion() throws {
        let (view, spy) = makeView()
        try drag(view, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 250))
        try drag(view, from: CGPoint(x: 305, y: 175), to: CGPoint(x: 365, y: 175))
        try view.keyDown(with: key("r", keyCode: kVK_ANSI_R))

        XCTAssertEqual(spy.selected.first?.0, CGRect(x: 100, y: 100, width: 260, height: 150))
    }

    /// An edge dragged onto its opposite leaves nothing to grab; on release the region comes back
    /// as it was before the drag.
    func testAnEdgeDraggedToNothingPutsTheRegionBack() throws {
        let (view, spy) = makeView()
        try drag(view, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 250))
        try drag(view, from: CGPoint(x: 300, y: 175), to: CGPoint(x: 100, y: 175))
        try view.keyDown(with: key("r", keyCode: kVK_ANSI_R))

        XCTAssertEqual(spy.selected.first?.0, CGRect(x: 100, y: 100, width: 200, height: 150))
    }

    /// The region recorded last time comes back as the region itself, not as a picture of one:
    /// ↩ records it as it stands, and a drag by its middle moves it. It used to be a dashed ghost,
    /// and a press inside it drew a new region.
    func testTheLastRegionComesBackAlive() throws {
        let (view, spy) = makeView()
        let last = CGRect(x: 10, y: 20, width: 300, height: 200)
        view.restore(lastRegion: last)
        XCTAssertEqual(try recorded(view, spy), last)

        try drag(view, from: CGPoint(x: 160, y: 120), to: CGPoint(x: 200, y: 150))
        XCTAssertEqual(try recorded(view, spy), CGRect(x: 50, y: 50, width: 300, height: 200))
    }

    /// A click beside the region used to wipe it on the press itself.
    func testAClickBesideTheRegionLeavesIt() throws {
        let (view, spy) = makeView()
        try drag(view, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 250))

        let beside = CGPoint(x: 600, y: 500)
        try view.mouseDown(with: mouse(.leftMouseDown, at: beside, in: view))
        XCTAssertNotNil(view.recordingRegion, "the press alone changes nothing")
        try view.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: 601, y: 502), in: view))
        try view.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 601, y: 502), in: view))

        XCTAssertEqual(try recorded(view, spy), CGRect(x: 100, y: 100, width: 200, height: 150))
    }

    func testAPressBesideBecomesANewRegionOnceItMoves() throws {
        let (view, spy) = makeView()
        try drag(view, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 250))
        try drag(view, from: CGPoint(x: 500, y: 300), to: CGPoint(x: 700, y: 450))

        XCTAssertEqual(try recorded(view, spy), CGRect(x: 500, y: 300, width: 200, height: 150))
    }

    // MARK: - The drop onto a window

    /// Dragged by its middle onto the middle of a window, the region takes the window's frame —
    /// as a region: no window id goes to the recorder.
    func testDroppedOnTheMiddleOfAWindowTheRegionTakesItsFrame() throws {
        let (view, spy) = makeView()
        view.windows = [otherWindow]
        try drag(view, from: CGPoint(x: 50, y: 50), to: CGPoint(x: 150, y: 130))
        try drag(view, from: CGPoint(x: 100, y: 90), to: CGPoint(x: 550, y: 350))

        XCTAssertEqual(try recorded(view, spy), otherWindow.frame)
        XCTAssertNil(spy.selected.last?.1, "a fitted region is still a region")
    }

    /// Moved again, it is the size it was before the drop.
    func testMovedAgainTheFittedRegionGetsItsSizeBack() throws {
        let (view, spy) = makeView()
        view.windows = [otherWindow]
        try drag(view, from: CGPoint(x: 50, y: 50), to: CGPoint(x: 150, y: 130))
        try drag(view, from: CGPoint(x: 100, y: 90), to: CGPoint(x: 550, y: 350))

        // Grabbed a quarter of the way across and down the window: the cursor stays a quarter of
        // the way across and down the region that comes back.
        try drag(view, from: CGPoint(x: 475, y: 275), to: CGPoint(x: 175, y: 375))

        XCTAssertEqual(try recorded(view, spy), CGRect(x: 150, y: 355, width: 100, height: 80))
    }

    /// A click on a fitted region is not a move: it stays the window's size.
    func testAClickOnAFittedRegionKeepsItFitted() throws {
        let (view, spy) = makeView()
        view.windows = [otherWindow]
        try drag(view, from: CGPoint(x: 50, y: 50), to: CGPoint(x: 150, y: 130))
        try drag(view, from: CGPoint(x: 100, y: 90), to: CGPoint(x: 550, y: 350))
        try drag(view, from: CGPoint(x: 500, y: 300), to: CGPoint(x: 501, y: 301))

        XCTAssertEqual(try recorded(view, spy), otherWindow.frame)
    }

    /// Anywhere else over the window, the region is just laid on top of it.
    func testOffTheMiddleOfAWindowTheRegionKeepsItsSize() throws {
        let (view, spy) = makeView()
        view.windows = [otherWindow]
        try drag(view, from: CGPoint(x: 50, y: 50), to: CGPoint(x: 150, y: 130))
        try drag(view, from: CGPoint(x: 100, y: 90), to: CGPoint(x: 470, y: 350))

        XCTAssertEqual(try recorded(view, spy), CGRect(x: 420, y: 310, width: 100, height: 80))
    }

    func testCommandSwitchesTheFitAndTheMagnetOff() throws {
        let (view, spy) = makeView()
        view.windows = [otherWindow]
        try drag(view, from: CGPoint(x: 50, y: 50), to: CGPoint(x: 150, y: 130))
        try drag(view, from: CGPoint(x: 100, y: 90), to: CGPoint(x: 550, y: 350), modifiers: .command)
        XCTAssertEqual(try recorded(view, spy), CGRect(x: 500, y: 310, width: 100, height: 80))

        // 3 pt short of the window's right edge, at x 700: with ⌘ the dragged edge stays there.
        try drag(view, from: CGPoint(x: 600, y: 350), to: CGPoint(x: 697, y: 350), modifiers: .command)
        XCTAssertEqual(try recorded(view, spy)?.maxX, 697)
    }

    // MARK: - The magnet, the arrows, the modes

    func testADraggedEdgeSticksToAWindowEdge() throws {
        let (view, spy) = makeView()
        view.windows = [otherWindow]
        try drag(view, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 250))
        // The right edge is dragged to 4 pt short of the window's left edge, at x 400.
        try drag(view, from: CGPoint(x: 300, y: 175), to: CGPoint(x: 396, y: 175))

        XCTAssertEqual(try recorded(view, spy), CGRect(x: 100, y: 100, width: 300, height: 150))
    }

    func testArrowsMoveAndResizeTheRegion() throws {
        let (view, spy) = makeView()
        try drag(view, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 250))

        try view.keyDown(with: key("\u{F703}", keyCode: kVK_RightArrow))
        try view.keyDown(with: key("\u{F700}", keyCode: kVK_UpArrow, modifiers: .shift))
        XCTAssertEqual(try recorded(view, spy), CGRect(x: 101, y: 90, width: 200, height: 150))

        try view.keyDown(with: key("\u{F701}", keyCode: kVK_DownArrow, modifiers: [.option, .shift]))
        XCTAssertEqual(try recorded(view, spy), CGRect(x: 101, y: 90, width: 200, height: 160))
    }

    /// The toolbar switches modes back and forth; the region must outlive the trip.
    func testSwitchingModesKeepsTheRegion() throws {
        let (view, spy) = makeView()
        try drag(view, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 250))
        view.apply(mode: .window)
        view.apply(mode: .region)

        XCTAssertEqual(try recorded(view, spy), CGRect(x: 100, y: 100, width: 200, height: 150))
    }

    func testTheScreenModeRecordsTheWholeScreen() throws {
        let (view, spy) = makeView()
        view.apply(mode: .screen)

        XCTAssertEqual(try recorded(view, spy), view.bounds)
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
