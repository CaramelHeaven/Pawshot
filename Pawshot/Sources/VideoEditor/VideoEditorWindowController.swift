import AppKit
import AVFoundation
import Carbon.HIToolbox
import os
import SwiftUI

/// The window a recording opens in when it stops: watch it, keep the pieces worth keeping, pick
/// the format, hand it off.
///
/// Like the screenshot editor, AppKit owns the window and SwiftUI draws the inside. The rules are
/// the screenshot's too: ⌘C, ⇧⌘C and ⌘S hand the video off and the window dissolves; closing it any
/// other way throws the recording away. An export keeps running after its window is gone and still
/// delivers — the take is not lost to an impatient ⌘W.
@MainActor
final class VideoEditorWindowController: NSWindowController, NSWindowDelegate {
    private static let logger = Logger(subsystem: "com.caramelheaven.pawshot", category: "video")

    /// Alive until the window is closed and its export, if any, has finished.
    private static var openControllers: Set<VideoEditorWindowController> = []

    let movieURL: URL
    let model: VideoEditorModel
    /// The recording itself: what is shown paused and while editing. It only ever seeks.
    private let player: AVPlayer
    /// The export's splice of the pieces: what plays.
    private let splicePlayer = AVPlayer()
    private let openingScreen: NSScreen
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    /// Building the splice and seeking it, between Space and the first frame.
    private var playTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    private var estimateTask: Task<Void, Never>?
    private var isClosing = false
    private var windowIsClosed = false
    /// The pieces' history for ⌘Z. The editor's own, not the window's: an `NSHostingView` as the
    /// content would otherwise hand the window a manager nobody registers into.
    let piecesUndoManager = UndoManager()

    init(movieURL: URL, videoSize: CGSize, on screen: NSScreen) {
        self.movieURL = movieURL
        openingScreen = screen
        model = VideoEditorModel(videoSize: videoSize, preset: Settings.shared.videoPreset)
        model.timeline = EventTimeline.load(nextTo: movieURL)
        let settings = Settings.shared
        model.effects = EffectsOptions(clicks: settings.showsClicks, keys: true, zooms: settings.showsZooms)
        model.showsHints = settings.videoEditorOpenCount < 5
        player = AVPlayer(url: movieURL)

        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: Self.contentSize(for: videoSize, on: screen)),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.title = "Recording"
        window.minSize = CGSize(width: 520, height: 360)

        super.init(window: window)

        let host = KeyHostingView(rootView: VideoEditorView(
            model: model,
            player: player,
            splicePlayer: splicePlayer,
            actions: actions
        ))
        host.onKey = { [weak self] event in self?.handleKey(event) ?? false }
        host.onCancel = { [weak self] in self?.close() }
        host.contentUndoManager = piecesUndoManager
        window.contentView = host
        window.initialFirstResponder = host
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is unused — the UI is built in code")
    }

    func show() {
        Self.openControllers.insert(self)
        Settings.shared.recordVideoEditorOpen()
        guard let window else { return }
        window.setFrameOrigin(Self.origin(for: window, on: openingScreen))
        NSApp.activate()
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        // After a recording another app is in front, and macOS's cooperative activation may not
        // hand it over to a background utility — then `makeKeyAndOrderFront` only puts the
        // window on top of Pawshot's own, behind everything else. This puts it above the other
        // apps' windows whether or not the activation went through.
        window.orderFrontRegardless()
        window.makeFirstResponder(window.contentView)

        observeTime()
        Task { await load() }
    }

    private var actions: VideoEditorActions {
        VideoEditorActions(
            togglePlay: { [weak self] in self?.togglePlay() },
            seek: { [weak self] in self?.seek(to: $0) },
            editKeep: { [weak self] in self?.editKeep($0) },
            commitKeep: { [weak self] in self?.commitKeep(before: $0) },
            selectPiece: { [weak self] in self?.model.selectedPiece = $0 },
            cyclePreset: { [weak self] in self?.cyclePreset() },
            copy: { [weak self] in self?.copy(nil) },
            save: { [weak self] in self?.saveDocument(nil) },
            setEffects: { [weak self] in self?.setEffects($0) }
        )
    }

    // MARK: - Loading

    private func load() async {
        let asset = AVURLAsset(url: movieURL)
        guard let duration = try? await asset.load(.duration).seconds, duration > 0 else { return }
        model.keep = KeepRanges(duration: duration)
        window?.title = "Recording · \(VideoEditing.durationText(duration))"
        refreshEstimate()
        await loadThumbnails(of: asset, duration: duration)
    }

    private func loadThumbnails(of asset: AVURLAsset, duration: TimeInterval) async {
        let count = 12
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 0, height: 104)
        let times = (0 ..< count).map {
            CMTime(seconds: duration * (Double($0) + 0.5) / Double(count), preferredTimescale: 600)
        }

        var images: [CGImage] = []
        for await result in generator.images(for: times) {
            if let image = try? result.image {
                images.append(image)
            }
        }
        model.thumbnails = images
    }

    // MARK: - Playback

    private func observeTime() {
        let interval = CMTime(value: 1, timescale: 30)
        timeObserver = splicePlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.spliceTimeDidChange(time.seconds) }
        }
    }

    /// The playhead on the strip is in the recording's time; the splice runs on the file's.
    private func spliceTimeDidChange(_ seconds: TimeInterval) {
        guard model.isPlaying, model.showsSplice, let keep = model.spliceKeep else { return }
        model.currentTime = keep.sourceTime(forOutput: seconds)
    }

    /// Playback plays what the file will be — the export's own splice, so no frame of the grey
    /// gets through between pieces. After the last one it stops at the start of the first.
    private func togglePlay() {
        if model.isPlaying || playTask != nil {
            stopPlayback()
            return
        }
        let keep = model.keep
        var start = keep.nextPlayableTime(after: model.currentTime) ?? keep.first.start
        // At the very end of a piece there is nothing left to play in it: on to the next one,
        // or back to the beginning after the last.
        if let index = keep.piece(containing: start), keep.pieces[index].end - start < 0.05 {
            start = keep.nextPlayableTime(after: keep.pieces[index].end) ?? keep.first.start
        }
        guard let output = keep.outputTime(forSource: start) else { return }

        let source = movieURL
        playTask = Task { [weak self] in
            guard let self else { return }
            if model.spliceKeep != keep {
                guard
                    let item = try? await VideoExporter.previewItem(source: source, keep: keep),
                    !Task.isCancelled
                else { return finishStarting() }
                splicePlayer.replaceCurrentItem(with: item)
                observeEnd(of: item)
                model.spliceKeep = keep
            }
            await splicePlayer.seek(to: Self.time(output), toleranceBefore: .zero, toleranceAfter: .zero)
            guard !Task.isCancelled else { return }
            finishStarting()
            model.currentTime = start
            model.isPlaying = true
            model.showsSplice = true
            splicePlayer.play()
        }
    }

    /// A cancelled start has been replaced already; only a live one clears its handle.
    private func finishStarting() {
        if !Task.isCancelled {
            playTask = nil
        }
    }

    private func observeEnd(of item: AVPlayerItem) {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.stopPlayback(at: self.model.keep.first.start)
            }
        }
    }

    /// Back to the recording, on the frame playback got to (or on `time`). The splice stays on
    /// screen until the recording has that frame ready — switching earlier would flash.
    private func stopPlayback(at time: TimeInterval? = nil) {
        playTask?.cancel()
        playTask = nil
        splicePlayer.pause()
        let wasPlaying = model.isPlaying
        model.isPlaying = false
        guard wasPlaying || time != nil else { return }

        let target = time ?? model.spliceKeep.map {
            $0.sourceTime(forOutput: splicePlayer.currentTime().seconds)
        } ?? model.currentTime
        model.currentTime = target
        Task { [weak self] in
            guard let self else { return }
            await player.seek(to: Self.time(target), toleranceBefore: .zero, toleranceAfter: .zero)
            if !model.isPlaying {
                model.showsSplice = false
            }
        }
    }

    /// Scrubbing: the recording always follows; the splice too while it plays, unless the time
    /// is in the grey — the splice has nothing there, so playback stops on that frame.
    private func seek(to time: TimeInterval) {
        guard model.isPlaying else {
            model.currentTime = time
            player.seek(to: Self.time(time), toleranceBefore: .zero, toleranceAfter: .zero)
            return
        }
        if let keep = model.spliceKeep, keep == model.keep, let output = keep.outputTime(forSource: time) {
            model.currentTime = time
            splicePlayer.seek(to: Self.time(output), toleranceBefore: .zero, toleranceAfter: .zero)
            player.seek(to: Self.time(time), toleranceBefore: .zero, toleranceAfter: .zero)
        } else {
            stopPlayback(at: time)
        }
    }

    private static func time(_ seconds: TimeInterval) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    // MARK: - Pieces and format

    /// The pieces while a hand is on them: shown at once, not yet a step of ⌘Z.
    func editKeep(_ keep: KeepRanges) {
        // The splice playing is of the old pieces.
        if model.isPlaying || playTask != nil {
            stopPlayback()
        }
        model.keep = keep
        if let selected = model.selectedPiece, !keep.pieces.indices.contains(selected) {
            model.selectedPiece = nil
        }
        refreshEstimate()
    }

    /// The hand let go: what the pieces were before is one step back.
    func commitKeep(before: KeepRanges) {
        registerUndo(restoring: before)
    }

    /// ⌫: the selected piece goes, unless it is the only one.
    private func removeSelectedPiece() -> Bool {
        guard let selected = model.selectedPiece else { return false }
        var keep = model.keep
        guard keep.remove(at: selected) else { return false }
        let before = model.keep
        model.selectedPiece = nil
        editKeep(keep)
        registerUndo(restoring: before)
        return true
    }

    /// Undo puts `keep` back and registers the way forward again, so ⇧⌘Z works too.
    private func registerUndo(restoring keep: KeepRanges) {
        piecesUndoManager.registerUndo(withTarget: self) { controller in
            MainActor.assumeIsolated {
                let current = controller.model.keep
                controller.model.selectedPiece = nil
                controller.editKeep(keep)
                controller.registerUndo(restoring: current)
            }
        }
    }

    private func cyclePreset() {
        model.preset = model.preset.next
        Settings.shared.videoPreset = model.preset
        refreshEstimate()
    }

    private func setEffects(_ effects: EffectsOptions) {
        model.effects = effects
    }

    /// Asked again after every change, a moment after the hand stops: dragging a bracket would
    /// otherwise start dozens of estimates.
    private func refreshEstimate() {
        estimateTask?.cancel()
        let source = movieURL
        let keep = model.keep
        let preset = model.preset
        estimateTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let bytes = await VideoExporter.estimatedSize(source: source, keep: keep, preset: preset)
            guard !Task.isCancelled else { return }
            self?.model.estimatedBytes = bytes
        }
    }

    // MARK: - Keys

    /// Space plays, ⌫ removes the selected piece, P changes the format — the letter read off the
    /// physical key, as everywhere.
    func handleKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        switch Int(event.keyCode) {
        case kVK_Space:
            togglePlay()
            return true
        case kVK_Delete, kVK_ForwardDelete:
            return removeSelectedPiece()
        default:
            break
        }
        guard KeyboardLayout.latinCharacter(for: event)?.lowercased() == "p" else { return false }
        cyclePreset()
        return true
    }

    // MARK: - Hand-off

    private enum Destination {
        case clipboard
        case desktop
    }

    /// ⌘C: the file in the chosen format.
    @objc func copy(_: Any?) {
        export(model.preset, to: .clipboard)
    }

    /// ⇧⌘C: a GIF, whatever format is chosen.
    @objc func copyGIF(_: Any?) {
        export(.gif, to: .clipboard)
    }

    /// ⌘S: to the Desktop, in the chosen format.
    @objc func saveDocument(_: Any?) {
        export(model.preset, to: .desktop)
    }

    private func export(_ preset: VideoPreset, to destination: Destination) {
        guard exportTask == nil, !isClosing, model.keep.duration > 0 else { return }
        stopPlayback()

        let url: URL
        do {
            url = try destination == .desktop ? VideoHandOff.desktopURL(for: preset) : VideoHandOff.clipURL(for: preset)
        } catch {
            presentFailure(error)
            return
        }

        model.exportProgress = 0
        model.exportStarted = Date()
        let source = movieURL
        let keep = model.keep
        let timeline = model.timeline
        let effects = model.effects
        let started = Date()
        exportTask = Task { [weak self] in
            do {
                try await VideoExporter.export(
                    source: source, keep: keep, preset: preset, to: url, timeline: timeline, effects: effects
                ) { value in
                    Task { @MainActor in self?.model.exportProgress = value }
                }
                if destination == .clipboard {
                    VideoHandOff.copy(url)
                }
                let elapsed = Int(Date().timeIntervalSince(started) * 1000)
                Self.logger.info("exported \(preset.rawValue, privacy: .public) in \(elapsed, privacy: .public) ms")
                self?.exportDidFinish(nil)
            } catch {
                self?.exportDidFinish(error)
            }
        }
    }

    private func exportDidFinish(_ error: Error?) {
        exportTask = nil
        model.exportProgress = nil
        model.exportStarted = nil

        if let error {
            Self.logger.error("export failed: \(error.localizedDescription, privacy: .public)")
            presentFailure(error)
            if windowIsClosed {
                discard()
            }
            return
        }

        if windowIsClosed {
            discard()
        } else {
            dissolveAndClose()
        }
    }

    /// The window fades out in 150 ms, the same as the screenshot editor's after ⌘C.
    private func dissolveAndClose() {
        guard !isClosing, let window, window.isVisible else {
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

    private func presentFailure(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Couldn't hand off the recording"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        if let window, window.isVisible {
            alert.beginSheetModal(for: window)
        } else {
            NSApp.activate()
            alert.runModal()
        }
    }

    // MARK: - Closing

    func windowWillClose(_: Notification) {
        windowIsClosed = true
        stopPlayback()
        if let timeObserver {
            splicePlayer.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
        estimateTask?.cancel()

        // An export still running delivers first and cleans up after itself.
        if exportTask == nil {
            discard()
        }
    }

    /// The raw recording goes: it was either exported or thrown away — the owner's rule, the same
    /// as for a screenshot closed without ⌘C or ⌘S.
    private func discard() {
        try? FileManager.default.removeItem(at: movieURL)
        try? FileManager.default.removeItem(at: EventTimeline.url(forMovie: movieURL))
        Self.openControllers.remove(self)
    }

    // MARK: - Geometry

    /// The video at up to 70 % of the screen width and 60 % of its height, plus the strip and
    /// the footer under it.
    private static func contentSize(for videoSize: CGSize, on screen: NSScreen) -> CGSize {
        let visible = screen.visibleFrame.size
        let chrome = CGSize(width: 32, height: 32 + 12 + 52 + 12 + 32 + 28)
        guard videoSize.width > 0, videoSize.height > 0 else { return CGSize(width: 800, height: 600) }

        let aspect = videoSize.width / videoSize.height
        var width = min(visible.width * 0.7, max(520, videoSize.width / 2))
        var height = width / aspect
        let maxHeight = visible.height * 0.6
        if height > maxHeight {
            height = maxHeight
            width = height * aspect
        }
        return CGSize(width: max(520, width + chrome.width), height: height + chrome.height)
    }

    private static func origin(for window: NSWindow, on screen: NSScreen) -> CGPoint {
        let visible = screen.visibleFrame
        let size = window.frame.size
        return CGPoint(
            x: (visible.midX - size.width / 2).rounded(),
            y: (visible.midY - size.height / 2).rounded()
        )
    }
}

/// A hosting view that hears the keys SwiftUI would let fall — Space, ⌫, P, Esc — and answers
/// ⌘Z itself: first in the responder chain, it gets `undo:` before the window, whose own manager
/// the editor never registers into.
final class KeyHostingView<Content: View>: NSHostingView<Content>, NSMenuItemValidation {
    var onKey: ((NSEvent) -> Bool)?
    var onCancel: (() -> Void)?
    var contentUndoManager: UndoManager?

    @objc func undo(_: Any?) {
        contentUndoManager?.undo()
    }

    @objc func redo(_: Any?) {
        contentUndoManager?.redo()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)): contentUndoManager?.canUndo ?? false
        case #selector(redo(_:)): contentUndoManager?.canRedo ?? false
        default: true
        }
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func keyDown(with event: NSEvent) {
        if onKey?(event) == true {
            return
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_: Any?) {
        onCancel?()
    }
}
