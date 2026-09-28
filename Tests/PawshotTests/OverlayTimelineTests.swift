@testable import Pawshot
import XCTest

/// The first ⇧⌘2 after launch once showed nothing until a click. The timeline's lines are what
/// tell a frame never drawn from one drawn but not seen — so what they say is pinned here.
final class OverlayTimelineTests: XCTestCase {
    private let pressed = Date(timeIntervalSince1970: 1000)

    private func at(_ milliseconds: Double) -> Date {
        pressed.addingTimeInterval(milliseconds / 1000)
    }

    func testTheFirstDrawIsReportedOnceWithItsTime() {
        var timeline = OverlayTimeline(pressed: pressed)
        timeline.begin(at: at(90))

        XCTAssertEqual(timeline.drew(at: at(120)), "overlay first draw +120 ms")
        XCTAssertNil(timeline.drew(at: at(140)), "only the first one")
        XCTAssertEqual(timeline.draws, 2)
    }

    /// The report itself: the first event arrives before anything was drawn.
    func testAnEventBeforeAnyDrawIsFlagged() throws {
        var timeline = OverlayTimeline(pressed: pressed)
        timeline.begin(at: at(90))

        let first = try XCTUnwrap(timeline.received("mouseDown", at: at(4000)))
        XCTAssertFalse(first.drawnBefore)
        XCTAssertEqual(first.message, "overlay first event mouseDown +4000 ms, drawn before it: false")
        XCTAssertNil(timeline.received("mouseMoved", at: at(4100)), "only the first one")
    }

    func testAnEventAfterTheDrawIsNormal() throws {
        var timeline = OverlayTimeline(pressed: pressed)
        _ = timeline.drew(at: at(120))
        XCTAssertTrue(try XCTUnwrap(timeline.received("mouseMoved", at: at(300))).drawnBefore)
    }

    func testTheSummaryNamesTheSlowestDraw() {
        var timeline = OverlayTimeline(pressed: pressed)
        _ = timeline.drew(at: at(20))
        timeline.drawFinished(took: 0.004)
        timeline.drawFinished(took: 0.019)
        XCTAssertEqual(timeline.summary(at: at(900)), "overlay closed +900 ms after the hotkey, 1 draw(s), slowest 19 ms")
    }

    func testACheckWithoutADrawIsAnError() {
        var timeline = OverlayTimeline(pressed: pressed)
        let undrawn = timeline.check(at: at(500), visibleWindows: 0, windows: 1, appActive: false, keyWindow: false)
        XCTAssertTrue(undrawn.isError)
        XCTAssertTrue(undrawn.message.hasSuffix("NOT DRAWN YET"))

        _ = timeline.drew(at: at(510))
        let drawn = timeline.check(at: at(600), visibleWindows: 1, windows: 1, appActive: true, keyWindow: true)
        XCTAssertFalse(drawn.isError)
        XCTAssertEqual(drawn.message, "overlay check +600 ms: drawn 1×, visible 1/1, app active true, key window true")
    }
}
