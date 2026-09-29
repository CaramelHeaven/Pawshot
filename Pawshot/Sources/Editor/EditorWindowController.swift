import AppKit
import os
import SwiftUI

/// The editor window: a SwiftUI toolbar on glass, the shot below it as a sheet of paper.
///
/// The window, the document, the canvas and every action stay here; `EditorView` only draws the
/// chrome and calls back through `EditorChromeModel`.
@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate, AnnotationCanvasDelegate, ClosesOnQuitKey {
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
        // The size stands in the middle of the toolbar instead; the title stays for Mission
        // Control and the Window menu.
        window.titleVisibility = .hidden

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

    /// Since 0.4.2 the overlay no longer activates Pawshot, so the editor usually opens while
    /// another app is active, and activation asked for by a background app may come late or never
    /// — the video editor's window once turned up behind other apps that way. In a tester's log it
    /// came 150–190 ms later every time, so this only looks, half a second on.
    private func checkActivation() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let window = self?.window, window.isVisible else { return }
            let active = NSApp.isActive
            let key = window.isKeyWindow
            if key {
                Self.editorLogger.notice("editor after 500 ms: app active \(active, privacy: .public), window key true")
            } else {
                Self.editorLogger.error("editor after 500 ms: app active \(active, privacy: .public), window key false — not in front?")
            }
        }
    }

    func show() {
        Self.openControllers.insert(self)
        NSApp.activate()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        let active = NSApp.isActive
        let key = window?.isKeyWindow ?? false
        Self.editorLogger.notice("editor shown: app active \(active, privacy: .public), window key \(key, privacy: .public), \(Self.openControllers.count) open")
        window?.makeFirstResponder(canvas)
        checkActivation()

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
            guard let self else { return }
            let palette = AnnotationStyle.Palette.self
            let color = palette.colors.indices.contains(index) ? palette.colors[index] : Settings.shared.customColor
            editorDocument.updateStyle { $0.color = color }
            syncChrome()
            returnFocusToCanvas()
        }
        chrome.pickCustomColor = { [weak self] color in
            Settings.shared.pickCustomColor(color)
            self?.editorDocument.updateStyle { $0.color = color }
            self?.syncChrome()
        }
        chrome.pickLineWidth = { [weak self] width in
            self?.editorDocument.updateStyle { $0.lineWidth = width }
            self?.syncChrome()
            self?.returnFocusToCanvas()
        }
        chrome.cycleFill = { [weak self] in
            self?.editorDocument.updateStyle {
                $0.fillOpacity = AnnotationStyle.FillOpacity.next(after: $0.fillOpacity)
            }
            self?.syncChrome()
            self?.returnFocusToCanvas()
        }
        chrome.setFillOpacity = { [weak self] opacity in
            guard let self else { return }
            let isText = chrome.showsTextControls
            editorDocument.updateStyle { AnnotationStyle.setFillOpacity(opacity, onText: isText, of: &$0) }
            syncChrome()
        }
        chrome.previewFillOpacity = { [weak self] opacity in
            guard let self else { return }
            let isText = chrome.showsTextControls
            editorDocument.previewStyle { AnnotationStyle.setFillOpacity(opacity, onText: isText, of: &$0) }
            syncChrome()
        }
        chrome.cycleTextStyle = { [weak self] in
            self?.editorDocument.updateStyle(AnnotationStyle.nextTextStyle)
            self?.syncChrome()
            self?.returnFocusToCanvas()
        }
        chrome.pickLineEnds = { [weak self] ends in
            self?.editorDocument.updateStyle { $0.lineEnds = ends }
            self?.syncChrome()
            self?.returnFocusToCanvas()
        }
        chrome.pickShapeKind = { [weak self] kind in
            self?.editorDocument.updateStyle { $0.shapeKind = kind }
            self?.syncChrome()
            self?.returnFocusToCanvas()
        }
        chrome.pickTextWeight = { [weak self] weight in
            self?.editorDocument.updateStyle { $0.textWeight = weight }
            self?.syncChrome()
            self?.returnFocusToCanvas()
        }
        chrome.reportShotFrame = { [weak self] frame in
            self?.shotInSwiftUI = frame
            self?.updateCursorExclusion()
        }
        chrome.reportToolsFrame = { [weak self] frame in
            self?.toolsInSwiftUI = frame
            self?.updateCursorExclusion()
        }
        chrome.rotate = { [weak self] clockwise in
            clockwise ? self?.rotateRight(nil) : self?.rotateLeft(nil)
            self?.returnFocusToCanvas()
        }
        chrome.undo = { [weak self] in
            guard let manager = self?.editorUndoManager, manager.canUndo else { return }
            Stats.shared.add(.undos)
            manager.undo()
        }
        chrome.redo = { [weak self] in self?.editorUndoManager.redo() }
        chrome.clearAll = { [weak self] in self?.clearAll() }
        chrome.copy = { [weak self] in self?.copy(nil) }
        chrome.save = { [weak self] in self?.saveDocument(nil) }
        chrome.copyText = { [weak self] in self?.copyText(nil) }
    }

    private var shotInSwiftUI: CGRect?
    private var toolsInSwiftUI: CGRect?

    /// The floating tools' frame on the window, for the canvas to leave the cursor to them.
    private func updateCursorExclusion() {
        guard let tools = toolsInSwiftUI, let shot = shotInSwiftUI else {
            canvas.cursorExclusion = nil
            return
        }
        canvas.cursorExclusion = SelectionGeometry.windowRect(
            fromSwiftUI: tools,
            shotInSwiftUI: shot,
            shotInWindow: scrollView.convert(scrollView.bounds, to: nil)
        )
    }

    /// The keys — tool letters, 1…6, [ ], Esc — are read by the canvas, so a click in the toolbar
    /// must not leave the focus anywhere else.
    private func returnFocusToCanvas() {
        window?.makeFirstResponder(canvas)
    }

    /// Assigns only what changed: this runs on every document change, a drag included, and each
    /// assignment redraws the toolbar.
    private func syncChrome() {
        let selection = editorDocument.selection
        let style = selection?.style ?? editorDocument.style
        if chrome.style != style {
            chrome.style = style
        }
        let kind = selection.map(AnnotationTool.drawing)
        if chrome.selectedKind != kind {
            chrome.selectedKind = kind
        }
        let shapeKind = editorDocument.style.shapeKind
        if chrome.drawingShapeKind != shapeKind {
            chrome.drawingShapeKind = shapeKind
        }
        // The size after a crop or a turn, in the middle of the toolbar.
        if chrome.pixelSize != pixelSize {
            chrome.pixelSize = pixelSize
        }
        let weights = LabelFont.weights(of: LabelFont.family)
        if chrome.textWeights != weights {
            chrome.textWeights = weights
        }
        if chrome.tool != canvas.tool {
            chrome.tool = canvas.tool
        }
        let settings = Settings.shared
        if chrome.customColor != settings.customColor {
            chrome.customColor = settings.customColor
        }
        let recent = settings.recentColors
        if chrome.recentColors != recent {
            chrome.recentColors = recent
        }
    }

    // MARK: - Actions

    /// No confirmation dialog — the owner's decision. The operation is undoable, so ⌘Z brings
    /// everything back.
    @objc func clearAll(_: Any? = nil) {
        editorDocument.removeAll()
    }

    /// ⌘L and ⌘R, as in Preview: with something selected, that object turns a quarter about its
    /// own centre; with nothing selected, the shot turns with everything drawn on it. A label
    /// being typed is finished first — it turns as a finished label.
    @objc func rotateLeft(_: Any?) {
        rotate(clockwise: false)
    }

    @objc func rotateRight(_: Any?) {
        rotate(clockwise: true)
    }

    private func rotate(clockwise: Bool) {
        canvas.finishTextEditing()
        if editorDocument.selection != nil {
            editorDocument.rotateSelection(clockwise: clockwise)
        } else {
            editorDocument.rotate(clockwise: clockwise)
        }
    }

    // MARK: - Export

    /// The Edit → Copy item is already wired to `copy:`, and the responder chain finds this method
    /// on its own. While text is being typed, `NSTextView` intercepts `copy:` first — so ⌘C copies
    /// the text and not the picture. That is exactly how it should be.
    @objc func copy(_: Any?) {
        export(to: .clipboard)
    }

    @objc func saveDocument(_: Any?) {
        export(to: .folder)
    }

    /// ⇧⌘S: a name, a folder and a format picked once, in the system's save sheet. The folder and
    /// format in Settings stay as they are.
    @objc func saveDocumentAs(_: Any?) {
        guard let window, !isClosing else { return }
        canvas.finishTextEditing()
        let settings = Settings.shared
        let panel = NSSavePanel()
        panel.directoryURL = settings.saveFolder
        panel.nameFieldStringValue = ExportNaming.fileName(extension: settings.imageFormat.fileExtension)
        panel.allowedContentTypes = [settings.imageFormat.type]
        panel.canCreateDirectories = true
        let picker = SaveFormatPicker(initial: settings.imageFormat) { [weak panel] format in
            panel?.allowedContentTypes = [format.type]
        }
        panel.accessoryView = NSHostingView(rootView: picker)
        Self.editorLogger.notice("save as: sheet opened")
        panel.beginSheetModal(for: window) { [weak self, weak panel] response in
            guard response == .OK, let panel, let url = panel.url else {
                Self.editorLogger.notice("save as: cancelled")
                return
            }
            // The picker keeps the panel's one allowed type in step with the format it shows.
            let format = ImageFormat.allCases.first { $0.type == panel.allowedContentTypes.first } ?? settings.imageFormat
            self?.export(to: .file(url, format))
        }
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
                Self.logger.notice("read \(Self.milliseconds(since: started)) ms, \(text.count) chars")

                guard !text.isEmpty else {
                    // Nothing to hand over, so nothing is taken away either: the clipboard keeps
                    // what it had and the window stays for another go.
                    if isStillOpen {
                        presentNoTextFound()
                    } else {
                        Self.logger.notice("nothing readable, and the window had already gone")
                    }
                    return
                }

                // Deliberately not guarded by "is the window still open". ⌘D asks for the text,
                // not for the window, and closing the shot while the reading ran used to throw
                // away the very thing that was asked for.
                ExportService.copy(text: text, to: pasteboard)
                Stats.shared.add(.recognizedCharacters, text.count)
                // The window is about to go, so the paw in the menu bar is the one thing left to
                // say the text arrived.
                AppState.shared.flashTextCopied()
                dissolveAndClose()
            } catch {
                Self.logger.error("read failed after \(Self.milliseconds(since: started)) ms: \(String(describing: error), privacy: .public)")
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

    private static var logger: Logger {
        .pawshot("text")
    }

    private static var editorLogger: Logger {
        .pawshot("editor")
    }

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
            Self.logger.notice("warm-up took \(Self.milliseconds(since: started)) ms")
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
        alert.messageText = String(localized: "No text found")
        alert.informativeText = String(localized: "Nothing readable turned up in this shot — the clipboard is untouched.")
        alert.alertStyle = .informational

        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    private enum ExportDestination {
        case clipboard
        /// The folder and format in Settings.
        case folder
        /// Save As…: this file, in this format.
        case file(URL, ImageFormat)
    }

    private func export(to destination: ExportDestination) {
        guard !isClosing else {
            Self.editorLogger.notice("export ignored: the window is already closing")
            return
        }
        canvas.finishTextEditing()

        let started = Date()
        guard let image = AnnotationRenderer.render(editorDocument) else {
            Self.editorLogger.error("export: rendering the shot failed")
            presentExportFailure(ExportError.encodingFailed)
            return
        }

        do {
            switch destination {
            case .clipboard:
                try ExportService.copy(image)
                Self.editorLogger.notice("copied \(image.width)×\(image.height) px in \(Self.milliseconds(since: started)) ms")
            case .folder:
                let settings = Settings.shared
                let url = try ExportService.save(image, to: settings.saveFolder, format: settings.imageFormat)
                Self.editorLogger.notice("saved \(image.width)×\(image.height) px to \(url.path, privacy: .public) in \(Self.milliseconds(since: started)) ms")
            case let .file(url, format):
                try ExportService.write(image, to: url, format: format)
                Self.editorLogger.notice("saved as \(image.width)×\(image.height) px to \(url.path, privacy: .public) in \(Self.milliseconds(since: started)) ms")
            }

            // No confirmation banner: the window dissolving is the confirmation. The shot is already
            // on the clipboard or on disk by now, so the fade costs the hand nothing.
            dissolveAndClose()
        } catch {
            Self.editorLogger.error("export failed: \(String(describing: error), privacy: .public)")
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
        alert.messageText = String(localized: "Couldn't hand off the shot")
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

    /// A tap of ⌘Q. A shot with something drawn on it asks first; any other closes at once —
    /// growing, cropping or turning it alone is not work worth a question (the owner's call).
    func closeForQuitKey() {
        guard hasWork, let window else {
            Self.editorLogger.notice("⌘Q tap: bare shot, closing")
            close()
            return
        }
        Self.editorLogger.notice("⌘Q tap: the shot has work, asking")
        let alert = NSAlert()
        alert.messageText = String(localized: "Close the screenshot?")
        alert.informativeText = String(localized: "What is drawn on it will be lost.")
        let close = alert.addButton(withTitle: String(localized: "Close"))
        close.hasDestructiveAction = true
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            let closes = response == .alertFirstButtonReturn
            Self.editorLogger.notice("⌘Q tap: \(closes ? "close" : "cancel", privacy: .public) chosen")
            guard closes else { return }
            self?.close()
        }
    }

    /// Something is drawn on the shot. Drawn and then erased is nothing.
    var hasWork: Bool {
        !editorDocument.annotations.isEmpty
    }

    /// The labels' family changed in Settings: every open editor re-sets its labels right away.
    static func labelFontDidChange() {
        for controller in openControllers {
            controller.canvas.finishTextEditing()
            controller.editorDocument.labelFontDidChange()
            controller.syncChrome()
        }
    }

    /// The tools moved between under the shot and over it: SwiftUI redraws the content by itself,
    /// and once it has laid out, every open window refits, so the shot is whole again with or
    /// without the strip.
    static func toolsPlacementDidChange() {
        DispatchQueue.main.async {
            for controller in openControllers {
                controller.window?.contentView?.layoutSubtreeIfNeeded()
                controller.fitWindowToShot()
            }
        }
    }

    func canvasDidRequestCustomColor(_: AnnotationCanvasView) {
        chrome.pickColor(AnnotationStyle.Palette.customIndex)
    }

    // MARK: - NSWindowDelegate

    /// Without this ⌘Z from the Edit menu won't find our undo manager.
    func windowWillReturnUndoManager(_: NSWindow) -> UndoManager? {
        editorUndoManager
    }

    func windowWillClose(_: Notification) {
        let work = hasWork
        Self.editorLogger.notice("editor closed, had work: \(work, privacy: .public)")
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
        syncChrome()

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

        if let visible = window.screen?.visibleFrame, !visible.contains(frame) {
            if onlyIfItFits {
                return
            }
            // A turned full-screen shot is taller than the screen: the window stops at the screen
            // and the shot scrolls inside it, as a big shot does when it opens.
            frame.size.width = min(frame.width, visible.width)
            frame.size.height = min(frame.height, visible.height)
            frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
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
