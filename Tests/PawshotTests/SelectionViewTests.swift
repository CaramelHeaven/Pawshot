import AppKit
@testable import Pawshot
import XCTest

@MainActor
final class SelectionViewTests: XCTestCase {
    /// A frame whose top half is red and bottom half is blue. `CGContext` has its origin at the
    /// bottom left, so the top of the image means large Y.
    private func makeFrame(size: CGSize) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))

        context.setFillColor(NSColor.red.cgColor)
        context.fill(CGRect(x: 0, y: size.height / 2, width: size.width, height: size.height / 2))
        context.setFillColor(NSColor.blue.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height / 2))

        return try XCTUnwrap(context.makeImage())
    }

    /// A trap for the same mine as in `AnnotationRendererTests`: `SelectionView` has
    /// `isFlipped = true`, and the `draw(in:from:operation:fraction:)` variant draws the picture
    /// upside down — silently, without a single error. The dimming on top of the frame mutes the
    /// colours, so the channels are compared against each other rather than against a reference
    /// red.
    func testFrozenFrameIsNotUpsideDown() throws {
        let size = CGSize(width: 40, height: 60)
        let view = SelectionView(frame: CGRect(origin: .zero, size: size))
        view.background = try NSImage(cgImage: makeFrame(size: size), size: size)

        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)

        // The rep's origin is at the top left — like the frame's. Its size, however, is in
        // pixels: on Retina that is twice the view's, and points in the view's coordinates would
        // land in the wrong place.
        let middleX = rep.pixelsWide / 2
        let top = try XCTUnwrap(rep.colorAt(x: middleX, y: rep.pixelsHigh / 4)?.usingColorSpace(.deviceRGB))
        let bottom = try XCTUnwrap(
            rep.colorAt(x: middleX, y: rep.pixelsHigh * 3 / 4)?.usingColorSpace(.deviceRGB)
        )

        XCTAssertGreaterThan(top.redComponent, top.blueComponent, "the top of the frame must stay red")
        XCTAssertGreaterThan(bottom.blueComponent, bottom.redComponent, "the bottom must stay blue")
    }

    private func mouse(_ type: NSEvent.EventType, at point: CGPoint, in view: NSView) throws -> NSEvent {
        // The view has no window here, so "window coordinates" are the view's own — flipped back,
        // because `convert(_:from: nil)` expects AppKit's bottom-left origin.
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type,
            location: CGPoint(x: point.x, y: view.bounds.height - point.y),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
    }

    private func key(_ characters: String, keyCode: Int) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: UInt16(keyCode)
        ))
    }

    /// A frame that is green except for a narrow column on the left: red above the middle, blue
    /// below. The loupe, placed over the green part, must show red on top and blue at the bottom —
    /// the same flip trap as the frozen frame, this time in the magnifier's own drawing.
    func testLoupeMagnifiesTheFrameRightSideUp() throws {
        let size = CGSize(width: 200, height: 120)
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 200, height: 120, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(NSColor.green.cgColor)
        context.fill(CGRect(origin: .zero, size: size))
        context.setFillColor(NSColor.red.cgColor)
        context.fill(CGRect(x: 0, y: 60, width: 40, height: 60))
        context.setFillColor(NSColor.blue.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 60))
        let image = try XCTUnwrap(context.makeImage())

        let view = SelectionView(frame: CGRect(origin: .zero, size: size))
        view.background = NSImage(cgImage: image, size: size)
        view.frameImage = image
        view.scale = 1

        try view.mouseMoved(with: mouse(.mouseMoved, at: CGPoint(x: 20, y: 60), in: view))
        try view.keyDown(with: key("m", keyCode: 46))

        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let factor = CGFloat(rep.pixelsWide) / size.width

        func color(at point: CGPoint) throws -> NSColor {
            try XCTUnwrap(rep.colorAt(x: Int(point.x * factor), y: Int(point.y * factor))?.usingColorSpace(.deviceRGB))
        }

        // The loupe lands at x 40…160, y 0…120 — over the green.
        let upper = try color(at: CGPoint(x: 100, y: 25))
        let lower = try color(at: CGPoint(x: 100, y: 95))
        XCTAssertGreaterThan(upper.redComponent, upper.greenComponent, "the top of the loupe is the red above the cursor")
        XCTAssertGreaterThan(lower.blueComponent, lower.greenComponent, "the bottom is the blue below it")
    }
}
