import AppKit
import AVFoundation
import Carbon.HIToolbox
import os
import ScreenCaptureKit

/// What to record: a display, a part of it, or one window.
struct RecordingTarget {
    let displayID: CGDirectDisplayID
    /// The region in global CoreGraphics coordinates, in points. `nil` records the whole display.
    /// For a window, its frame — only to place the pill by.
    let rect: CGRect?
    let screen: NSScreen
    /// A window recording follows the window wherever it goes, even under other windows.
    var windowID: CGWindowID?
}

/// One recording at a time, from the hotkey to the file: the engine, the pill, the time in the
/// menu bar.
///
/// idle → starting → recording ⇄ paused → idle. Restart throws the take away and starts over with
/// the same target and the same sound settings; stop hands the file on.
@MainActor
final class RecordingController {
    private nonisolated static let logger = Logger(subsystem: "com.caramelheaven.pawshot", category: "recording")

    private let settings = Settings.shared
    private let state = AppState.shared
    private var engine: RecordingEngine?
    private var target: RecordingTarget?
    private var recordedSize = CGSize.zero
    private var events: EventRecorder?
    /// Marks a zoom (⇧⌘6 by default) — registered only while a take runs, so the combination
    /// stays free the rest of the time. Set in Settings → Shortcuts.
    private var zoomHotKey: GlobalHotKey?
    /// Switches the pen (⇧⌘7 by default), on the same terms.
    private var penHotKey: GlobalHotKey?
    /// Restart (⇧⌘5), on the same terms. Stopping is the shortcut that started the take.
    private var restartHotKey: GlobalHotKey?
    private var ink: InkPanelController?
    /// The dimming around a recorded region, the way macOS shows a region being recorded.
    private let frame = RecordingFrameController()
    private let zoomIndicator = ZoomMarkIndicator()
    private var isStarting = false
    /// Stop pressed while the take was still starting (or restarting): honoured once it is up.
    private var stopWhenStarted = false
    /// The zoom the outline shows, in the recording's clock: a mark close behind it only extends
    /// it, the way `EffectsPlanner.zoomSegments` merges them at export.
    private var zoomOutline: (cursor: CGPoint, end: TimeInterval)?
    private var ticker: Timer?
    private lazy var pill = RecordingPillController(actions: RecordingPillActions(
        togglePause: { [weak self] in self?.togglePause() },
        restart: { [weak self] in self?.restart() },
        stop: { [weak self] in self?.stop() },
        zoom: { [weak self] in self?.markZoom() },
        togglePen: { [weak self] in self?.togglePen() }
    ))

    /// Handed the finished take — the raw file, its pixel size, and the screen it was recorded on —
    /// for the video editor to open.
    var onRecorded: ((URL, CGSize, NSScreen) -> Void)?

    /// Told about anything that went wrong once the recording was no longer the caller's business:
    /// a failed stop, a stream the system ended, an export that didn't make it.
    var onFailure: ((Error) -> Void)?

    var isActive: Bool {
        engine != nil || isStarting
    }

    // MARK: - Control

    func start(_ target: RecordingTarget) async throws {
        guard !isActive else { return }
        isStarting = true
        defer {
            isStarting = false
            stopWhenStarted = false
        }

        // Straight away, before anything slow: the selection overlay has just gone, and the frame
        // should take its place rather than leave a flash of the bare screen in between.
        if target.windowID == nil, target.rect != nil {
            frame.show(area: Self.appKitRect(of: target), on: target.screen)
        }

        let microphone = await MicrophonePermission.resolve(wanted: settings.recordsMicrophone)

        // The pen's panel has to be on screen before the stream starts: it is the one Pawshot
        // window the filter lets through, and the filter is fixed from then on. A window
        // recording has no pen — its filter only ever sees that one window.
        let ink = target.windowID == nil ? InkPanelController(area: Self.appKitRect(of: target)) : nil
        ink?.show()
        ink?.onExit = { [weak self] in self?.togglePen() }
        await ink?.waitUntilOnScreen()

        let engine: RecordingEngine
        let size: (width: Int, height: Int)
        do {
            (engine, size) = try await Self.makeEngine(
                displayID: target.displayID,
                rect: target.rect,
                windowID: target.windowID,
                includingWindows: ink.map { [$0.windowID] } ?? [],
                nativeResolution: settings.recordsAtNativeResolution,
                capturesSystemAudio: settings.recordsSystemAudio,
                capturesMicrophone: microphone
            )
        } catch {
            ink?.close()
            frame.close()
            throw error
        }
        self.ink = ink
        engine.onUnexpectedStop = { [weak self] error in
            self?.finish(reporting: error)
        }
        do {
            try await engine.start()
        } catch {
            ink?.close()
            self.ink = nil
            frame.close()
            throw error
        }

        self.engine = engine
        self.target = target
        recordedSize = CGSize(width: size.width, height: size.height)
        Self.logger.info("recording \(size.width, privacy: .public)×\(size.height, privacy: .public), mic \(microphone, privacy: .public)")

        let events = EventRecorder(area: Self.appKitRect(of: target)) { [weak engine] in
            guard let engine, !engine.isPaused else { return nil }
            return engine.duration
        }
        events.start(recordingKeys: settings.showsKeystrokes)
        self.events = events
        // Dropped first: Carbon refuses a combination the app has already registered, so on a
        // restart the new ones would fail while the old ones were still alive.
        unregisterRecordingHotKeys()
        zoomHotKey = try? GlobalHotKey.register(settings.zoomMarkHotKey) { [weak self] in
            self?.markZoom()
        }
        restartHotKey = try? GlobalHotKey.register(settings.restartHotKey) { [weak self] in
            self?.restart()
        }
        if ink != nil {
            penHotKey = try? GlobalHotKey.register(settings.penHotKey) { [weak self] in
                self?.togglePen()
            }
        }

        state.recording = AppState.RecordingStatus(elapsed: 0, isPaused: false)
        // A full-screen take was started by ⇧⌘4, a region or a window by ⇧⌘3 — and stops the same way.
        let startedBy = target.rect == nil ? settings.recordFullScreenHotKey : settings.recordRegionHotKey
        pill.show(
            near: Self.appKitRect(of: target),
            on: target.screen,
            penAvailable: ink != nil,
            stopShortcut: startedBy
        )
        startTicker()
        if stopWhenStarted {
            stop()
        }
    }

    /// The moment to zoom in on at export, centred where the cursor is now. The part of the
    /// screen the zoom will show is outlined for as long as it will last, so the mark can be
    /// seen while recording; the outline is a Pawshot window and never reaches the video.
    func markZoom() {
        // Paused, the mark isn't recorded — and then nothing may pretend it was.
        guard let events, let target, let time = events.markZoom() else { return }
        var outline = (cursor: NSEvent.mouseLocation, end: time + EffectsPlanner.zoomLength)
        if let last = zoomOutline, time <= last.end + EffectsPlanner.zoomMergeGap {
            outline = (last.cursor, max(last.end, outline.end))
        }
        zoomOutline = outline
        zoomIndicator.show(
            around: outline.cursor,
            in: Self.appKitRect(of: target),
            scale: EffectsPlanner.zoomScale,
            for: outline.end - time
        )
        pill.flashZoom()
    }

    /// Drawing on the screen, into the video. While it is on, the mouse draws instead of clicking.
    func togglePen() {
        guard let ink else { return }
        ink.setDrawing(!ink.isDrawing)
        pill.setPen(isOn: ink.isDrawing)
    }

    func togglePause() {
        guard let engine else { return }
        if engine.isPaused {
            engine.resume()
        } else {
            engine.pause()
        }
        tick()
    }

    /// Throws the take away and starts again at once, with the same region and sound.
    func restart() {
        guard let engine, let target else { return }
        self.engine = nil
        // Still "active" while the old take winds down, so ⇧⌘3 in between stops rather than
        // opening a second overlay.
        isStarting = true
        zoomOutline = nil
        _ = events?.stop()
        events = nil
        // The frame stays: the region is the same, and closing it would flash the bare screen.
        closeInk()
        zoomIndicator.close()
        unregisterRecordingHotKeys()
        stopTicker()
        state.recording = AppState.RecordingStatus(elapsed: 0, isPaused: false)

        Task {
            await engine.cancel()
            isStarting = false
            do {
                try await start(target)
            } catch {
                teardown()
                onFailure?(error)
            }
        }
    }

    func stop() {
        if engine == nil, isStarting {
            stopWhenStarted = true
            return
        }
        finish(reporting: nil)
    }

    /// Ends the recording and keeps what was written — also when the system ended the stream on
    /// its own, where `error` says why.
    private func finish(reporting error: Error?) {
        guard let engine, let screen = target?.screen else { return }
        self.engine = nil
        let size = recordedSize
        let timeline = events?.stop() ?? EventTimeline()
        events = nil
        teardown()

        Task {
            do {
                let movie = try await engine.stop()
                try? timeline.save(nextTo: movie)
                Self.logger.info("recording finished: \(movie.lastPathComponent, privacy: .public)")
                onRecorded?(movie, size, screen)
                if let error {
                    onFailure?(error)
                }
            } catch {
                Self.logger.error("recording not saved: \(error.localizedDescription, privacy: .public)")
                onFailure?(error)
            }
        }
    }

    private func closeInk() {
        ink?.close()
        ink = nil
    }

    /// The shortcuts that only exist while a take runs.
    private func unregisterRecordingHotKeys() {
        zoomHotKey = nil
        penHotKey = nil
        restartHotKey = nil
    }

    private func teardown() {
        target = nil
        unregisterRecordingHotKeys()
        closeInk()
        frame.close()
        zoomIndicator.close()
        zoomOutline = nil
        _ = events?.stop()
        events = nil
        stopTicker()
        pill.hide()
        state.recording = nil
    }

    /// Everything ScreenCaptureKit hands out here — content, display, filter — isn't `Sendable`,
    /// so all of it lives and dies inside this one nonisolated function, off the main thread where
    /// the writer and the stream must not be created. Only the engine comes out.
    nonisolated static func makeEngine(
        displayID: CGDirectDisplayID,
        rect: CGRect?,
        windowID: CGWindowID? = nil,
        includingWindows includedIDs: [CGWindowID] = [],
        nativeResolution: Bool = true,
        capturesSystemAudio: Bool,
        capturesMicrophone: Bool
    ) async throws -> (engine: RecordingEngine, size: (width: Int, height: Int)) {
        // A fresh enumeration rather than the screenshot cache: the filter needs our own app as it
        // is now, and a recording can afford the 20 ms a screenshot can't.
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pawshot-recording-\(UUID().uuidString).mov")

        // One window, independent of the desktop: it is recorded even when something covers it,
        // and nothing else — the pill included — can get into the frame.
        if let windowID {
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                throw RecordingError.windowNotFound
            }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let scale = nativeResolution ? CGFloat(filter.pointPixelScale) : 1
            let size = SelectionGeometry.recordingPixelSize(of: filter.contentRect, scale: scale)
            let engine = try RecordingEngine(
                filter: filter,
                configuration: RecordingEngine.Configuration(
                    sourceRect: nil,
                    pixelWidth: size.width,
                    pixelHeight: size.height,
                    capturesSystemAudio: capturesSystemAudio,
                    capturesMicrophone: capturesMicrophone
                ),
                outputURL: outputURL
            )
            return (engine, size)
        }

        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw RecordingError.displayNotFound
        }

        // Every Pawshot window stays out of the video — the pill above all. `sharingType = .none`
        // would be the obvious tool, and since macOS 15.4 ScreenCaptureKit ignores it.
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let filter = SCContentFilter(
            display: display,
            excludingApplications: content.applications.filter { $0.processID == ownPID },
            exceptingWindows: content.windows.filter { includedIDs.contains($0.windowID) }
        )
        if content.windows.filter({ includedIDs.contains($0.windowID) }).count != includedIDs.count {
            Self.logger.error("a window meant for the video isn't in the shareable content — the pen won't be recorded")
        }

        let wholeDisplay = CGRect(origin: .zero, size: display.frame.size)
        let sourceRect = rect.map {
            SelectionGeometry.sourceRect(displayRect: $0, displayFrame: display.frame).intersection(wholeDisplay)
        }
        let size = SelectionGeometry.recordingPixelSize(
            of: sourceRect ?? wholeDisplay,
            scale: nativeResolution ? CGFloat(filter.pointPixelScale) : 1
        )

        let engine = try RecordingEngine(
            filter: filter,
            configuration: RecordingEngine.Configuration(
                sourceRect: sourceRect,
                pixelWidth: size.width,
                pixelHeight: size.height,
                capturesSystemAudio: capturesSystemAudio,
                capturesMicrophone: capturesMicrophone
            ),
            outputURL: outputURL
        )
        return (engine, size)
    }

    // MARK: - Time

    private func startTicker() {
        stopTicker()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private func tick() {
        guard let engine else { return }
        let status = AppState.RecordingStatus(elapsed: engine.duration, isPaused: engine.isPaused)
        if state.recording != status {
            state.recording = status
        }
    }

    // MARK: - Helpers

    /// The recorded area in AppKit screen coordinates — where the pill has to steer clear of.
    private static func appKitRect(of target: RecordingTarget) -> CGRect {
        guard let rect = target.rect else { return target.screen.frame }
        let primaryMaxY = NSScreen.screens.first.map(\.frame.maxY) ?? 0
        return SelectionGeometry.convertToAppKit(rect: rect, primaryScreenMaxY: primaryMaxY)
    }
}
