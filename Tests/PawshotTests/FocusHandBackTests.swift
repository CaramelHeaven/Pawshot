import AppKit
@testable import Pawshot
import XCTest

/// Closing the last editor gives the focus back to the app the person was in; a window of
/// Pawshot's own still open — Settings, a second editor — keeps it.
@MainActor
final class FocusHandBackTests: XCTestCase {
    private func shownWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.orderFront(nil)
        addTeardownBlock { window.orderOut(nil) }
        return window
    }

    func testOnlyAnotherOrdinaryWindowKeepsTheFocus() {
        let closing = shownWindow()
        let other = shownWindow()

        XCTAssertFalse(FocusHandBack.otherWindowsStayOpen(closing: closing, among: [closing]), "the closing one doesn't count")
        XCTAssertTrue(FocusHandBack.otherWindowsStayOpen(closing: closing, among: [closing, other]))

        other.level = .floating
        XCTAssertFalse(FocusHandBack.otherWindowsStayOpen(closing: closing, among: [closing, other]), "a toast or the pill doesn't")

        other.level = .normal
        other.orderOut(nil)
        XCTAssertFalse(FocusHandBack.otherWindowsStayOpen(closing: closing, among: [closing, other]), "a hidden one doesn't")
    }
}
