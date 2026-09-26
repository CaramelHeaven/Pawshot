import AppKit
@testable import Pawshot
import SwiftUI
import XCTest

/// Holds a reading open so the test decides when it answers, and counts how many times it was
/// asked. Both defects under test are about what happens *while* a reading is still in flight.
@MainActor
private final class RecognitionStub {
    private(set) var callCount = 0
    var onCall: (() -> Void)?

    private var continuation: CheckedContinuation<String, Error>?

    func recognize(_: CGImage) async throws -> String {
        callCount += 1
        onCall?()
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func finish(with text: String) {
        continuation?.resume(returning: text)
        continuation = nil
    }
}

@MainActor
final class EditorWindowControllerTests: XCTestCase {
    private func makeDocument(pointSize: CGSize, scale: CGFloat) throws -> EditorDocument {
        let context = CGContext(
            data: nil,
            width: Int(pointSize.width * scale),
            height: Int(pointSize.height * scale),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let frame = CapturedFrame(
            image: context.makeImage()!,
            displayFrame: CGRect(origin: .zero, size: pointSize),
            scale: scale
        )
        return try XCTUnwrap(
            EditorDocument(frame: frame, cropRect: CGRect(origin: .zero, size: pointSize))
        )
    }

    /// Catches crashes while assembling the window, and the one setting the toolbar hangs on: the
    /// SwiftUI `.toolbar` only reaches an AppKit window through scene bridging. The toolbar itself
    /// is installed once the window is on screen, which a unit test doesn't do.
    func testBuildsWindowWithBridgedToolbar() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let document = try makeDocument(pointSize: CGSize(width: 200, height: 100), scale: 2)

        let controller = EditorWindowController(
            document: document,
            on: screen
        )

        let window = try XCTUnwrap(controller.window)
        XCTAssertEqual(window.title, "400 × 200")

        let hosting = try XCTUnwrap(window.contentViewController as? NSHostingController<EditorView>)
        XCTAssertTrue(hosting.sceneBridgingOptions.contains(.toolbars), "the SwiftUI toolbar is bridged")
        XCTAssertEqual(hosting.sizingOptions, [], "the window's size follows the shot, not SwiftUI")
    }

    /// The window opens the size of the shot plus its margin, so the shot is whole at once and the
    /// edges can be dragged straight away.
    func testWindowStartsTheSizeOfTheShotPlusTheMargin() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let document = try makeDocument(pointSize: CGSize(width: 300, height: 200), scale: 2)

        let controller = EditorWindowController(
            document: document,
            on: screen
        )

        let content = try XCTUnwrap(controller.window?.contentLayoutRect.size)
        let margin = EditorView.shotPadding * 2
        XCTAssertEqual(content.width, 300 + margin, accuracy: 0.5)
        XCTAssertEqual(content.height, 200 + margin, accuracy: 0.5)
    }

    /// The SwiftUI toolbar reaches the AppKit window only through scene bridging, and only once the
    /// window is on screen. Shown fully transparent, so nothing flashes while the suite runs.
    func testSwiftUIToolbarLandsInTheWindowOnceShown() async throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let document = try makeDocument(pointSize: CGSize(width: 900, height: 300), scale: 1)
        let controller = EditorWindowController(
            document: document,
            on: screen
        )
        let window = try XCTUnwrap(controller.window)
        window.alphaValue = 0
        window.orderFront(nil)
        defer { window.orderOut(nil) }

        for _ in 0 ..< 20 where (window.toolbar?.items.count ?? 0) == 0 {
            try await Task.sleep(for: .milliseconds(50))
        }

        let toolbar = try XCTUnwrap(window.toolbar, "no toolbar reached the window")
        XCTAssertGreaterThan(toolbar.items.count, 10, "tools, colours, widths, history, export")
    }

    /// The toolbar arrives after the window is shown. Measured: AppKit grows the frame for it, and
    /// `show()` refits once more as a safety net. Either way the shot must open whole — a shot that
    /// doesn't fit its window no longer grows or crops when an edge is dragged.
    func testShotStillFitsItsWindowAfterTheToolbarArrives() async throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let document = try makeDocument(pointSize: CGSize(width: 900, height: 300), scale: 1)
        let controller = EditorWindowController(
            document: document,
            on: screen
        )
        controller.recognizeText = { _ in "" }
        let window = try XCTUnwrap(controller.window)
        window.alphaValue = 0
        controller.show()
        defer { controller.close() }

        let margin = EditorView.shotPadding * 2
        for _ in 0 ..< 20 where abs(window.contentLayoutRect.height - (300 + margin)) > 0.5 {
            try await Task.sleep(for: .milliseconds(50))
        }

        XCTAssertNotNil(window.toolbar)
        XCTAssertEqual(window.contentLayoutRect.width, 900 + margin, accuracy: 0.5)
        XCTAssertEqual(window.contentLayoutRect.height, 300 + margin, accuracy: 0.5)
    }

    /// ⌘Z sends `undo:` down the responder chain. Since the content became an `NSHostingController`,
    /// `NSWindow` answers it with an undo manager SwiftUI supplies — not the one the document
    /// records into — and ⌘Z silently did nothing. The canvas, first in the chain, has to answer.
    func testUndoSentDownTheResponderChainUndoesTheLastChange() async throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let document = try makeDocument(pointSize: CGSize(width: 400, height: 200), scale: 1)
        let controller = EditorWindowController(
            document: document,
            on: screen
        )
        controller.recognizeText = { _ in "" }
        let window = try XCTUnwrap(controller.window)
        window.alphaValue = 0
        controller.show()
        defer { controller.close() }
        try await Task.sleep(for: .milliseconds(200))

        let shape = RectangleAnnotation(start: CGPoint(x: 10, y: 10), style: .default)
        shape.update(to: CGPoint(x: 100, y: 100))
        document.add(shape)
        // Undo groups close at the end of a run loop pass, as they would after a real mouse-up.
        try await Task.sleep(for: .milliseconds(50))

        let responder = try XCTUnwrap(window.firstResponder)
        XCTAssertTrue(responder.tryToPerform(Selector(("undo:")), with: nil))
        XCTAssertTrue(document.annotations.isEmpty, "⌘Z must take the rectangle back")

        XCTAssertTrue(responder.tryToPerform(Selector(("redo:")), with: nil))
        XCTAssertEqual(document.annotations.count, 1, "⌘⇧Z must bring it back again")
    }

    /// The editor opens in the middle of the screen the shot was taken on, wherever the selection
    /// was — the owner's choice over "below the selection".
    func testWindowOpensCentredOnItsScreen() async throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let document = try makeDocument(pointSize: CGSize(width: 600, height: 400), scale: 1)
        let controller = EditorWindowController(
            document: document,
            on: screen
        )
        controller.recognizeText = { _ in "" }
        let window = try XCTUnwrap(controller.window)
        window.alphaValue = 0
        controller.show()
        defer { controller.close() }
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(window.frame.midX, screen.visibleFrame.midX, accuracy: 1)
        XCTAssertEqual(window.frame.midY, screen.visibleFrame.midY, accuracy: 1)
    }

    /// A shot bigger than the window — a full-screen capture — opens on its middle, not on its top
    /// left corner.
    func testHugeShotOpensScrolledToItsMiddle() async throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let size = CGSize(width: 3000, height: 2000)
        let document = try makeDocument(pointSize: size, scale: 1)
        let controller = EditorWindowController(document: document, on: screen)
        controller.recognizeText = { _ in "" }
        let window = try XCTUnwrap(controller.window)
        window.alphaValue = 0
        controller.show()
        defer { controller.close() }
        try await Task.sleep(for: .milliseconds(300))

        func scrollView(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView {
                return scroll
            }
            return view.subviews.lazy.compactMap(scrollView(in:)).first
        }
        let scroll = try XCTUnwrap(window.contentView.flatMap(scrollView(in:)))
        let visible = scroll.contentView.documentVisibleRect

        XCTAssertEqual(visible.midX, size.width / 2, accuracy: 1)
        XCTAssertEqual(visible.midY, size.height / 2, accuracy: 1)
    }

    /// A full-screen shot must not open in a window larger than the screen.
    func testWindowFitsOnScreenForHugeScreenshot() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let huge = CGSize(width: screen.frame.width * 2, height: screen.frame.height * 2)

        let controller = try EditorWindowController(
            document: makeDocument(pointSize: huge, scale: 1),
            on: screen
        )

        let window = try XCTUnwrap(controller.window)
        XCTAssertLessThanOrEqual(window.frame.width, screen.visibleFrame.width)
        XCTAssertLessThanOrEqual(window.frame.height, screen.visibleFrame.height)
    }

    // MARK: - ⌘D

    /// A controller wired to a stub reader and a pasteboard of its own. `show()` is never called,
    /// so no warm-up runs and nothing here ever reaches Vision — which also means these tests do
    /// not need the Neural Engine and take microseconds.
    private func makeReadingController(
        _ stub: RecognitionStub,
        pasteboard: NSPasteboard
    ) throws -> EditorWindowController {
        let screen = try XCTUnwrap(NSScreen.main)
        let controller = try EditorWindowController(
            document: makeDocument(pointSize: CGSize(width: 200, height: 100), scale: 2),
            on: screen
        )
        controller.recognizeText = { try await stub.recognize($0) }
        controller.pasteboard = pasteboard
        // A named pasteboard lives in the system pasteboard server and outlives the test process,
        // so yesterday's answer is still sitting in it. Without this, a test that asserts the text
        // arrived passes while reading the previous run's value.
        pasteboard.clearContents()
        return controller
    }

    private func waitUntilReadingStarts(_ stub: RecognitionStub) async {
        let started = expectation(description: "the reading has started")
        stub.onCall = { started.fulfill() }
        await fulfillment(of: [started], timeout: 2)
    }

    /// Reading a 5K shot is not free, and ⌘D is a key somebody can lean on. A second press while
    /// the first is still working used to start a second reading of the same picture.
    func testSecondCopyTextIsIgnoredWhileTheFirstIsStillReading() async throws {
        let stub = RecognitionStub()
        let controller = try makeReadingController(
            stub,
            pasteboard: NSPasteboard(name: NSPasteboard.Name("pawshot.tests.copytext.repeat"))
        )

        controller.copyText(nil)
        let reading = try XCTUnwrap(controller.textReadingTask)
        await waitUntilReadingStarts(stub)

        controller.copyText(nil)
        stub.finish(with: "hello")
        await reading.value

        XCTAssertEqual(stub.callCount, 1)
    }

    /// What the owner actually hit: a reading was running, the window was closed, and the text
    /// asked for vanished without a word. ⌘D is a request for the text, not for the window.
    func testTextStillReachesTheClipboardWhenTheWindowIsClosedFirst() async throws {
        let stub = RecognitionStub()
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("pawshot.tests.copytext.closed"))
        let controller = try makeReadingController(stub, pasteboard: pasteboard)

        controller.copyText(nil)
        let reading = try XCTUnwrap(controller.textReadingTask)
        await waitUntilReadingStarts(stub)

        controller.close()
        stub.finish(with: "text from the shot")
        await reading.value

        XCTAssertEqual(pasteboard.string(forType: .string), "text from the shot")
    }

    /// The exact shape of what went wrong on the owner's machine. The window opens and starts a
    /// warm-up reading; ⌘D on an untouched shot waits on that very reading rather than starting
    /// its own; the window is closed; and the warm-up used to be cancelled out from under it, so
    /// the text asked for disappeared without a word.
    func testTextSurvivesWhenTheWindowClosesWhileTheWarmUpIsStillReading() async throws {
        let stub = RecognitionStub()
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("pawshot.tests.copytext.warmup"))
        let controller = try makeReadingController(stub, pasteboard: pasteboard)

        controller.startTextRecognitionWarmUp()
        await waitUntilReadingStarts(stub)

        controller.copyText(nil)
        let reading = try XCTUnwrap(controller.textReadingTask)
        controller.close()
        stub.finish(with: "from the warm-up")
        await reading.value

        XCTAssertEqual(pasteboard.string(forType: .string), "from the warm-up")
        XCTAssertEqual(stub.callCount, 1, "an untouched shot reuses the warm-up instead of re-reading it")
    }
}
