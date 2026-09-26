import AppKit
@testable import Pawshot
import XCTest

final class WindowPickerTests: XCTestCase {
    private func window(_ rect: CGRect, pid: pid_t = 1) -> CapturedWindow {
        CapturedWindow(frame: rect, ownerPID: pid, windowID: CGWindowID(pid))
    }

    /// The list arrives front to back, so the first match is the window the user can actually see.
    /// Pick the last one instead and clicking a dialog would capture the window buried under it.
    func testFrontmostWindowWinsWhereTheyOverlap() {
        let front = window(CGRect(x: 100, y: 100, width: 200, height: 200))
        let behind = window(CGRect(x: 0, y: 0, width: 800, height: 600))

        let picked = WindowPicker.window(at: CGPoint(x: 150, y: 150), in: [front, behind])

        XCTAssertEqual(picked, front)
    }

    func testPointOutsideTheFrontWindowFallsThroughToTheOneBehind() {
        let front = window(CGRect(x: 100, y: 100, width: 200, height: 200))
        let behind = window(CGRect(x: 0, y: 0, width: 800, height: 600))

        let picked = WindowPicker.window(at: CGPoint(x: 40, y: 40), in: [front, behind])

        XCTAssertEqual(picked, behind)
    }

    func testNothingUnderTheCursorIsNotAPick() {
        let windows = [window(CGRect(x: 0, y: 0, width: 100, height: 100))]

        XCTAssertNil(WindowPicker.window(at: CGPoint(x: 500, y: 500), in: windows))
        XCTAssertNil(WindowPicker.window(at: .zero, in: []))
    }

    /// Windows live in global coordinates, so a second display is just larger x — the picker needs
    /// no idea that displays exist.
    func testWindowOnASecondDisplayIsPickedByItsGlobalFrame() {
        let onSecondScreen = window(CGRect(x: 1920, y: 200, width: 400, height: 300))

        let picked = WindowPicker.window(at: CGPoint(x: 2000, y: 300), in: [onSecondScreen])

        XCTAssertEqual(picked, onSecondScreen)
    }
}
