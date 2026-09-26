import AppKit
@testable import Pawshot
import XCTest

final class RecordingFrameGeometryTests: XCTestCase {
    /// A second display to the right of the first, a bit lower: the area comes in global AppKit
    /// coordinates, the frame window draws in its own.
    /// The outline shown for a zoom mark is exactly what the export zooms to: half the area,
    /// on the cursor, never past the area's edge.
    func testZoomOutlineIsHalfTheAreaOnTheCursorAndStaysInside() {
        let area = CGRect(x: 100, y: 100, width: 800, height: 600)

        XCTAssertEqual(
            SelectionGeometry.zoomPreviewRect(cursor: CGPoint(x: 500, y: 400), area: area, scale: 2),
            CGRect(x: 300, y: 250, width: 400, height: 300)
        )
        XCTAssertEqual(
            SelectionGeometry.zoomPreviewRect(cursor: CGPoint(x: 110, y: 690), area: area, scale: 2),
            CGRect(x: 100, y: 400, width: 400, height: 300),
            "a mark in the corner is pulled in, the way zoomOffset pulls the export"
        )
    }

    func testAreaIsMovedIntoTheScreensOwnCoordinates() {
        let screen = CGRect(x: 1512, y: -200, width: 2560, height: 1440)
        let area = CGRect(x: 1612, y: 100, width: 800, height: 600)

        XCTAssertEqual(
            SelectionGeometry.localRect(of: area, in: screen),
            CGRect(x: 100, y: 300, width: 800, height: 600)
        )
    }
}

@MainActor
final class RecordingFrameViewTests: XCTestCase {
    /// Outside the area dark, inside see-through, the red corner just outside — never inside,
    /// where it would sit over what is being recorded.
    func testDimsAroundTheAreaAndLeavesItClear() throws {
        let view = RecordingFrameView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        view.area = CGRect(x: 100, y: 80, width: 200, height: 140)

        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let factor = CGFloat(rep.pixelsWide) / view.bounds.width

        /// `colorAt` counts rows from the top; the view is unflipped, so y is turned over.
        func color(atX x: CGFloat, y: CGFloat) throws -> NSColor {
            try XCTUnwrap(rep.colorAt(
                x: Int(x * factor),
                y: Int((view.bounds.height - y) * factor)
            )?.usingColorSpace(.sRGB))
        }

        XCTAssertGreaterThan(try color(atX: 20, y: 20).alphaComponent, 0.3, "outside is dimmed")
        XCTAssertLessThan(try color(atX: 200, y: 150).alphaComponent, 0.01, "the area stays clear")
        XCTAssertLessThan(try color(atX: 103, y: 217).alphaComponent, 0.01, "nothing is drawn inside the corner")

        let corner = try color(atX: 97, y: 223)
        XCTAssertGreaterThan(corner.redComponent, 0.6, "the red bracket sits just outside the corner")
        XCTAssertLessThan(corner.greenComponent, 0.5)
    }

    /// A restart shows the frame again; it must be the same window moved, not a new one — a new
    /// one means a flash of the bare screen in between.
    func testShowingAgainReusesTheWindow() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let frame = RecordingFrameController()
        defer { frame.close() }
        frame.show(area: CGRect(x: screen.frame.minX + 50, y: screen.frame.minY + 50, width: 300, height: 200), on: screen)
        let first = try XCTUnwrap(frame.window)

        frame.show(area: CGRect(x: screen.frame.minX + 80, y: screen.frame.minY + 60, width: 320, height: 180), on: screen)

        XCTAssertTrue(frame.window === first)
        XCTAssertEqual((first.contentView as? RecordingFrameView)?.area, CGRect(x: 80, y: 60, width: 320, height: 180))
    }

    func testFrameWindowLetsClicksThroughAndCoversTheScreen() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let frame = RecordingFrameController()
        frame.show(area: CGRect(x: screen.frame.minX + 50, y: screen.frame.minY + 50, width: 300, height: 200), on: screen)
        defer { frame.close() }

        XCTAssertEqual(frame.window?.ignoresMouseEvents, true)
        XCTAssertEqual(frame.window?.frame, screen.frame)
    }
}

@MainActor
final class VideoEditorOrderingTests: XCTestCase {
    /// The test host is a background app while xcodebuild runs, which is exactly the situation
    /// after a recording: another app is in front and activation may be refused. The editor must
    /// still come up above every other app's window.
    func testEditorOpensAboveOtherAppsWindows() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pawshot-front-\(UUID().uuidString).mov")
        _ = try await SyntheticVideo.write(to: url, audioTracks: 0)
        let screen = try XCTUnwrap(NSScreen.main)
        let controller = VideoEditorWindowController(movieURL: url, videoSize: SyntheticVideo.size, on: screen)
        defer { controller.close() }

        controller.show()
        try await Task.sleep(for: .milliseconds(300))

        let number = try XCTUnwrap(controller.window?.windowNumber)
        let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]]) ?? []
        let firstOrdinary = windows.first { ($0[kCGWindowLayer as String] as? Int) == 0 }
        XCTAssertEqual(firstOrdinary?[kCGWindowNumber as String] as? Int, number, "the editor is the front window")
    }
}
