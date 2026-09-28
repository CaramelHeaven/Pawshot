import AppKit
@testable import Pawshot
import XCTest

/// The overlay goes up before the frames are captured, over the live screen, and the frames catch
/// up. These pin what that order must not break.
@MainActor
final class InstantOverlayTests: XCTestCase {
    private func frames() throws -> [CGDirectDisplayID: CapturedFrame] {
        var frames: [CGDirectDisplayID: CapturedFrame] = [:]
        let primaryMaxY = NSScreen.screens.first.map(\.frame.maxY) ?? 0
        for screen in NSScreen.screens {
            let displayID = try XCTUnwrap(SelectionOverlayController.displayID(of: screen))
            let size = screen.frame.size
            let context = try XCTUnwrap(CGContext(
                data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.setFillColor(CGColor(gray: 0.8, alpha: 1))
            context.fill(CGRect(origin: .zero, size: size))
            let origin = SelectionOverlayController.coreGraphicsOrigin(of: screen, primaryMaxY: primaryMaxY)
            frames[displayID] = try CapturedFrame(
                image: XCTUnwrap(context.makeImage()),
                displayFrame: CGRect(origin: origin, size: size),
                scale: 1
            )
        }
        return frames
    }

    private func visibleOverlays() -> [OverlayWindow] {
        NSApp.windows.compactMap { $0 as? OverlayWindow }.filter(\.isVisible)
    }

    /// The dimming is on screen with no frame yet — the hotkey no longer waits for the capture.
    func testTheOverlayIsUpBeforeTheFramesArrive() throws {
        let overlay = SelectionOverlayController()
        overlay.prepareWindows()
        overlay.begin(purpose: .screenshot) { _ in }
        defer { overlay.dismiss() }

        XCTAssertTrue(overlay.isActive)
        XCTAssertFalse(overlay.hasFrames)
        let window = try XCTUnwrap(visibleOverlays().first)
        XCTAssertNotNil(window.selectionView)
        XCTAssertNil(window.frameView.image, "the live screen shows through until the frame comes")
    }

    /// A selection made before the frames — a fast flick — is cut out of them once they come.
    func testASelectionBeforeTheFramesWaitsForThem() throws {
        let overlay = SelectionOverlayController()
        overlay.prepareWindows()
        var result: SelectionOverlayController.Selection??
        overlay.begin(purpose: .screenshot) { result = .some($0) }
        let view = try XCTUnwrap(visibleOverlays().first?.selectionView)

        overlay.selectionView(view, didSelect: CGRect(x: 10, y: 10, width: 100, height: 80), windowID: nil)
        XCTAssertNil(result, "nothing to cut from yet")
        XCTAssertTrue(overlay.isActive, "the overlay stays until the frames come")

        try overlay.deliver(frames: frames())
        let selection = try XCTUnwrap(result ?? nil)
        XCTAssertEqual(selection.rect.size, CGSize(width: 100, height: 80))
        XCTAssertFalse(overlay.isActive)
    }

    /// Esc before the frames closes the overlay; frames arriving afterwards are dropped.
    func testCancellingBeforeTheFramesDropsThem() throws {
        let overlay = SelectionOverlayController()
        overlay.prepareWindows()
        var result: SelectionOverlayController.Selection?? = nil
        overlay.begin(purpose: .screenshot) { result = .some($0) }
        let view = try XCTUnwrap(visibleOverlays().first?.selectionView)

        view.cancelOperation(nil)
        XCTAssertFalse(overlay.isActive)
        XCTAssertEqual(result.map { $0 == nil }, true, "cancelled")

        try overlay.deliver(frames: frames())
        XCTAssertFalse(overlay.isActive)
    }

    /// A capture that fails closes the overlay it already put up.
    func testAFailedCaptureClosesTheOverlay() {
        let overlay = SelectionOverlayController()
        overlay.prepareWindows()
        var cancelled = false
        overlay.begin(purpose: .screenshot) { cancelled = $0 == nil }

        overlay.fail()

        XCTAssertTrue(cancelled)
        XCTAssertFalse(overlay.isActive)
        XCTAssertTrue(visibleOverlays().isEmpty)
    }

    /// The windows are built once and reused: the hotkey never pays for creating one.
    func testTheWindowsAreReusedBetweenCaptures() throws {
        let overlay = SelectionOverlayController()
        overlay.prepareWindows()
        overlay.begin(purpose: .screenshot) { _ in }
        let first = try XCTUnwrap(visibleOverlays().first)
        overlay.dismiss()
        XCTAssertNil(first.frameView.image)

        overlay.begin(purpose: .screenshot) { _ in }
        defer { overlay.dismiss() }
        XCTAssertTrue(try XCTUnwrap(visibleOverlays().first) === first)
    }

    /// A non-activating panel: it takes the keyboard without making Pawshot the active app, and it
    /// stays up while another app is active.
    func testTheOverlayIsANonActivatingPanel() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let window = OverlayWindow(screen: screen)
        XCTAssertTrue(window.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(window.canBecomeKey)
        XCTAssertFalse(window.hidesOnDeactivate)
    }

    /// Of our own windows, everything but the overlay stays in the frame — an open editor, the paw.
    func testOnlyTheOverlayIsLeftOutOfTheFrame() {
        XCTAssertEqual(ScreenCaptureService.windowsToKeep([5, 7, 9], hiding: [7]), [5, 9])
        XCTAssertEqual(ScreenCaptureService.windowsToKeep([5], hiding: []), [5])
    }

    /// The real thing: with the overlay up, the frame taken while hiding it is not dimmed by it —
    /// taken at once, the way the hotkey takes it. ScreenCaptureKit notices a window that has just
    /// been ordered in a beat late, and until it does, an on-screen-only list has no Pawshot in it
    /// at all: one query in five missed it here, and a tester's log showed it twice. A version of
    /// this test that waited 300 ms first stayed green through all of that.
    func testTheFrameTakenAtOnceDoesNotContainTheOverlay() async throws {
        try XCTSkipUnless(CGPreflightScreenCaptureAccess(), "needs screen recording access")
        let screen = try XCTUnwrap(NSScreen.main)
        let displayID = try XCTUnwrap(SelectionOverlayController.displayID(of: screen))
        let overlay = SelectionOverlayController()
        overlay.prepareWindows()

        for attempt in 1 ... 8 {
            overlay.begin(purpose: .screenshot) { _ in }
            await Task.yield()
            let clean = try await ScreenCaptureService.captureDisplays([displayID], hiding: overlay.windowNumbers)
            try await Task.sleep(for: .milliseconds(300))
            let dimmed = try await ScreenCaptureService.captureDisplays([displayID])
            overlay.dismiss()

            let cleanLight = try XCTUnwrap(clean[displayID]).image.averageBrightness
            let dimmedLight = try XCTUnwrap(dimmed[displayID]).image.averageBrightness
            XCTAssertGreaterThan(cleanLight, dimmedLight * 1.2, "attempt \(attempt): the 35 % dimming is in one and not the other")
            try await Task.sleep(for: .milliseconds(200))
        }
    }

    /// Lines logged outside a capture say nothing about a hotkey, where they used to say `+-1 ms`.
    func testTheSinceHotkeyNoteIsOnlyThereDuringACapture() {
        OverlayDiagnostics.pressed(at: Date(timeIntervalSinceNow: -0.1))
        XCTAssertTrue(OverlayDiagnostics.sincePressNote().hasPrefix(" (+"))
        OverlayDiagnostics.ended()
        XCTAssertEqual(OverlayDiagnostics.sincePressNote(), "")
    }

    func testAStallMessageSaysWhereTheMainThreadWas() {
        XCTAssertEqual(
            MainThreadWatchdog.stallMessage(
                at: 400,
                mode: "kCFRunLoopDefaultMode",
                windows: "12 onscreen true alpha 1.0",
                mainThread: "running, priority 4 (base 47)",
                system: "memory pressure WARN, load 7.9"
            ),
            "main thread stalled over 250 ms at +400 ms, run loop mode kCFRunLoopDefaultMode; "
                + "window server: 12 onscreen true alpha 1.0; main thread running, priority 4 (base 47); "
                + "memory pressure WARN, load 7.9"
        )
    }
}

private extension CGImage {
    /// The mean of a 16 × 16 thumbnail's grey levels — enough to tell a dimmed screen from a clear one.
    var averageBrightness: Double {
        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.draw(self, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return 0 }
        return Double(pixels.reduce(0) { $0 + Int($1) }) / Double(side * side)
    }
}
