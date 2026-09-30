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
    /// Zones blurred in the video throughout, as fractions of the region (0…1, origin top left).
    var maskZones: [CGRect] = []
}

/// One recording at a time, from the hotkey to the file: the engine, the pill, the time in the
/// menu bar.
///
/// idle → starting → recording ⇄ paused → idle. Restart throws the take away and starts over with
/// the same target and the same sound settings; stop hands the file on.
@MainActor
final class RecordingController {
    private nonisolated static var logger: Logger {
        .pawshot("recording")
    }

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
    /// "Cut the last seconds" (⌃⌘X), on the same terms.
    private var badTakeHotKey: GlobalHotKey?
    /// The three keys that do something for as long as they are held: a spotlight around the
    /// cursor (⌃⌘A), the picture hidden (⌃⌘B), the microphone silent (⌃⌘V).
    private var spotlightHotKey: GlobalHotKey?
    private var blurHotKey: GlobalHotKey?
    private var muteHotKey: GlobalHotKey?
    /// When each held effect's key went down, in the file's time.
    private var heldSince: [EventRecorder.HeldEffect: TimeInterval] = [:]
    private let heldIndicator = HeldEffectIndicator()
    /// Listens to the microphone during a take recorded without it, to tell when somebody talks.
    private var talkMeter: MicrophoneLevelMeter?
    private var speech = SpeechWatch()
    /// The zoom key is down: the mark its press left, and when it went down. Held past
    /// `EffectsPlanner.zoomHoldAfter`, the mark becomes a zoom that lasts until the release.
    private var zoomPress: (mark: TimeInterval, at: Date)?
    private var zoomFollowTimer: Timer?
    /// Counts the ticks, a quarter of a second each: the file's size is looked at once a second.
    private var ticks = 0
    private var diskWarningLogged = false
    private var sizeFailureLogged = false
    private var ink: InkPanelController?
    /// The dimming around a recorded region, the way macOS shows a region being recorded.
    private let frame = RecordingFrameController()
    /// Four bars round the region while a take is paused, to move it by.
    private let grabFrame = RegionMoveFrameController()
    /// A moved region is being handed to the stream; resuming waits for it.
    private var regionMoveInFlight = false
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
        togglePen: { [weak self] in self?.togglePen() },
        badTake: { [weak self] in self?.markBadTake() },
        recordWithMicrophone: { [weak self] in self?.restartWithMicrophone() },
        dismissMicrophoneHint: { [weak self] in self?.closeMicrophoneHint() }
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
        guard !isActive else {
            Self.logger.notice("recording not started: one is already running")
            return
        }
        let kind = target.windowID != nil ? "window" : (target.rect == nil ? "full screen" : "region")
        Self.logger.notice("recording starts: \(kind, privacy: .public) on display \(target.displayID)")
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
        // The microphone picked in the toolbar, if it is still plugged in; otherwise the system's.
        let devices = MicrophoneDevices.all()
        let stored = settings.microphoneDeviceID
        let device = microphone
            ? MicrophoneDevices.resolved(stored: stored, among: devices, systemDefault: MicrophoneDevices.systemDefaultID)
            : nil
        if microphone, let stored, device != stored {
            Self.logger.error("the picked microphone is gone: recording from the default one instead")
        }

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
                capturesMicrophone: microphone,
                microphoneDeviceID: device
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
        wireRegionMove()
        recordedSize = CGSize(width: size.width, height: size.height)
        let systemAudio = settings.recordsSystemAudio
        let native = settings.recordsAtNativeResolution
        let penAvailable = ink != nil
        Self.logger.notice(
            "recording \(size.width, privacy: .public)×\(size.height, privacy: .public), mic \(microphone, privacy: .public), system audio \(systemAudio, privacy: .public), native \(native, privacy: .public), pen available \(penAvailable, privacy: .public)"
        )

        let events = EventRecorder(area: Self.appKitRect(of: target)) { [weak engine] in
            guard let engine, !engine.isPaused else { return nil }
            return engine.duration
        }
        events.setMasks(target.maskZones)
        events.start(recordingKeys: settings.showsKeystrokes)
        self.events = events
        registerRecordingHotKeys()

        state.recording = AppState.RecordingStatus(elapsed: 0, isPaused: false)
        // A full-screen take was started by ⇧⌘4, a region or a window by ⇧⌘3 — and stops the same way.
        let startedBy = target.rect == nil ? settings.recordFullScreenHotKey : settings.recordRegionHotKey
        pill.show(
            near: Self.appKitRect(of: target),
            on: target.screen,
            penAvailable: ink != nil,
            stopShortcut: startedBy
        )
        pill.setGoal(settings.recordingGoal)
        pill.setDetail(nil, isWarning: false)
        let goal = Int(settings.recordingGoal)
        if goal > 0 {
            Self.logger.notice("the take aims for \(goal, privacy: .public) s")
        }
        listenForTalking(takeHasMicrophone: microphone)
        startTicker()
        if stopWhenStarted {
            stop()
        }
    }

    /// The moment to zoom in on at export, centred where the cursor is now. The part of the
    /// screen the zoom will show is outlined for as long as it will last, so the mark can be
    /// seen while recording; the outline is a Pawshot window and never reaches the video.
    @discardableResult
    func markZoom() -> TimeInterval? {
        // Paused, the mark isn't recorded — and then nothing may pretend it was.
        guard let events, let target else { return nil }
        guard let time = events.markZoom() else {
            Self.logger.notice("zoom mark ignored: paused")
            return nil
        }
        let marks = events.timeline.zoomMarks.count
        Self.logger.notice(
            "zoom mark at \(String(format: "%.1f", time), privacy: .public) s (\(marks, privacy: .public) so far)"
        )
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
        return time
    }

    /// The zoom key went down. It is a mark at once — a tap is nothing more — and the start of a
    /// hold if the key stays down: then the outline follows the cursor until the release.
    private func zoomKeyDown() {
        // A held key may repeat; only the first press counts.
        guard zoomPress == nil, let mark = markZoom() else { return }
        zoomPress = (mark, Date())
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.followHeldZoom() }
        }
        RunLoop.main.add(timer, forMode: .common)
        zoomFollowTimer = timer
    }

    private func followHeldZoom() {
        guard let zoomPress, let target else { return }
        guard EffectsPlanner.isZoomHold(heldFor: Date().timeIntervalSince(zoomPress.at)) else { return }
        zoomIndicator.follow(NSEvent.mouseLocation, in: Self.appKitRect(of: target), scale: EffectsPlanner.zoomScale)
    }

    /// The zoom key came up. Held long enough, the mark of its press becomes a zoom from the
    /// press to now; let go sooner, it was a tap and the mark stands.
    private func zoomKeyUp() {
        zoomFollowTimer?.invalidate()
        zoomFollowTimer = nil
        guard let press = zoomPress else { return }
        zoomPress = nil
        let held = Date().timeIntervalSince(press.at)
        guard EffectsPlanner.isZoomHold(heldFor: held), let engine, let events else { return }

        let end = engine.duration
        events.holdZoom(from: press.mark, to: end)
        zoomOutline = nil
        zoomIndicator.letGo()
        Self.logger.notice(
            "zoom held \(String(format: "%.1f", press.mark), privacy: .public)–\(String(format: "%.1f", end), privacy: .public) s (the key was down \(String(format: "%.1f", held), privacy: .public) s)"
        )
    }

    // MARK: - Keys that are held

    /// A spotlight or a blur key went down: the effect starts here in the file, and the screen
    /// shows that it took.
    private func heldKeyDown(_ effect: EventRecorder.HeldEffect) {
        // A held key may repeat; only the first press counts.
        guard heldSince[effect] == nil, let events, let target else { return }
        guard let start = events.now else {
            Self.logger.notice("\(effect.rawValue, privacy: .public) key ignored: paused")
            return
        }
        heldSince[effect] = start
        heldIndicator.show(effect, over: Self.appKitRect(of: target))
        Self.logger.notice("\(effect.rawValue, privacy: .public) held from \(String(format: "%.1f", start), privacy: .public) s")
    }

    /// The key came up: the stretch from its press to now goes into the timeline, and the export
    /// draws the effect over it.
    private func heldKeyUp(_ effect: EventRecorder.HeldEffect) {
        guard let start = heldSince.removeValue(forKey: effect) else { return }
        heldIndicator.hide()
        guard let engine, let events else { return }
        let end = engine.duration
        if events.hold(effect, from: start, to: end) == nil {
            Self.logger.notice("\(effect.rawValue, privacy: .public) key let go at once: nothing recorded")
        } else {
            Self.logger.notice(
                "\(effect.rawValue, privacy: .public) held \(String(format: "%.1f", start), privacy: .public)–\(String(format: "%.1f", end), privacy: .public) s"
            )
        }
    }

    /// A key that is down when its shortcut goes away — the take stops, restarts, or a shortcut
    /// field starts recording — has nobody left to hear its release: what it held ends here.
    private func releaseHeldKeys() {
        for effect in Array(heldSince.keys) {
            heldKeyUp(effect)
        }
        engine?.setMicrophoneMuted(false)
        pill.hold(notice: nil)
    }

    /// The mute key went down or came up: while it is down the microphone records silence.
    private func setMuteHeld(_ held: Bool) {
        guard let engine else { return }
        guard engine.recordsMicrophone else {
            if held {
                Self.logger.notice("mute key: this take has no microphone")
                pill.flash(notice: String(localized: "The microphone is off"))
            }
            return
        }
        engine.setMicrophoneMuted(held)
        pill.hold(notice: held ? String(localized: "Microphone muted") : nil)
        Self.logger.notice(
            "microphone \(held ? "muted" : "back", privacy: .public) at \(String(format: "%.1f", engine.duration), privacy: .public) s"
        )
    }

    // MARK: - Talking into a microphone that is off

    /// A take recorded without the microphone listens to it all the same — keeping nothing — so
    /// the pill can say, once, that somebody is talking. Only with the setting on and access
    /// already granted: the take never asks for the microphone for this.
    private func listenForTalking(takeHasMicrophone: Bool) {
        stopListeningForTalking()
        let wanted = settings.noticesTalkingWhileMuted
        let granted = MicrophonePermission.isGranted
        guard !takeHasMicrophone, wanted, granted else {
            if !takeHasMicrophone {
                Self.logger.notice(
                    "not listening for talk: setting \(wanted, privacy: .public), microphone access \(granted, privacy: .public)"
                )
            }
            return
        }
        speech = SpeechWatch()
        let started = Date()
        let meter = MicrophoneLevelMeter(deviceUID: settings.microphoneDeviceID) { [weak self] level, _ in
            guard let self, talkMeter != nil else { return }
            if speech.feed(level: level, at: Date().timeIntervalSince(started)) {
                talkingHeard()
            }
        }
        meter.start()
        talkMeter = meter
        Self.logger.notice("listening for talk: this take has no microphone")
    }

    private func talkingHeard() {
        let elapsed = engine.map { String(format: "%.1f", $0.duration) } ?? "?"
        Self.logger.notice("talk heard at \(elapsed, privacy: .public) s with the microphone off: the pill says so")
        // Said once a take; after that there is nothing left to listen for.
        stopListeningForTalking()
        pill.showMicrophoneHint()
    }

    private func stopListeningForTalking() {
        talkMeter?.stop()
        talkMeter = nil
    }

    /// The hint's cross: the take goes on as it is, without the microphone.
    private func closeMicrophoneHint() {
        pill.dismissMicrophoneHint(reason: "closed with the cross")
    }

    /// From the pill's hint: the microphone goes on and the take starts over with it.
    private func restartWithMicrophone() {
        Self.logger.notice("hint answered: starting over with the microphone on")
        pill.dismissMicrophoneHint(reason: "start over with the microphone")
        settings.recordsMicrophone = true
        restart()
    }

    // MARK: - Marks

    /// The last seconds were no good: they are marked, the take goes on, and the editor opens
    /// with them already cut.
    func markBadTake() {
        guard let events else { return }
        guard let span = events.markBadTake() else {
            Self.logger.notice("bad take ignored: paused, or nothing new to cut")
            return
        }
        let marks = events.timeline.badTakes.count
        Self.logger.notice(
            "bad take: \(String(format: "%.1f", span.start), privacy: .public)–\(String(format: "%.1f", span.end), privacy: .public) s will be cut (\(marks, privacy: .public) so far)"
        )
        pill.flashBadTake()
        pill.flash(notice: String(localized: "Last \(Int((span.end - span.start).rounded())) s cut"))
    }

    /// The picture being recorded, onto the clipboard — ⇧⌘2 during a take. The take goes on, and
    /// no window opens: a Pawshot window would not be in the video, but it would be in the way.
    func copyFrame() {
        guard let engine else { return }
        Task {
            guard let image = await engine.snapshot() else {
                Self.logger.error("frame not copied: the take has no picture yet")
                return
            }
            do {
                try ExportService.copy(image)
                Self.logger.notice("frame copied from the take: \(image.width, privacy: .public)×\(image.height, privacy: .public) px")
                pill.flash(notice: String(localized: "Frame copied"))
            } catch {
                Self.logger.error("frame not copied: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Drawing on the screen, into the video. While it is on, the mouse draws instead of clicking.
    func togglePen() {
        guard let ink else { return }
        ink.setDrawing(!ink.isDrawing)
        let drawing = ink.isDrawing
        Self.logger.notice("pen \(drawing ? "on" : "off", privacy: .public)")
        pill.setPen(isOn: drawing)
    }

    func togglePause() {
        guard let engine else { return }
        let resumes = engine.isPaused
        let elapsed = String(format: "%.1f", engine.duration)
        Self.logger.notice("recording \(resumes ? "resumed" : "paused", privacy: .public) at \(elapsed, privacy: .public) s")
        if !resumes {
            Stats.shared.add(.pauses)
        }
        if resumes, regionMoveInFlight {
            Self.logger.notice("resume ignored: the moved region is still being handed to the stream")
            return
        }
        if engine.isPaused {
            engine.resume()
        } else {
            engine.pause()
        }
        updateGrabFrame(paused: !resumes)
        tick()
    }

    // MARK: - Moving the region while paused

    /// A region take can be moved on a pause; a window follows its window and a whole screen has
    /// nowhere to go.
    private var canMoveRegion: Bool {
        target.map { $0.rect != nil && $0.windowID == nil } ?? false
    }

    private func wireRegionMove() {
        grabFrame.onMove = { [weak self] area in self?.regionMoves(to: area) }
        grabFrame.onDrop = { [weak self] old, new in self?.regionDropped(from: old, to: new) }
    }

    private func updateGrabFrame(paused: Bool) {
        guard paused, canMoveRegion, let target else {
            grabFrame.close()
            return
        }
        grabFrame.show(area: Self.appKitRect(of: target), within: target.screen.frame)
    }

    /// Every step of a drag: what shows the region follows, the stream is not touched yet.
    private func regionMoves(to area: CGRect) {
        guard let target else { return }
        frame.show(area: area, on: target.screen)
        ink?.move(to: area)
        pill.follow(area: area, on: target.screen)
    }

    /// The mouse was let go: the stream, the timeline and the remembered region all follow. When
    /// the stream won't take the new place, everything goes back where it was.
    private func regionDropped(from old: CGRect, to new: CGRect) {
        guard let engine, let target else { return }
        let primaryMaxY = NSScreen.screens.first.map(\.frame.maxY) ?? 0
        let global = SelectionGeometry.convertToCoreGraphics(rect: new, primaryScreenMaxY: primaryMaxY)
        let display = CGDisplayBounds(target.displayID)
        let source = SelectionGeometry.sourceRect(displayRect: global, displayFrame: display)
            .intersection(CGRect(origin: .zero, size: display.size))
        let fromText = "\(Int(old.minX)),\(Int(old.minY))"
        let toText = "\(Int(new.minX)),\(Int(new.minY))"
        regionMoveInFlight = true
        Task {
            defer { regionMoveInFlight = false }
            do {
                try await engine.moveSource(to: source)
                self.target = RecordingTarget(
                    displayID: target.displayID, rect: global, screen: target.screen, windowID: nil, maskZones: target.maskZones
                )
                events?.move(to: new)
                settings.setLastRecordingArea(source, on: target.displayID)
                Self.logger.notice("region moved while paused: \(fromText, privacy: .public) → \(toText, privacy: .public) pt (AppKit), stream follows")
            } catch {
                Self.logger.error("region move refused by the stream, put back: \(String(describing: error), privacy: .public)")
                regionMoves(to: old)
                grabFrame.place(old)
                pill.flash(notice: String(localized: "The region can't be moved"))
            }
        }
    }

    /// Throws the take away and starts again at once, with the same region and sound.
    func restart() {
        guard let engine, let target else { return }
        releaseHeldKeys()
        stopListeningForTalking()
        let thrownAway = String(format: "%.1f", engine.duration)
        Self.logger.notice("recording restarts: \(thrownAway, privacy: .public) s thrown away")
        Stats.shared.add(.restarts)
        self.engine = nil
        // Still "active" while the old take winds down, so ⇧⌘3 in between stops rather than
        // opening a second overlay.
        isStarting = true
        zoomOutline = nil
        _ = events?.stop()
        events = nil
        // The frame stays: the region is the same, and closing it would flash the bare screen.
        grabFrame.close()
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
                Self.logger.error("restart failed: \(String(describing: error), privacy: .public)")
                teardown()
                onFailure?(error)
            }
        }
    }

    func stop() {
        if engine == nil, isStarting {
            Self.logger.notice("recording stop asked while starting: stops once started")
            stopWhenStarted = true
            return
        }
        Self.logger.notice("recording stops")
        finish(reporting: nil)
    }

    /// Ends the recording and keeps what was written — also when the system ended the stream on
    /// its own, where `error` says why.
    private func finish(reporting error: Error?) {
        guard let engine, let screen = target?.screen else {
            Self.logger.notice("recording finish: nothing running")
            return
        }
        if let error {
            Self.logger.error("the stream ended on its own: \(String(describing: error), privacy: .public)")
        }
        // While the engine and the timeline are still there: a key held at the stop keeps its stretch.
        releaseHeldKeys()
        let seconds = engine.duration
        self.engine = nil
        let size = recordedSize
        let timeline = events?.stop() ?? EventTimeline()
        events = nil
        let penStrokes = ink?.strokeCount ?? 0
        teardown()

        Task {
            do {
                let movie = try await engine.stop()
                do {
                    try timeline.save(nextTo: movie)
                } catch {
                    Self.logger.error("timeline not saved: \(String(describing: error), privacy: .public)")
                }
                let bytes = (try? movie.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                Self.logger.notice(
                    "recording finished: \(movie.lastPathComponent, privacy: .public), \(String(format: "%.1f", seconds), privacy: .public) s, \(Int(size.width), privacy: .public)×\(Int(size.height), privacy: .public), \(bytes, privacy: .public) B, \(timeline.clicks.count, privacy: .public) clicks, \(timeline.keys.count, privacy: .public) keys, \(timeline.zoomMarks.count, privacy: .public) zoom marks, \(penStrokes, privacy: .public) pen strokes"
                )
                onRecorded?(movie, size, screen)
                Stats.shared.noteRecording(seconds: seconds)
                if let error {
                    onFailure?(error)
                }
            } catch {
                Self.logger.error("recording not saved: \(String(describing: error), privacy: .public)")
                onFailure?(error)
            }
        }
    }

    private func closeInk() {
        ink?.close()
        ink = nil
    }

    /// The shortcuts that only exist while a take runs, as Settings has them now. `AppDelegate`
    /// calls it with its own on every shortcut change: one cleared with × mid-take used to stay
    /// live — and ⇧⌘5 pressed from habit threw the take away.
    func registerRecordingHotKeys() {
        // Dropped first: Carbon refuses a combination the app has already registered, so on a
        // restart the new ones would fail while the old ones were still alive.
        unregisterRecordingHotKeys()
        guard engine != nil else { return }
        zoomHotKey = GlobalHotKey.register(
            settings.zoomMarkHotKey,
            for: "mark a zoom",
            onRelease: { [weak self] in self?.zoomKeyUp() },
            action: { [weak self] in self?.zoomKeyDown() }
        )
        badTakeHotKey = GlobalHotKey.register(settings.badTakeHotKey, for: "mark a bad take") { [weak self] in
            self?.markBadTake()
        }
        spotlightHotKey = GlobalHotKey.register(
            settings.spotlightHotKey,
            for: "hold the spotlight",
            onRelease: { [weak self] in self?.heldKeyUp(.spotlight) },
            action: { [weak self] in self?.heldKeyDown(.spotlight) }
        )
        blurHotKey = GlobalHotKey.register(
            settings.blurHotKey,
            for: "hold the blur",
            onRelease: { [weak self] in self?.heldKeyUp(.blur) },
            action: { [weak self] in self?.heldKeyDown(.blur) }
        )
        muteHotKey = GlobalHotKey.register(
            settings.muteHotKey,
            for: "hold the mute",
            onRelease: { [weak self] in self?.setMuteHeld(false) },
            action: { [weak self] in self?.setMuteHeld(true) }
        )
        restartHotKey = GlobalHotKey.register(settings.restartHotKey, for: "restart the take") { [weak self] in
            self?.restart()
        }
        if ink != nil {
            penHotKey = GlobalHotKey.register(settings.penHotKey, for: "switch the pen") { [weak self] in
                self?.togglePen()
            }
        }
    }

    /// Also while a shortcut field records, so the old combination can be pressed to replace it.
    func unregisterRecordingHotKeys() {
        zoomHotKey = nil
        penHotKey = nil
        restartHotKey = nil
        badTakeHotKey = nil
        spotlightHotKey = nil
        blurHotKey = nil
        muteHotKey = nil
        releaseHeldKeys()
        // A zoom key that was down has nobody left to hear its release.
        zoomFollowTimer?.invalidate()
        zoomFollowTimer = nil
        zoomPress = nil
    }

    private func teardown() {
        target = nil
        unregisterRecordingHotKeys()
        closeInk()
        grabFrame.close()
        frame.close()
        zoomIndicator.close()
        heldIndicator.hide()
        stopListeningForTalking()
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
        capturesMicrophone: Bool,
        microphoneDeviceID: String? = nil
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
                    capturesMicrophone: capturesMicrophone,
                    microphoneDeviceID: microphoneDeviceID
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
                capturesMicrophone: capturesMicrophone,
                microphoneDeviceID: microphoneDeviceID
            ),
            outputURL: outputURL
        )
        return (engine, size)
    }

    // MARK: - Time

    private func startTicker() {
        stopTicker()
        ticks = 0
        diskWarningLogged = false
        sizeFailureLogged = false
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
        ticks += 1
        if ticks % 4 == 0 {
            showFileSize(of: engine, elapsed: status.elapsed)
        }
    }

    /// Once a second: what the take weighs so far, or — with under five minutes of room left at
    /// this rate — that the disk is running out. Said in the pill while there is still time to
    /// wrap up; logged once.
    private func showFileSize(of engine: RecordingEngine, elapsed: TimeInterval) {
        let values: URLResourceValues
        do {
            values = try engine.outputURL.resourceValues(forKeys: [.fileSizeKey, .volumeAvailableCapacityForImportantUsageKey])
        } catch {
            if !sizeFailureLogged {
                sizeFailureLogged = true
                Self.logger.error("the take's size can't be read: \(String(describing: error), privacy: .public)")
            }
            return
        }
        let written = Int64(values.fileSize ?? 0)
        // The file is written in parts; before the first one lands there is nothing to show.
        guard written > 0 else { return }

        let left = values.volumeAvailableCapacityForImportantUsage.flatMap {
            RecordingBudget.secondsLeft(freeBytes: $0, writtenBytes: written, elapsed: elapsed)
        }
        if RecordingBudget.isRunningOut(secondsLeft: left), let left {
            let minutes = max(1, Int(left / 60))
            pill.setDetail(String(localized: "disk: about \(minutes) min left"), isWarning: true)
            if !diskWarningLogged {
                diskWarningLogged = true
                Self.logger.error(
                    "the disk is running out: about \(Int(left), privacy: .public) s of recording left, \(written, privacy: .public) B written in \(Int(elapsed), privacy: .public) s"
                )
            }
        } else {
            pill.setDetail(RecordingBudget.sizeText(bytes: written), isWarning: false)
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
