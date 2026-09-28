import AppKit
import Carbon.HIToolbox
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

        try click(recorder, atX: 20)
        XCTAssertEqual(changes, [true], "recording started")
        return (window, recorder, { changes })
    }

    /// A click `x` points from the window's left edge; the recorder starts at 10 and is 150 wide.
    private func click(_ recorder: HotKeyRecorderView, atX x: CGFloat) throws {
        try recorder.mouseDown(with: XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: CGPoint(x: x, y: 20),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: recorder.window?.windowNumber ?? 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )))
    }

    /// Modifiers going down or up, as AppKit hands them to the field.
    private func modifiers(_ flags: CGEventFlags, in recorder: HotKeyRecorderView) throws {
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Command), keyDown: true))
        event.type = .flagsChanged
        event.flags = flags
        try recorder.flagsChanged(with: XCTUnwrap(NSEvent(cgEvent: event)))
    }

    private func resignKey(_ window: NSWindow) {
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
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

    /// A tester's log: the field still recording for 35 s while she was in other apps, every
    /// global hotkey unregistered all that time. The window losing focus ends it now.
    func testTheWindowLosingFocusMidRecordingGivesTheHotKeysBack() throws {
        let (window, _, changes) = try recordingRecorder()
        defer { window.orderOut(nil) }

        resignKey(window)

        XCTAssertEqual(changes(), [true, false])
    }

    /// Clicking a recording field again used to announce the recording again and unregister the
    /// hotkeys a second time.
    func testASecondClickDoesNotAnnounceTheRecordingAgain() throws {
        let (window, recorder, changes) = try recordingRecorder()
        defer { window.orderOut(nil) }

        try click(recorder, atX: 20)

        XCTAssertEqual(changes(), [true])
        XCTAssertTrue(recorder.isRecording)
    }

    /// The × at the right end takes the shortcut away and starts no recording.
    func testTheCrossClearsTheShortcutWithoutRecording() throws {
        let (window, recorder, _) = try recordingRecorder()
        defer { window.orderOut(nil) }
        resignKey(window)
        var changes: [Bool] = []
        recorder.onRecordingChange = { changes.append($0) }
        var cleared = 0
        recorder.onClear = { cleared += 1 }

        try click(recorder, atX: 10 + 150 - 8)

        XCTAssertEqual(cleared, 1)
        XCTAssertEqual(changes, [], "no recording")

        recorder.binding = nil
        try click(recorder, atX: 10 + 150 - 8)

        XCTAssertEqual(cleared, 1, "no shortcut, no ×: the click records")
        XCTAssertEqual(changes, [true])
    }

    /// ⇧⌘ held and let go with no key between: the tester's ⇧⌘1, taken by her window switcher
    /// before Pawshot. The field says so instead of doing nothing.
    func testModifiersLetGoWithNoKeySayTheKeyNeverArrived() throws {
        let (window, recorder, _) = try recordingRecorder()
        defer { window.orderOut(nil) }

        try modifiers([.maskShift, .maskCommand], in: recorder)
        try modifiers([], in: recorder)

        XCTAssertEqual(recorder.hint, "Didn't reach Pawshot")
        XCTAssertTrue(recorder.isRecording, "another combination can be tried at once")

        try modifiers([.maskShift], in: recorder)
        XCTAssertNil(recorder.hint, "the next chord clears it")
        try modifiers([], in: recorder)
        XCTAssertNil(recorder.hint, "⇧ alone is not a shortcut, nothing went missing")
    }

    /// The same chord taking the focus away — a switcher bringing up another app's window.
    func testTheWindowLosingFocusMidChordSaysTheKeyNeverArrived() throws {
        let (window, recorder, changes) = try recordingRecorder()
        defer { window.orderOut(nil) }

        try modifiers([.maskShift, .maskCommand], in: recorder)
        resignKey(window)

        XCTAssertEqual(recorder.hint, "Didn't reach Pawshot")
        XCTAssertEqual(changes(), [true, false])
    }
}
