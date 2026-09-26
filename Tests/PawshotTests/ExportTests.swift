import AppKit
@testable import Pawshot
import XCTest

final class ExportNamingTests: XCTestCase {
    private func date(_ iso: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: iso)!
    }

    func testFileNameMatchesAgreedFormat() throws {
        let name = try ExportNaming.fileName(
            date: date("2026-08-08 13:42:10"),
            uuid: XCTUnwrap(UUID(uuidString: "3F9A2C11-0000-0000-0000-000000000000")),
            timeZone: XCTUnwrap(TimeZone(identifier: "UTC"))
        )

        XCTAssertEqual(name, "pawshot-2026-08-08-134210-3f9a2c.png")
    }

    func testFileNameIsLowercasedAndHasNoSpaces() throws {
        let name = try ExportNaming.fileName(
            date: date("2026-01-02 03:04:05"),
            uuid: XCTUnwrap(UUID(uuidString: "ABCDEF01-0000-0000-0000-000000000000")),
            timeZone: XCTUnwrap(TimeZone(identifier: "UTC"))
        )

        XCTAssertEqual(name, "pawshot-2026-01-02-030405-abcdef.png")
        XCTAssertFalse(name.contains(" "))
    }

    /// Two shots taken within the same second must not overwrite each other — that's what the
    /// UUID tail is for.
    func testSameSecondDifferentUUIDGivesDifferentNames() throws {
        let moment = date("2026-08-08 13:42:10")
        let zone = try XCTUnwrap(TimeZone(identifier: "UTC"))

        let first = ExportNaming.fileName(date: moment, uuid: UUID(), timeZone: zone)
        let second = ExportNaming.fileName(date: moment, uuid: UUID(), timeZone: zone)

        XCTAssertNotEqual(first, second)
    }
}

@MainActor
final class AnnotationRendererTests: XCTestCase {
    /// A white shot in points, but twice as large in pixels — like on Retina.
    ///
    /// - Parameter crop: the visible region inside the captured frame. It defaults to the whole
    ///   frame; the resize tests hand in a smaller one to check that the export follows the crop.
    private func makeDocument(
        pointSize: CGSize,
        scale: CGFloat,
        crop: CGRect? = nil
    ) -> EditorDocument {
        let pixelWidth = Int(pointSize.width * scale)
        let pixelHeight = Int(pointSize.height * scale)

        let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))

        let frame = CapturedFrame(
            image: context.makeImage()!,
            displayFrame: CGRect(origin: .zero, size: pointSize),
            scale: scale
        )
        return EditorDocument(
            frame: frame,
            cropRect: crop ?? CGRect(origin: .zero, size: pointSize)
        )!
    }

    private func color(of image: CGImage, atX x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8)? {
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return nil }
        let offset = y * image.bytesPerRow + x * (image.bitsPerPixel / 8)
        return (bytes[offset], bytes[offset + 1], bytes[offset + 2])
    }

    func testRenderKeepsFullPixelResolution() {
        let document = makeDocument(pointSize: CGSize(width: 200, height: 100), scale: 2)

        let rendered = AnnotationRenderer.render(document)

        XCTAssertEqual(rendered?.width, 400)
        XCTAssertEqual(rendered?.height, 200)
    }

    /// The key test of the whole export: an annotation in the top third of the shot has to end
    /// up in the top third of the file. Get the sign of the Y flip wrong and the picture is built
    /// without a single error — but mirrored, which the eye doesn't catch right away.
    func testAnnotationLandsWhereItWasDrawn() throws {
        let document = makeDocument(pointSize: CGSize(width: 200, height: 300), scale: 1)

        let marker = RectangleAnnotation(
            start: CGPoint(x: 20, y: 20),
            style: AnnotationStyle(color: .red, lineWidth: 3, isFilled: true)
        )
        marker.update(to: CGPoint(x: 180, y: 80))
        document.add(marker)

        let rendered = try XCTUnwrap(AnnotationRenderer.render(document))

        let top = try XCTUnwrap(color(of: rendered, atX: 100, y: 50))
        let bottom = try XCTUnwrap(color(of: rendered, atX: 100, y: 250))

        XCTAssertGreaterThan(top.r, top.b, "the top third must carry a red mark")
        XCTAssertEqual(bottom.r, bottom.b, "the bottom of the shot must stay white")
    }

    /// The regression guard for annotations living in frame coordinates: growing the shot to the
    /// left must not drag what is already drawn. The marker sits 20 pt from the left edge of the
    /// crop; after the crop grows by 40 pt on that side, the very same pixels have to be 60 pt in.
    func testGrowingTheCropLeftKeepsAnnotationsInPlace() throws {
        let document = makeDocument(
            pointSize: CGSize(width: 300, height: 200),
            scale: 1,
            crop: CGRect(x: 100, y: 0, width: 200, height: 200)
        )

        let marker = RectangleAnnotation(
            start: CGPoint(x: 120, y: 20),
            style: AnnotationStyle(color: .red, lineWidth: 3, isFilled: true)
        )
        marker.update(to: CGPoint(x: 160, y: 60))
        document.add(marker)

        let before = try XCTUnwrap(AnnotationRenderer.render(document))
        XCTAssertGreaterThan(try XCTUnwrap(color(of: before, atX: 30, y: 40)).r,
                             try XCTUnwrap(color(of: before, atX: 30, y: 40)).b)

        document.setCrop(CGRect(x: 60, y: 0, width: 240, height: 200))
        let after = try XCTUnwrap(AnnotationRenderer.render(document))

        XCTAssertEqual(after.width, 240, "the shot itself grew")
        let moved = try XCTUnwrap(color(of: after, atX: 70, y: 40))
        let vacated = try XCTUnwrap(color(of: after, atX: 20, y: 40))

        XCTAssertGreaterThan(moved.r, moved.b, "the marker stayed on the same pixels of the frame")
        XCTAssertEqual(vacated.r, vacated.b, "the newly captured strip is bare")
    }

    /// Shrinking leaves the annotation alive but outside the picture — it is clipped away by the
    /// context, and growing back brings it into view again.
    func testShrinkingTheCropClipsAnnotationWithoutDeletingIt() throws {
        let document = makeDocument(pointSize: CGSize(width: 200, height: 200), scale: 1)

        let marker = RectangleAnnotation(
            start: CGPoint(x: 150, y: 20),
            style: AnnotationStyle(color: .red, lineWidth: 3, isFilled: true)
        )
        marker.update(to: CGPoint(x: 190, y: 60))
        document.add(marker)

        document.setCrop(CGRect(x: 0, y: 0, width: 100, height: 200))
        let shrunk = try XCTUnwrap(AnnotationRenderer.render(document))

        XCTAssertEqual(shrunk.width, 100)
        XCTAssertEqual(document.annotations.count, 1, "the annotation is kept, only clipped")

        document.setCrop(CGRect(x: 0, y: 0, width: 200, height: 200))
        let restored = try XCTUnwrap(AnnotationRenderer.render(document))
        let marked = try XCTUnwrap(color(of: restored, atX: 170, y: 40))

        XCTAssertGreaterThan(marked.r, marked.b, "growing back shows it again")
    }

    func testSelectionFrameIsNotExported() throws {
        let document = makeDocument(pointSize: CGSize(width: 100, height: 100), scale: 1)
        let arrow = ArrowAnnotation(start: CGPoint(x: 10, y: 10), style: .default)
        arrow.update(to: CGPoint(x: 90, y: 90))
        document.add(arrow)
        document.selection = arrow

        let rendered = try XCTUnwrap(AnnotationRenderer.render(document))

        // The selection frame is drawn around the object with an inset; the corner of the shot
        // has to stay clean.
        let corner = try XCTUnwrap(color(of: rendered, atX: 2, y: 2))
        XCTAssertEqual(corner.r, corner.g)
        XCTAssertEqual(corner.g, corner.b)
    }
}

@MainActor
final class ExportServiceTests: XCTestCase {
    private func makeImage() -> CGImage {
        let context = CGContext(
            data: nil,
            width: 20,
            height: 10,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return context.makeImage()!
    }

    /// Into its own pasteboard, not the general one: a test must not clobber what the user
    /// copied.
    func testCopyPutsPNGOnPasteboard() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("pawshot.tests"))

        try ExportService.copy(makeImage(), to: pasteboard)

        XCTAssertNotNil(pasteboard.data(forType: .png))
        XCTAssertNotNil(pasteboard.data(forType: .tiff))
    }

    func testPNGDataStartsWithPNGSignature() throws {
        let data = try ExportService.pngData(from: makeImage())

        XCTAssertEqual(Array(data.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
    }

    func testCopyTextPutsItOnPasteboardAsPlainText() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("pawshot.tests.text"))

        ExportService.copy(text: "let total = 4", to: pasteboard)

        XCTAssertEqual(pasteboard.string(forType: .string), "let total = 4")
    }

    /// ⌘C and ⌘D share one pasteboard, and ⌘C runs first far more often. Without wiping what is
    /// already on it, the picture stays next to the text, and an app that prefers an image — Mail,
    /// Slack — pastes the old screenshot instead of the words just asked for.
    func testCopyTextClearsAPreviouslyCopiedImage() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("pawshot.tests.text"))
        try ExportService.copy(makeImage(), to: pasteboard)

        ExportService.copy(text: "let total = 4", to: pasteboard)

        XCTAssertNil(pasteboard.data(forType: .png))
        XCTAssertNil(pasteboard.data(forType: .tiff))
    }
}
