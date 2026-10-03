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

    private func shownController(_ document: EditorDocument) throws -> (EditorWindowController, NSWindow) {
        let controller = try EditorWindowController(document: document, on: XCTUnwrap(NSScreen.main))
        controller.recognizeText = { _ in "" }
        let window = try XCTUnwrap(controller.window)
        window.alphaValue = 0
        window.orderFront(nil)
        return (controller, window)
    }

    private func canvas(in view: NSView?) -> AnnotationCanvasView? {
        guard let view else { return nil }
        if let canvas = view as? AnnotationCanvasView {
            return canvas
        }
        return view.subviews.lazy.compactMap { self.canvas(in: $0) }.first
    }

    /// The window's own edge is the system's to show the resize cursor on — the way to grow or crop
    /// the shot. The canvas, first responder, gets mouse moves from all over the window, and it used
    /// to put its tool's cursor there too: the resize cursor survived in about a pixel (the owner,
    /// 2026-09-30). Near every edge the canvas must leave the cursor alone, and it never reaches
    /// closer to an edge than the padding round the shot.
    func testTheCanvasLeavesTheCursorAloneAtTheWindowsEdges() async throws {
        let document = try makeDocument(pointSize: CGSize(width: 600, height: 400), scale: 1)
        let (controller, window) = try shownController(document)
        defer { controller.close() }
        var found: AnnotationCanvasView?
        for _ in 0 ..< 40 {
            found = canvas(in: window.contentView)
            if let found, found.visibleRect.width > 0 {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        let canvas = try XCTUnwrap(found, "no canvas in the editor")
        let content = try XCTUnwrap(window.contentView).bounds

        let nearEdges = [
            CGPoint(x: content.minX + 2, y: content.midY),
            CGPoint(x: content.maxX - 2, y: content.midY),
            CGPoint(x: content.midX, y: content.minY + 2),
        ]
        for point in nearEdges {
            XCTAssertFalse(canvas.ownsCursor(atWindowPoint: point), "the canvas takes the cursor at \(point), by the window's edge")
        }
        let middle = canvas.convert(CGPoint(x: canvas.visibleRect.midX, y: canvas.visibleRect.midY), to: nil)
        XCTAssertTrue(canvas.ownsCursor(atWindowPoint: middle), "over the shot the cursor is the canvas's")

        let onWindow = canvas.convert(canvas.visibleRect, to: nil)
        let margin = EditorView.shotPadding - 1
        XCTAssertGreaterThanOrEqual(onWindow.minX - content.minX, margin, "\(onWindow) in \(content)")
        XCTAssertGreaterThanOrEqual(content.maxX - onWindow.maxX, margin, "\(onWindow) in \(content)")
        XCTAssertGreaterThanOrEqual(onWindow.minY - content.minY, margin, "\(onWindow) in \(content)")
    }

    /// Esc lets go of the selection and then does nothing at all: it used to close the window
    /// once everything else was let go of, and a shot was lost to one press too many.
    func testEscapeNeverClosesTheEditor() throws {
        let document = try makeDocument(pointSize: CGSize(width: 300, height: 200), scale: 1)
        let (_, window) = try shownController(document)
        defer { window.orderOut(nil) }
        let box = RectangleAnnotation(start: CGPoint(x: 10, y: 10), style: .default)
        box.update(to: CGPoint(x: 50, y: 30))
        document.add(box)
        document.selection = box
        let canvas = try XCTUnwrap(canvas(in: window.contentView))

        canvas.cancelOperation(nil)
        XCTAssertNil(document.selection)
        canvas.cancelOperation(nil)
        canvas.cancelOperation(nil)

        XCTAssertTrue(window.isVisible, "still open after Esc on an empty selection")
    }

    /// A tap of ⌘Q closes a shot nothing was done to straight away.
    func testQuitKeyClosesAnUntouchedShotAtOnce() throws {
        let document = try makeDocument(pointSize: CGSize(width: 300, height: 200), scale: 1)
        let (controller, window) = try shownController(document)
        defer { window.orderOut(nil) }
        XCTAssertEqual(QuitKey.action(for: window), .askController)
        XCTAssertFalse(controller.hasWork)

        controller.closeForQuitKey()

        XCTAssertFalse(window.isVisible)
    }

    /// Growing the shot by the window's edge and turning it are not drawing: a tap of ⌘Q still
    /// closes at once. It used to ask, since both are steps of ⌘Z.
    func testQuitKeyClosesACroppedOrTurnedShotAtOnce() throws {
        let document = try makeDocument(pointSize: CGSize(width: 300, height: 200), scale: 1)
        let (controller, window) = try shownController(document)
        defer { window.orderOut(nil) }

        document.setCrop(CGRect(x: 20, y: 20, width: 200, height: 120))
        document.rotate(clockwise: true)
        XCTAssertTrue(document.undoManager?.canUndo ?? false, "both are steps of ⌘Z")
        XCTAssertFalse(controller.hasWork)

        controller.closeForQuitKey()

        XCTAssertFalse(window.isVisible)
    }

    /// With something drawn, a tap of ⌘Q asks first and leaves the window where it is.
    func testQuitKeyAsksBeforeThrowingAwayWork() throws {
        let document = try makeDocument(pointSize: CGSize(width: 300, height: 200), scale: 1)
        let (controller, window) = try shownController(document)
        defer { window.orderOut(nil) }
        let box = RectangleAnnotation(start: CGPoint(x: 10, y: 10), style: .default)
        box.update(to: CGPoint(x: 50, y: 30))
        document.add(box)

        controller.closeForQuitKey()

        XCTAssertTrue(window.isVisible)
        let sheet = try XCTUnwrap(window.attachedSheet, "asks before closing")
        window.endSheet(sheet, returnCode: .alertSecondButtonReturn)
    }

    /// A tap closes the window; held past it, the toast comes up with its bar filling; held to
    /// the end, Pawshot quits.
    func testQuitKeyTellsATapFromAHold() {
        XCTAssertEqual(QuitKey.phase(heldFor: .milliseconds(100)), .tap)
        XCTAssertEqual(QuitKey.phase(heldFor: .milliseconds(500)), .warning)
        XCTAssertEqual(QuitKey.phase(heldFor: .milliseconds(1300)), .quit)

        XCTAssertEqual(QuitKey.progress(heldFor: .milliseconds(300)), 0)
        XCTAssertEqual(QuitKey.progress(heldFor: .milliseconds(800)), 0.5, accuracy: 0.001)
        XCTAssertEqual(QuitKey.progress(heldFor: .seconds(5)), 1)
    }

    /// Windows of our own decide for themselves; any other closable window just closes; the
    /// capture overlay, with no close button, stays.
    func testQuitKeyPicksWhatToDoPerWindow() {
        let plain = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: true)
        XCTAssertEqual(QuitKey.action(for: plain), .performClose)

        let borderless = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        XCTAssertEqual(QuitKey.action(for: borderless), .nothing)
    }

    /// ⌘R turns the selected object when there is one, and the whole shot when there isn't.
    func testRotateRightTurnsTheSelectionOrTheShot() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let document = try makeDocument(pointSize: CGSize(width: 300, height: 200), scale: 1)
        let controller = EditorWindowController(document: document, on: screen)
        let box = RectangleAnnotation(start: CGPoint(x: 10, y: 10), style: .default)
        box.update(to: CGPoint(x: 50, y: 30))
        document.add(box)

        document.selection = box
        controller.rotateRight(nil)
        XCTAssertEqual(document.frameSize, CGSize(width: 300, height: 200), "only the object turned")
        XCTAssertEqual(box.rect.size, CGSize(width: 20, height: 40))

        document.selection = nil
        controller.rotateRight(nil)
        XCTAssertEqual(document.frameSize, CGSize(width: 200, height: 300), "nothing selected: the shot turned")
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
        // The tools, colours and style live in the capsules at the bottom now.
        XCTAssertGreaterThan(toolbar.items.count, 6, "turns, history, export")
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

    /// On a slow Mac the toolbar landed after the refit in `show()` and ate the bottom of the shot:
    /// the shot no longer fitted, and dragging the window's edge grew grey around it instead of
    /// the shot (a tester's M1, 2026-09-29). Shrinking the content outside a resize stands in for
    /// that late toolbar.
    func testShotRefitsWhenItsContentShrinksOutsideAResize() async throws {
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

        // Let the refit in `show()` run first: before it the height is already right, and a shrink
        // made then is undone by that refit — the test stayed green without the fix.
        try await Task.sleep(for: .milliseconds(300))
        let margin = EditorView.shotPadding * 2
        XCTAssertEqual(window.contentLayoutRect.height, 300 + margin, accuracy: 0.5)

        window.setContentSize(CGSize(width: window.contentLayoutRect.width, height: window.contentLayoutRect.height - 24))
        // Waits for the refit rather than for a guess at how long it takes; a slow run gets longer.
        for _ in 0 ..< 40 where abs(window.contentLayoutRect.height - (300 + margin)) > 0.5 {
            try await Task.sleep(for: .milliseconds(50))
        }

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
        for _ in 0 ..< 40 where abs(window.frame.midX - screen.visibleFrame.midX) > 1 || abs(window.frame.midY - screen.visibleFrame.midY) > 1 {
            try await Task.sleep(for: .milliseconds(50))
        }

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

    /// The first ⌘D of a fresh install compiles Vision's model for half a minute; Copy Text turns
    /// into a spinner after 300 ms and back once the reading is done.
    func testASlowReadingShowsASpinnerUntilItEnds() async throws {
        let stub = RecognitionStub()
        let controller = try makeReadingController(
            stub,
            pasteboard: NSPasteboard(name: NSPasteboard.Name("pawshot.tests.copytext.spinner"))
        )

        controller.copyText(nil)
        let reading = try XCTUnwrap(controller.textReadingTask)
        await waitUntilReadingStarts(stub)
        XCTAssertFalse(controller.isReadingText, "a quick reading shows nothing")
        let deadline = Date().addingTimeInterval(3)
        while !controller.isReadingText, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(controller.isReadingText)

        stub.finish(with: "hello")
        await reading.value
        XCTAssertFalse(controller.isReadingText)
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
