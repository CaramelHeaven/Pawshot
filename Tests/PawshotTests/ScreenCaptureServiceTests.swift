import AppKit
import CoreGraphics
@testable import Pawshot
import XCTest

/// An integration test: it pokes the real ScreenCaptureKit. It skips itself when the test host
/// has no screen recording access — otherwise on somebody else's machine it would fail for a
/// reason that has nothing to do with the code.
final class ScreenCaptureServiceTests: XCTestCase {
    @MainActor
    func testCapturesWholeDisplayAtItsScale() async throws {
        try XCTSkipUnless(
            CGPreflightScreenCaptureAccess(),
            "No screen recording access — the capture test is skipped"
        )

        let screen = try XCTUnwrap(NSScreen.main)
        let displayID = try XCTUnwrap(SelectionOverlayController.displayID(of: screen))

        let frames = try await ScreenCaptureService.captureDisplays([displayID])
        let frame = try XCTUnwrap(frames[displayID])

        XCTAssertEqual(frame.displayFrame.width, screen.frame.width, accuracy: 1)
        XCTAssertEqual(frame.displayFrame.height, screen.frame.height, accuracy: 1)
        XCTAssertEqual(CGFloat(frame.image.width), screen.frame.width * frame.scale, accuracy: frame.scale)
        XCTAssertEqual(CGFloat(frame.image.height), screen.frame.height * frame.scale, accuracy: frame.scale)
    }

    /// The frame is captured whole and the selection is cut out of it — this checks the pair,
    /// because this is exactly where points and pixels are easy to mix up.
    @MainActor
    func testCropsRequestedRegionOutOfCapturedFrame() async throws {
        try XCTSkipUnless(
            CGPreflightScreenCaptureAccess(),
            "No screen recording access — the capture test is skipped"
        )

        let screen = try XCTUnwrap(NSScreen.main)
        let displayID = try XCTUnwrap(SelectionOverlayController.displayID(of: screen))
        let frames = try await ScreenCaptureService.captureDisplays([displayID])
        let frame = try XCTUnwrap(frames[displayID])

        let region = CGRect(x: frame.displayFrame.minX, y: frame.displayFrame.minY, width: 100, height: 80)
        let crop = try XCTUnwrap(
            SelectionGeometry.cropRect(
                displayRect: region,
                displayFrame: frame.displayFrame,
                scale: frame.scale,
                imagePixelSize: CGSize(width: frame.image.width, height: frame.image.height)
            )
        )
        let image = try XCTUnwrap(frame.image.cropping(to: crop))

        XCTAssertEqual(CGFloat(image.width), region.width * frame.scale, accuracy: frame.scale)
        XCTAssertEqual(CGFloat(image.height), region.height * frame.scale, accuracy: frame.scale)
    }
}
