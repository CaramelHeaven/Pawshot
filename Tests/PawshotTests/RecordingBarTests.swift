import AppKit
@testable import Pawshot
import SwiftUI
import XCTest

/// The recording toolbar is built once at launch and its actions are filled in later, per capture. A
/// button that captured the action when the view was first drawn stays dead for good — exactly
/// what "Record only works with ↩" was.
@MainActor
final class RecordingBarTests: XCTestCase {
    func testButtonsCallTheActionsSetAfterTheFirstDraw() throws {
        let model = OverlayHUD.RecordingBarModel()
        let host = NSHostingView(rootView: RecordingToolbarView(model: model))
        let size = host.fittingSize
        let window = NSWindow(
            contentRect: CGRect(origin: CGPoint(x: 200, y: 200), size: size),
            styleMask: .borderless, backing: .buffered, defer: false
        )
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        host.display()

        var started = 0
        model.start = { started += 1 }

        // The Record button is the last thing in the toolbar, just inside its right padding.
        let point = CGPoint(x: size.width - 40, y: size.height / 2)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ))
            window.sendEvent(event)
        }

        XCTAssertEqual(started, 1)
    }
}

/// The same click, but where it really happens: the bar inside the capture overlay, put there by
/// the real `SelectionOverlayController`, the event going through the overlay window.
@MainActor
final class RecordingBarInOverlayTests: XCTestCase {
    private func frame(for screen: NSScreen, displayID _: CGDirectDisplayID) throws -> CapturedFrame {
        let size = screen.frame.size
        let context = try XCTUnwrap(CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 0.8, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        let primaryMaxY = NSScreen.screens.first.map(\.frame.maxY) ?? 0
        let origin = SelectionOverlayController.coreGraphicsOrigin(of: screen, primaryMaxY: primaryMaxY)
        return try CapturedFrame(image: XCTUnwrap(context.makeImage()), displayFrame: CGRect(origin: origin, size: size), scale: 1)
    }

    private func click(_ window: NSWindow, at point: CGPoint, type: NSEvent.EventType) throws {
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        window.sendEvent(event)
    }

    /// Draws a new region of `size` from a corner of the screen that no region restored from the
    /// last take holds. The test host is the app, with the owner's settings: his last region
    /// comes back alive, and a press inside it — or within reach of its edges — moves it instead
    /// of drawing a new one.
    private func drawRegion(_ window: NSWindow, _ view: SelectionView, size: CGSize = CGSize(width: 400, height: 250)) throws {
        let restored = view.recordingRegion?.insetBy(dx: -60, dy: -60)
        let bar = OverlayHUD.recordingBarHost.superview === view ? OverlayHUD.recordingBarHost.frame.insetBy(dx: -20, dy: -20) : .null
        let room = view.bounds.insetBy(dx: 60, dy: 60)
        let corners = [
            CGPoint(x: room.minX, y: room.minY),
            CGPoint(x: room.maxX - size.width, y: room.minY),
            CGPoint(x: room.minX, y: room.maxY - size.height),
            CGPoint(x: room.maxX - size.width, y: room.maxY - size.height),
        ]
        let start = try XCTUnwrap(
            corners.first { !(restored?.contains($0) ?? false) && !bar.contains($0) },
            "the region restored from the last take, \(String(describing: view.recordingRegion)), leaves no corner to draw from"
        )
        let end = CGPoint(x: start.x + size.width, y: start.y + size.height)
        try click(window, at: view.convert(start, to: nil), type: .leftMouseDown)
        try click(window, at: view.convert(end, to: nil), type: .leftMouseDragged)
        try click(window, at: view.convert(end, to: nil), type: .leftMouseUp)
        XCTAssertEqual(view.recordingRegion?.size, size, "a new region was drawn, not the restored one moved")
    }

    /// The overlay window of the main screen — the one the test hands a frame for. Another
    /// screen's overlay has no frame, and a selection there is dropped.
    private func mainOverlayWindow() throws -> (NSWindow, SelectionView) {
        let screen = try XCTUnwrap(NSScreen.main)
        let window = try XCTUnwrap(NSApp.windows.first { $0 is OverlayWindow && $0.isVisible && $0.screen == screen })
        let view = try XCTUnwrap((window as? OverlayWindow)?.selectionView)
        return (window, view)
    }

    /// The toolbar as it stands before anything is found wrong: no line above it. What the
    /// preflight or the level meter say comes later and would move the buttons under the click.
    private func layOutPlainToolbar(in view: SelectionView) throws {
        let bar = OverlayHUD.recordingBar
        bar.takenShortcuts = []
        bar.freeBytes = nil
        bar.microphoneIsSilent = false
        bar.zoneCount = 0
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
    }

    /// Opens the recording overlay with a region drawn and the toolbar laid out at the bottom.
    private func overlayWithRegion(
        onSelect: @escaping (SelectionOverlayController.Selection?) -> Void
    ) throws -> (SelectionOverlayController, NSWindow, SelectionView) {
        let screen = try XCTUnwrap(NSScreen.main)
        let displayID = try XCTUnwrap(SelectionOverlayController.displayID(of: screen))
        let overlay = SelectionOverlayController()
        let captured = try frame(for: screen, displayID: displayID)
        overlay.begin(frames: [displayID: captured], purpose: .recording, completion: onSelect)

        let (window, view) = try mainOverlayWindow()
        try drawRegion(window, view)
        try layOutPlainToolbar(in: view)
        return (overlay, window, view)
    }

    /// Anywhere on the bar — its padding, the gap between two buttons — belongs to the bar. A
    /// click there that fell through to the overlay started a new region and wiped the one drawn.
    func testClickAnywhereOnTheBarKeepsTheRegion() throws {
        let (overlay, window, view) = try overlayWithRegion { _ in }
        defer { overlay.dismiss() }
        let bar = OverlayHUD.recordingBarHost
        let region = try XCTUnwrap(view.recordingRegion, "a region to keep")

        for x in [bar.frame.minX + 2, bar.frame.minX + bar.frame.width * 0.45, bar.frame.maxX - 2] {
            let point = view.convert(CGPoint(x: x, y: bar.frame.midY), to: nil)
            try click(window, at: point, type: .leftMouseDown)
            try click(window, at: point, type: .leftMouseUp)
            XCTAssertEqual(view.recordingRegion, region, "a click at x \(x) of the bar wiped the region")
        }
    }

    /// Pawshot may not be the active app when the overlay is up — macOS can refuse the
    /// activation — and then the first click on a view that doesn't accept it only activates.
    func testTheBarTakesTheFirstClick() {
        XCTAssertTrue(OverlayHUD.recordingBarHost.acceptsFirstMouse(for: nil))
    }

    func testRecordButtonStartsTheRecording() throws {
        var selected: SelectionOverlayController.Selection?
        let (overlay, window, view) = try overlayWithRegion { selected = $0 }
        defer { overlay.dismiss() }

        let bar = OverlayHUD.recordingBarHost
        XCTAssertTrue(bar.superview === view, "the toolbar is on the screen that was clicked")
        XCTAssertGreaterThan(bar.frame.width, 100, "a bar with an empty frame can't be clicked")
        // Record is the last button of the row, and the row is the bottom of the toolbar (the
        // view is flipped: the bottom is the frame's maxY).
        let record = view.convert(CGPoint(x: bar.frame.maxX - 40, y: bar.frame.maxY - 20), to: nil)

        let hit = window.contentView?.superview?.hitTest(record) ?? window.contentView?.hitTest(record)
        let hitName = hit.map { String(describing: type(of: $0)) } ?? "nil"

        try click(window, at: record, type: .leftMouseDown)
        try click(window, at: record, type: .leftMouseUp)

        XCTAssertNotNil(selected, "Record started nothing — the click landed on \(hitName)")
        XCTAssertEqual(selected?.rect.size, CGSize(width: 400, height: 250))
    }
}
