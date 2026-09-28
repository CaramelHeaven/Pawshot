import AppKit
@testable import Pawshot
import XCTest

/// While the recorder records, every global hotkey is unregistered (`onRecordingChange(true)`), so
/// the old shortcut can be pressed to replace it. Whatever ends the recording has to say so, or
/// the hotkeys stay unregistered until a relaunch — and Pawshot answers no shortcut at all.
@MainActor
final class HotKeyRecorderViewTests: XCTestCase {
    private func recordingRecorder() throws -> (NSWindow, HotKeyRecorderView, () -> [Bool]) {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 200, height: 60),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        let recorder = HotKeyRecorderView(binding: .regionDefault)
        recorder.frame = CGRect(x: 10, y: 10, width: 150, height: 26)
        window.contentView?.addSubview(recorder)
        var changes: [Bool] = []
        recorder.onRecordingChange = { changes.append($0) }
        window.orderFront(nil)

        try recorder.mouseDown(with: XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: CGPoint(x: 20, y: 20),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )))
        XCTAssertEqual(changes, [true], "recording started")
        return (window, recorder, { changes })
    }

    /// A click on the field and then the window closed, no key pressed: measured, nothing ended
    /// the recording, and every hotkey stayed unregistered.
    func testClosingTheWindowMidRecordingGivesTheHotKeysBack() throws {
        let (window, _, changes) = try recordingRecorder()

        window.close()

        XCTAssertEqual(changes(), [true, false])
    }

    /// The same with the field taken out of the window — another Settings tab picked.
    func testLeavingTheWindowMidRecordingGivesTheHotKeysBack() throws {
        let (window, recorder, changes) = try recordingRecorder()
        defer { window.orderOut(nil) }

        recorder.removeFromSuperview()

        XCTAssertEqual(changes(), [true, false])
    }
}
