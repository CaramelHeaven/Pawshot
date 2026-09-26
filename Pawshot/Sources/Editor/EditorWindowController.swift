import AppKit
import os
import SwiftUI

/// The editor window: a SwiftUI toolbar on glass, the shot below it as a sheet of paper.
///
/// The window, the document, the canvas and every action stay here; `EditorView` only draws the
/// chrome and calls back through `EditorChromeModel`.
@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate, AnnotationCanvasDelegate {
    /// Live windows — otherwise nothing holds on to them once the method returns.
    private static var openControllers: Set<EditorWindowController> = []

    private let editorDocument: EditorDocument
    private let canvas: AnnotationCanvasView
    private let scrollView = NSScrollView()
    /// Where the window opens; `window.screen` can be `nil` until it is on screen.
    private let openingScreen: NSScreen
    private let editorUndoManager = UndoManager()
    private let chrome = EditorChromeModel()

    /// Set by ⌘C, ⌘S or ⌘D once the shot is handed off: the window is dissolving, and a second
    /// press in those 150 ms must not hand it off again.
    private var isClosing = false

    /// Which edges the current live resize is dragging, and the crop it started from. Both are
    /// `nil` while no resize is running.
    private var resizeEdges: ResizeEdges?
    private var cropBeforeResize: CGRect?
    private var frameBeforeResize: CGRect?
    /// The pixel size of the shot when the gesture began, for the "+48 px" chip.
    private var pixelSizeBeforeResize: CGSize?
    private var isAtResizeLimit = false

    /// The shot is read once while the window opens, so ⌘D has an answer waiting rather than a
    /// hundred milliseconds of work. It also moves the one-off compilation of the recognition
    /// model into the background — see the text-recognition section of `CLAUDE.md`; that price is
    /// paid once per signing identity, not once per session.
    ///
    /// The crop it was started from is kept alongside, because the answer only stands while the
    /// shot still looks the way it did — see `recognizedText()`.
    private var warmUpTask: Task<String, Error>?
    private var warmUpCrop: CGRect?

    /// The reading ⌘D asked for. Kept so a second press can be turned away while it runs, and so
    /// a closing window knows not to cancel work somebody is waiting for.
    private(set) var textReadingTask: Task<Void, Never>?

    /// Both have a working default and exist so the tests can watch ⌘D without the Neural Engine
    /// and without clobbering the owner's real clipboard — the same reason
    /// `ExportService.copy(_:to:)` takes a pasteboard.
    var recognizeText: (CGImage) async throws -> String = TextRecognitionService.text(for:)
    var pasteboard: NSPasteboard = .general

    init(document: EditorDocument, on screen: NSScreen) {
        openingScreen = screen
        editorDocument = document
        canvas = AnnotationCanvasView(document: document)

        let window = NSWindow(
            contentRect: CGRect(
                origin: .zero,
                size: Self.contentSize(for: document.imageSize, on: screen)
            ),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .unified

        super.init(window: window)

        editorDocument.undoManager = editorUndoManager
        canvas.delegate = self

        wireChrome()
        buildContentView()
        updateTitle()

        editorDocument.onCropChange = { [weak self] in
            self?.cropDidChange()
        }

        window.delegate = self
        window.setFrameOrigin(Self.origin(for: window, on: screen))
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is unused — the UI is built in code")
    }

    func show() {
        Self.openControllers.insert(self)
        NSApp.activate()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(canvas)

        syncChrome()
        startTextRecognitionWarmUp()

        // Once the SwiftUI toolbar is in, the window's final size is known: fit it to the shot,
        // centre it, and put the middle of a shot bigger than the window in view.
        Task { @MainActor [weak self] in
            guard let self, let window else { return }
            fitWindowToShot(onlyIfItFits: true)
            window.setFrameOrigin(Self.origin(for: window, on: window.screen ?? openingScreen))
            scrollToMiddleOfShot()
        }
    }

    /// A shot bigger than the window — a full-screen capture — would otherwise open on its top
    /// left corner. A shot that fits is centred by `CenteringClipView` anyway.
    private func scrollToMiddleOfShot() {
        let clip = scrollView.contentView
        let shot = canvas.frame.size
        let visible = clip.bounds.size
        guard shot.width > visible.width || shot.height > visible.height else { return }

        clip.scroll(to: CGPoint(
            x: max(0, (shot.width - visible.width) / 2),
            y: max(0, (shot.height - visible.height) / 2)
        ))
        scrollView.reflectScrolledClipView(clip)
    }

    // MARK: - Content

    private func buildContentView() {
        scrollView.contentView = CenteringClipView()
        scrollView.documentView = canvas
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .underPageBackgroundColor

        let hosting = NSHostingController(rootView: EditorView(model: chrome, scrollView: scrollView))
        // The window's size is ours: it follows the shot. Left to SwiftUI, the hosting view would
        // impose its own minimum and maximum and fight the resize logic below.
        hosting.sizingOptions = []
        // The SwiftUI `.toolbar` becomes this window's toolbar, glass and all.
        hosting.sceneBridgingOptions = [.toolbars]

        guard let window else { return }
        let size = window.contentLayoutRect.size
        hosting.view.frame = CGRect(origin: .zero, size: size)
        window.contentViewController = hosting
        window.setContentSize(size)
    }

    /// Every button of the toolbar lands on the same entry points as the keys.
    private func wireChrome() {
        chrome.selectTool = { [weak self] tool in
            self?.canvas.select(tool: tool)
            self?.returnFocusToCanvas()
        }
        chrome.pickColor = { [weak self] index in
            self?.editorDocument.updateStyle { style in
                style.color = AnnotationStyle.Palette.color(forKeyIndex: index, current: style.color)
            }
            self?.syncChrome()
            self?.returnFocusToCanvas()
        }
        chrome.pickLineWidth = { [weak self] width in
            self?.editorDocument.updateStyle { $0.lineWidth = width }
            self?.syncChrome()
            self?.returnFocusToCanvas()
        }
        chrome.toggleFill = { [weak self] in
            self?.editorDocument.updateStyle { $0.isFilled.toggle() }
            self?.syncChrome()
            self?.returnFocusToCanvas()
        }
        chrome.cycleTextStyle = { [weak self] in
            self?.editorDocument.updateStyle { $0.textStyle = $0.textStyle.next }
            self?.syncChrome()
            self?.returnFocusToCanvas()
        }
        chrome.undo = { [weak self] in self?.editorUndoManager.undo() }
        chrome.redo = { [weak self] in self?.editorUndoManager.redo() }
        chrome.clearAll = { [weak self] in self?.clearAll() }
        chrome.copy = { [weak self] in self?.copy(nil) }
        chrome.save = { [weak self] in self?.saveDocument(nil) }
        chrome.copyText = { [weak self] in self?.copyText(nil) }
    }

    /// The keys — tool letters, 1…6, [ ], Esc — are read by the canvas, so a click in the toolbar
    /// must not leave the focus anywhere else.
    private func returnFocusToCanvas() {
        window?.makeFirstResponder(canvas)
    }

    private func syncChrome() {
        chrome.style = editorDocument.style
        chrome.tool = canvas.tool
    }

    // MARK: - Actions

    /// No confirmation dialog — the owner's decision. The operation is undoable, so ⌘Z brings
    /// everything back.
    @objc func clearAll(_: Any? = nil) {
        editorDocument.removeAll()
    }

    // MARK: - Export

    /// The Edit → Copy item is already wired to `copy:`, and the responder chain finds this method
    /// on its own. While text is being typed, `NSTextView` intercepts `copy:` first — so ⌘C copies
    /// the text and not the picture. That is exactly how it should be.
    @objc func copy(_: Any?) {
        export(to: .clipboard)
    }

    @objc func saveDocument(_: Any?) {
        export(to: .desktop)
    }

    /// ⌘D: the text of the shot instead of the shot itself. Wired through Edit → Copy Text the
    /// same way ⌘S is, since an accessory app has no visible menu bar and the item is what carries
    /// the shortcut down the responder chain.
    @objc func copyText(_: Any?) {
        // ⌘D is a key somebody leans on, and reading a 5K shot is not free. A second press while
        // the first is still working used to start a second reading of the very same picture.
        guard textReadingTask == nil, !isClosing else { return }

        canvas.finishTextEditing()

        textReadingTask = Task {
            defer { textReadingTask = nil }

            let started = Date()
            do {
                let text = try await recognizedText()
                Self.logger.info("read \(Self.milliseconds(since: started)) ms, \(text.count) chars")

                guard !text.isEmpty else {
                    // Nothing to hand over, so nothing is taken away either: the clipboard keeps
                    // what it had and the window stays for another go.
                    if isStillOpen {
                        presentNoTextFound()
                    } else {
                        Self.logger.info("nothing readable, and the window had already gone")
                    }
                    return
                }

                // Deliberately not guarded by "is the window still open". ⌘D asks for the text,
                // not for the window, and closing the shot while the reading ran used to throw
                // away the very thing that was asked for.
                ExportService.copy(text: text, to: pasteboard)
                // The window is about to go, so the paw in the menu bar is the one thing left to
                // say the text arrived.
                AppState.shared.flashTextCopied()
                dissolveAndClose()
            } catch {
                Self.logger.error("read failed after \(Self.milliseconds(since: started)) ms: \(error.localizedDescription)")
                // An alert needs a window to hang off; a closed one gets the log line above.
                guard isStillOpen else { return }
                presentExportFailure(error)
            }
        }
    }

    /// `windowWillClose` is what takes the controller out of the set, so this is exact — unlike
    /// `window.isVisible`, which a miniaturised window also answers `false` to.
    private var isStillOpen: Bool {
        Self.openControllers.contains(self)
    }

    // MARK: - Text recognition

    private static let logger = Logger(subsystem: "com.caramelheaven.pawshot", category: "text")

    private static func milliseconds(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }

    /// Not private so a test can put the window into the state the owner actually hit: a ⌘D
    /// waiting on the warm-up when the window closes.
    func startTextRecognitionWarmUp() {
        let image = editorDocument.image
        warmUpCrop = editorDocument.cropRect

        warmUpTask = Task {
            let started = Date()
            let text = try await recognizeText(image)
            Self.logger.info("warm-up took \(Self.milliseconds(since: started)) ms")
            return text
        }
    }

    /// The warm-up read the bare shot, so its answer only stands while the shot is still bare: one
    /// blur over a password, and text that is no longer on screen would ride into the clipboard.
    /// Anything else is read fresh off the flattened picture — exactly what a ⌘S would write out.
    private func recognizedText() async throws -> String {
        if
            let warmUpTask,
            editorDocument.annotations.isEmpty,
            warmUpCrop == editorDocument.cropRect
        {
            return try await warmUpTask.value
        }

        guard let image = AnnotationRenderer.render(editorDocument) else {
            throw TextRecognitionError.renderFailed
        }

        return try await recognizeText(image)
    }

    /// Not an error, so not the failure alert — but not silence either. Closing the window here
    /// would leave whatever was on the clipboard before, and the shot would be gone with no way to
    /// tell that nothing had been read.
    private func presentNoTextFound() {
        let alert = NSAlert()
        alert.messageText = "No text found"
        alert.informativeText = "Nothing readable turned up in this shot — the clipboard is untouched."
        alert.alertStyle = .informational

        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    private enum ExportDestination {
        case clipboard
        case desktop
    }

    private func export(to destination: ExportDestination) {
        guard !isClosing else { return }
        canvas.finishTextEditing()

        guard let image = AnnotationRenderer.render(editorDocument) else {
            presentExportFailure(ExportError.encodingFailed)
            return
        }

        do {
            switch destination {
            case .clipboard:
                try ExportService.copy(image)
            case .desktop:
                try ExportService.saveToDesktop(image)
            }

            // No confirmation banner: the window dissolving is the confirmation. The shot is already
            // on the clipboard or on disk by now, so the fade costs the hand nothing.
            dissolveAndClose()
        } catch {
            presentExportFailure(error)
        }
    }

    /// ⌘C, ⌘S and ⌘D end here, after the hand-off has succeeded: the window fades out in 150 ms
    /// and closes. Mouse events pass through it straight away, so a click aimed at the app behind
    /// lands there. A window that isn't on screen closes at once — nothing to watch fade.
    private func dissolveAndClose() {
        guard !isClosing else { return }
        guard let window, window.isVisible else {
            close()
            return
        }

        isClosing = true
        window.ignoresMouseEvents = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Tokens.Motion.dissolve
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor in self?.close() }
        }
    }

    /// The window stays open: the work is not saved, and the user must be able to retry.
    private func presentExportFailure(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Couldn't hand off the shot"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning

        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    // MARK: - AnnotationCanvasDelegate

    func canvasDidChangeTool(_ canvas: AnnotationCanvasView) {
        chrome.tool = canvas.tool
    }

    func canvasDidChangeStyle(_: AnnotationCanvasView) {
        syncChrome()
    }

    func canvasDidRequestClose(_: AnnotationCanvasView) {
        close()
    }

    // MARK: - NSWindowDelegate

    /// Without this ⌘Z from the Edit menu won't find our undo manager.
    func windowWillReturnUndoManager(_: NSWindow) -> UndoManager? {
        editorUndoManager
    }

    func windowWillClose(_: Notification) {
        canvas.finishTextEditing()

        // The warm-up is speculative, and the shot it holds is worth tens of megabytes on a 5K
        // screen — but only while nobody wants it. A ⌘D in flight may be waiting on exactly this
        // task, and cancelling it there is how a requested reading used to die in silence.
        if textReadingTask == nil {
            warmUpTask?.cancel()
            warmUpTask = nil
        }

        Self.openControllers.remove(self)
    }

    // MARK: - Resizing the shot

    /// Which sides of the window the user grabbed. `windowWillResize(_:to:)` only reports a size,
    /// and the limit depends on the direction — dragging left stops at `crop.maxX`, dragging right
    /// at the far edge of the frame — so the edges are worked out once, from where the cursor was
    /// when the drag began.
    private struct ResizeEdges {
        var left = false
        var right = false
        var top = false
        var bottom = false

        var isEmpty: Bool {
            !left && !right && !top && !bottom
        }
    }

    func windowWillStartLiveResize(_: Notification) {
        resizeEdges = nil

        guard let window, canFollowResize else { return }

        let edges = Self.grabbedEdges(of: window, at: NSEvent.mouseLocation)
        // No edge under the cursor means this resize isn't ours to interpret — leave the window
        // alone rather than pin it to its current size.
        guard !edges.isEmpty else { return }

        resizeEdges = edges
        cropBeforeResize = editorDocument.cropRect
        frameBeforeResize = window.frame
        pixelSizeBeforeResize = pixelSize
        isAtResizeLimit = false
        // The blurred copy is expensive; keep the stale one until the gesture is over.
        editorDocument.blurSource.isFrozen = true
    }

    /// The shot follows the window only while it is fully visible. Once there is a scroller —
    /// after ⌘+, or on a region larger than the screen — dragging the window means "show more of
    /// what I already have", and quietly cropping pixels there would be a nasty surprise.
    private var canFollowResize: Bool {
        let content = scrollView.contentSize
        let shot = editorDocument.imageSize

        return shot.width <= content.width + 1 && shot.height <= content.height + 1
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard let edges = resizeEdges, !editorDocument.cropRect.isEmpty else { return frameSize }

        // Turn the proposed window size into the crop it implies, clamp that against the captured
        // frame, and turn it back. The window physically stops where the pixels end.
        let chrome = chromeSize(of: sender)
        let proposedShot = CGSize(
            width: frameSize.width - chrome.width,
            height: frameSize.height - chrome.height
        )
        let allowed = SelectionGeometry.resizedCrop(
            editorDocument.cropRect,
            by: Self.deltas(
                for: edges,
                width: proposedShot.width - editorDocument.cropRect.width,
                height: proposedShot.height - editorDocument.cropRect.height
            ),
            limitedTo: editorDocument.frameSize
        )

        // The window asked for more than the frame has — or less than the minimum side. Say so
        // once per contact, not on every mouse step that keeps pushing.
        let atLimit = abs(allowed.width - proposedShot.width) > 0.5
            || abs(allowed.height - proposedShot.height) > 0.5
        if atLimit, !isAtResizeLimit {
            self.chrome.noteDisplayEdgeHit()
        }
        isAtResizeLimit = atLimit
        self.chrome.resizeChip?.isAtDisplayEdge = atLimit

        return NSSize(
            width: allowed.width + chrome.width,
            height: allowed.height + chrome.height
        )
    }

    func windowDidResize(_ notification: Notification) {
        guard
            let window = notification.object as? NSWindow,
            let edges = resizeEdges,
            let previous = frameBeforeResize
        else { return }

        let current = window.frame
        frameBeforeResize = current

        // Window frames are AppKit's: y grows upwards. The shot's top edge is therefore the
        // window's maxY, and its bottom edge is the window's minY.
        var deltas = SelectionGeometry.CropEdgeDeltas()
        if edges.left {
            deltas.left = previous.minX - current.minX
        }
        if edges.right {
            deltas.right = current.maxX - previous.maxX
        }
        if edges.top {
            deltas.top = current.maxY - previous.maxY
        }
        if edges.bottom {
            deltas.bottom = previous.minY - current.minY
        }

        guard !deltas.isEmpty else { return }

        // Not undoable: every mouse step lands here, and one gesture must be one ⌘Z.
        // `windowDidEndLiveResize` registers the whole gesture at once.
        editorDocument.setCrop(SelectionGeometry.resizedCrop(
            editorDocument.cropRect,
            by: deltas,
            limitedTo: editorDocument.frameSize
        ), undoable: false)

        if let start = pixelSizeBeforeResize {
            chrome.resizeChip = ResizeChip(
                widthDelta: Int(pixelSize.width - start.width),
                heightDelta: Int(pixelSize.height - start.height),
                edges: ResizeChip.Edges(left: edges.left, right: edges.right, top: edges.top, bottom: edges.bottom),
                isAtDisplayEdge: isAtResizeLimit
            )
        }
    }

    func windowDidEndLiveResize(_: Notification) {
        defer {
            resizeEdges = nil
            cropBeforeResize = nil
            frameBeforeResize = nil
            pixelSizeBeforeResize = nil
            isAtResizeLimit = false
            chrome.resizeChip = nil
            // Recompute the blur once, now that the size has settled.
            editorDocument.blurSource.isFrozen = false
            canvas.needsDisplay = true
        }

        guard let start = cropBeforeResize else { return }
        editorDocument.registerCropUndo(from: start)
    }

    /// The crop changed: the canvas re-cuts the shot, then the window sizes itself to it. The
    /// window is skipped while a live resize is running — there the window is what moves first.
    private func cropDidChange() {
        canvas.documentCropDidChange()
        updateTitle()

        guard resizeEdges == nil else { return }
        fitWindowToShot()
    }

    /// Sizes the window to the shot plus the measured chrome. The window grows from its top left
    /// corner — the one AppKit keeps still — so undo of a resize puts the edges back where they were.
    ///
    /// `onlyIfItFits` is for the first layout: the SwiftUI toolbar lands in the window after it is
    /// shown and takes its height out of the content, so the shot is refitted once — unless the shot
    /// is bigger than the screen, where the window stays at its screen-sized frame and scrolls.
    private func fitWindowToShot(onlyIfItFits: Bool = false) {
        guard let window else { return }

        let chrome = chromeSize(of: window)
        let content = NSSize(
            width: editorDocument.imageSize.width + chrome.width,
            height: editorDocument.imageSize.height + chrome.height
        )
        var frame = window.frame
        frame.origin.y += frame.height - content.height
        frame.size = content

        if onlyIfItFits, let visible = window.screen?.visibleFrame, !visible.contains(frame) {
            return
        }
        window.setFrame(frame, display: true)
    }

    private func updateTitle() {
        window?.title = "\(editorDocument.image.width) × \(editorDocument.image.height)"
    }

    private var pixelSize: CGSize {
        CGSize(width: editorDocument.image.width, height: editorDocument.image.height)
    }

    /// Everything of the window that isn't the shot: the title bar with its toolbar and the margin
    /// around the paper.
    /// Measured rather than assumed — the title bar height isn't ours to hardcode.
    private func chromeSize(of window: NSWindow) -> CGSize {
        CGSize(
            width: window.frame.width - scrollView.contentSize.width,
            height: window.frame.height - scrollView.contentSize.height
        )
    }

    private static func grabbedEdges(of window: NSWindow, at mouse: CGPoint) -> ResizeEdges {
        let frame = window.frame
        let margin: CGFloat = 12
        var edges = ResizeEdges()

        edges.left = abs(mouse.x - frame.minX) <= margin
        edges.right = abs(mouse.x - frame.maxX) <= margin
        edges.top = abs(mouse.y - frame.maxY) <= margin
        edges.bottom = abs(mouse.y - frame.minY) <= margin

        return edges
    }

    /// Spreads a size change over the edges that are actually being dragged.
    private static func deltas(
        for edges: ResizeEdges,
        width: CGFloat,
        height: CGFloat
    ) -> SelectionGeometry.CropEdgeDeltas {
        var deltas = SelectionGeometry.CropEdgeDeltas()
        if edges.left {
            deltas.left = width
        } else if edges.right {
            deltas.right = width
        }
        if edges.top {
            deltas.top = height
        } else if edges.bottom {
            deltas.bottom = height
        }

        return deltas
    }

    // MARK: - Window geometry

    /// The window must not run off the screen: for a large shot we take as much of the visible
    /// area as we can.
    private static func contentSize(for imageSize: CGSize, on screen: NSScreen) -> CGSize {
        let visible = screen.visibleFrame.size
        // The toolbar sits outside the content rect; the margin around the paper is inside it.
        let margin = EditorView.shotPadding * 2
        let chrome = CGSize(width: margin, height: margin)

        return CGSize(
            width: min(imageSize.width + chrome.width, visible.width - 80),
            height: min(imageSize.height + chrome.height, visible.height - 80)
        )
    }

    /// The middle of the visible part of the screen the shot was taken on — the owner's choice:
    /// the editor always turns up in the same place, wherever on the screen the selection was.
    private static func origin(for window: NSWindow, on screen: NSScreen) -> CGPoint {
        let visible = screen.visibleFrame
        let size = window.frame.size

        let x = min(max(visible.minX, visible.midX - size.width / 2), max(visible.minX, visible.maxX - size.width))
        let y = min(max(visible.minY, visible.midY - size.height / 2), max(visible.minY, visible.maxY - size.height))

        return CGPoint(x: x.rounded(), y: y.rounded())
    }
}
