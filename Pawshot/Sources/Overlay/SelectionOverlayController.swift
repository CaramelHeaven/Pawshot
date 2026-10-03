import AppKit
import os

/// Full-screen region selection mode: one window per display.
@MainActor
final class SelectionOverlayController: NSObject, SelectionViewDelegate {
    private static var logger: Logger {
        .pawshot("overlay")
    }

    struct Selection {
        /// The display the frame was dragged on.
        let displayID: CGDirectDisplayID
        /// The region in global CoreGraphics coordinates (origin at the top left).
        let rect: CGRect
        let screen: NSScreen
        /// This display's frame, captured before the overlay was shown — the region is cut out of
        /// it. A recording has none: its region is picked on the live screen.
        let frame: CapturedFrame?
        /// Set when a whole window was picked: a recording follows the window, not the region.
        var windowID: CGWindowID?
        /// The whole display was picked — the toolbar's "screen" — rather than a part of it.
        var isWholeDisplay = false
        /// Zones to blur for the whole take, as fractions of the region (0…1, origin top left).
        var maskZones: [CGRect] = []
    }

    /// The windows of the capture on screen now; empty between captures.
    private var windows: [OverlayWindow] = []
    /// One ready window per display, built ahead of the hotkey and kept between captures: creating
    /// a window is the part of showing the overlay that costs.
    private var prepared: [CGDirectDisplayID: OverlayWindow] = [:]
    private var screenObserver: NSObjectProtocol?
    private var frames: [CGDirectDisplayID: CapturedFrame] = [:]
    /// Whether the frames have arrived — the overlay goes up before they do.
    private(set) var hasFrames = false
    /// A selection made before the frames arrived: it is cut out once they do.
    private var pendingSelection: (view: SelectionView, rect: CGRect, windowID: CGWindowID?)?
    private var completion: ((Selection?) -> Void)?
    private var purpose: OverlayPurpose = .screenshot
    private var levelMeter: MicrophoneLevelMeter?
    /// The three-seconds-and-back microphone check, while one is running.
    private var echo: MicrophoneEcho?
    /// Which echo the phases coming back belong to: one stopped a moment ago must not clear the
    /// next.
    private var echoRun = 0
    /// The app that was in front when the overlay went up. The overlay never activates Pawshot,
    /// so after a cancel this one is still in front; kept for the log and for safety.
    private var previousApp: NSRunningApplication?

    private var selectionViews: [SelectionView] {
        windows.compactMap(\.selectionView)
    }

    /// The screen whose region a take would record, and where its zones live: the one last
    /// pressed on (it holds the keyboard — `SelectionView.mouseDown`), then the one under the
    /// toolbar, then any. A region restored on every display used to be recorded from whichever
    /// screen the toolbar or the keyboard happened to be on.
    private var viewWithRegion: SelectionView? {
        let withRegion = selectionViews.filter { $0.recordingRegion != nil }
        return withRegion.first { $0.window?.isKeyWindow == true }
            ?? withRegion.first { $0 === toolbarView }
            ?? withRegion.first
    }

    var isActive: Bool {
        !windows.isEmpty
    }

    /// The overlay's window numbers — what the frozen frame must not contain.
    var windowNumbers: [CGWindowID] {
        windows.map { CGWindowID($0.windowNumber) }
    }

    /// Builds the overlay windows ahead of the first capture, and again whenever the displays
    /// change. Called at launch.
    func prepareWindows() {
        if screenObserver == nil {
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.displaysChanged()
                }
            }
        }
        var ready: [CGDirectDisplayID: OverlayWindow] = [:]
        for screen in NSScreen.screens {
            guard let displayID = Self.displayID(of: screen) else { continue }
            if let window = prepared[displayID], window.frame == screen.frame {
                ready[displayID] = window
            } else {
                ready[displayID] = OverlayWindow(screen: screen)
            }
        }
        prepared = ready
        Self.logger.notice("overlay windows ready for \(ready.count, privacy: .public) display(s)")
    }

    /// New displays, or new sizes: the ready windows no longer fit. Rebuilt between captures only.
    private func displaysChanged() {
        guard !isActive else {
            Self.logger.notice("displays changed during a capture: the ready windows are rebuilt after it")
            return
        }
        let dropped = prepared.values.map { "\($0.windowNumber) (\($0.timesShown)×)" }.joined(separator: ", ")
        Self.logger.notice("displays changed: ready windows dropped: \(dropped.isEmpty ? "none" : dropped, privacy: .public)")
        prepared.removeAll()
        prepareWindows()
    }

    /// Shows the overlay at once, over the live screen, and waits for a selection. The frozen
    /// frames follow through `deliver(frames:)` — the dimming does not wait for them.
    ///
    /// The frame is what the result is cut from and what the loupe magnifies; it is captured the
    /// moment the hotkey is pressed, with the overlay left out of it, and since the overlay never
    /// activates Pawshot, the other app's open menu is still open when it is taken.
    ///
    /// - Parameter capturedWindows: the window list, taken before the overlay, for the window mode.
    func begin(
        capturedWindows: [CapturedWindow] = [],
        purpose: OverlayPurpose = .screenshot,
        completion: @escaping (Selection?) -> Void
    ) {
        guard !isActive else {
            Self.logger.notice("overlay not started: one is already up")
            return
        }
        let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        Self.logger.notice(
            "overlay begins: \(String(describing: purpose), privacy: .public), \(capturedWindows.count) window(s), \(front, privacy: .public) in front"
        )
        OverlayDiagnostics.began()
        self.completion = completion
        self.purpose = purpose
        frames = [:]
        // A recording is picked on the live screen and records what is there afterwards: no frame
        // is captured for it, so there is none to wait for.
        hasFrames = purpose == .recording
        pendingSelection = nil
        previousApp = NSWorkspace.shared.frontmostApplication
        // From the list taken before the overlay, so no window-server call is added on the way
        // to the dimming — one here was seen to go with the dimming leaking into the frame.
        OverlayDiagnostics.noteFrontApp(previousApp, windows: capturedWindows)

        let primaryMaxY = NSScreen.screens.first.map(\.frame.maxY) ?? 0
        let mouseLocation = NSEvent.mouseLocation
        let settings = Settings.shared
        // The key hints are for learning the keys; after a handful of captures they are noise.
        let showsHints = settings.captureCount < 5
        OverlayHUD.hints.mode = .region
        OverlayHUD.hints.purpose = purpose
        OverlayHUD.hints.loupeIsOn = false
        if purpose == .recording {
            prepareRecordingBar()
        }
        if prepared.count != NSScreen.screens.count {
            prepareWindows()
        }

        for screen in NSScreen.screens {
            guard let displayID = Self.displayID(of: screen), var window = prepared[displayID] else { continue }

            let view = SelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
            view.delegate = self
            view.screenOrigin = Self.coreGraphicsOrigin(of: screen, primaryMaxY: primaryMaxY)
            view.windows = capturedWindows
            if purpose == .recording {
                view.refreshWindows = { [weak self] in self?.refreshWindows(reason: "press") }
            }
            view.scale = screen.backingScaleFactor
            view.showsHints = showsHints
            view.purpose = purpose
            if purpose == .recording {
                view.nativeResolution = settings.recordsAtNativeResolution
                // The region last recorded here comes back alive, to be moved, resized or
                // recorded again with ↩.
                let last = settings.lastRecordingArea(on: displayID)
                    .map { $0.intersection(CGRect(origin: .zero, size: screen.frame.size)) }
                    .flatMap { SelectionGeometry.isTooSmall($0) ? nil : $0 }
                if let last {
                    view.restore(lastRegion: last)
                    Self.logger.notice(
                        "last region restored on display \(displayID, privacy: .public): \(Int(last.width), privacy: .public)×\(Int(last.height), privacy: .public) pt"
                    )
                }
            }
            window.install(view)
            windows.append(window)

            window.orderFrontRegardless()
            // The screen under the cursor becomes key — that's where Esc and the first click go.
            // A non-activating panel takes the keyboard without Pawshot becoming active.
            //
            // Not deferred until the frame is taken, though Telegram Desktop's photo viewer may
            // close on losing the keyboard: tried on 2026-09-29 and rolled back after the dimming
            // leaked into the frame in test runs — see AGENTS.md, the overlay section.
            let takesKey = screen.frame.contains(mouseLocation)
            if takesKey {
                window.makeKey()
                window.makeFirstResponder(view)
            }
            window.timesShown += 1
            let number = window.windowNumber
            let visible = window.isVisible
            let onSpace = window.isOnActiveSpace
            let key = window.isKeyWindow
            let described = LogExport.describe(screen)
            let age = Int(Date().timeIntervalSince(window.builtAt))
            let shown = window.timesShown
            Self.logger.notice(
                "overlay window \(number, privacy: .public) on \(described, privacy: .public): visible \(visible, privacy: .public), on active space \(onSpace, privacy: .public), key \(key, privacy: .public), built \(age, privacy: .public) s ago, shown \(shown, privacy: .public)×"
            )
            // A ready window the system no longer shows on the Space in front: the dimming never
            // came, and every ⇧⌘2 after it met "the overlay is already up" until a relaunch (a log
            // of 0.5.3, 2026-09-30, a window kept since before a sleep and a display change). Why
            // it fell out of "every Space" is not known; a window built now is on this one.
            if !onSpace {
                Self.logger.error("overlay window \(number, privacy: .public) is not on the active space (built \(age, privacy: .public) s ago, shown \(shown, privacy: .public)×): rebuilt")
                window.orderOut(nil)
                window.clear()
                window.close()
                let fresh = OverlayWindow(screen: screen)
                prepared[displayID] = fresh
                fresh.install(view)
                windows[windows.count - 1] = fresh
                fresh.orderFrontRegardless()
                if takesKey {
                    fresh.makeKey()
                    fresh.makeFirstResponder(view)
                }
                fresh.timesShown = 1
                window = fresh
                let freshNumber = fresh.windowNumber
                let freshOnSpace = fresh.isOnActiveSpace
                Self.logger.notice("overlay window rebuilt as \(freshNumber, privacy: .public): on active space \(freshOnSpace, privacy: .public)")
            }
        }

        // Looked at a few times from the main thread, and watched from another one: the first
        // capture after launch once showed nothing until a click, with the main thread silent for
        // four seconds.
        OverlayDiagnostics.watch(windows: windows)
        Task { @MainActor [weak self] in
            // At about 100 ms, 500 ms and 2 s after the overlay went up.
            for pause in [100, 400, 1500] {
                try? await Task.sleep(for: .milliseconds(pause))
                guard let self, isActive else { return }
                OverlayDiagnostics.check(windows: windows)
                if pause == 400 {
                    OverlayDiagnostics.compareFrontAppWindows("at +\(OverlayDiagnostics.sincePress()) ms")
                    // Still on no Space in front half a second on, rebuilt or not: the person sees
                    // nothing. Closed, so the next press starts afresh instead of meeting "already up".
                    if !windows.contains(where: \.isOnActiveSpace) {
                        let numbers = windows.map { String($0.windowNumber) }.joined(separator: ", ")
                        Self.logger.error("overlay on no active space 500 ms after the hotkey (windows \(numbers, privacy: .public)): closed")
                        prepared.removeAll()
                        finish(with: nil)
                        return
                    }
                }
            }
        }

        // The overlay has to be alive the moment it appears: badge, highlight and cursor come
        // from where the mouse already is, not from where it moves next.
        for view in selectionViews {
            view.syncToCurrentMouseLocation()
        }

        // After the dimming is on screen, on the next turn of the run loop: reading the system's
        // shortcut preferences and the disk is not for the way from the hotkey to the overlay.
        if purpose == .recording {
            DispatchQueue.main.async { [weak self] in self?.runPreflight() }
        }
    }

    /// The overlay over frames already captured — how the tests and the older path show it.
    func begin(
        frames: [CGDirectDisplayID: CapturedFrame],
        capturedWindows: [CapturedWindow] = [],
        purpose: OverlayPurpose = .screenshot,
        completion: @escaping (Selection?) -> Void
    ) {
        begin(capturedWindows: capturedWindows, purpose: purpose, completion: completion)
        deliver(frames: frames)
    }

    /// The frozen frames arrived: each goes under its overlay, and a selection made meanwhile is
    /// cut out of them now.
    func deliver(frames: [CGDirectDisplayID: CapturedFrame]) {
        guard isActive else {
            Self.logger.notice("frames arrived after the overlay closed: dropped")
            return
        }
        self.frames = frames
        hasFrames = true
        for window in windows {
            guard
                let screen = window.screen,
                let displayID = Self.displayID(of: screen),
                let frame = frames[displayID]
            else { continue }
            window.frameView.image = NSImage(cgImage: frame.image, size: screen.frame.size)
            window.selectionView?.frameImage = frame.image
            window.selectionView?.scale = frame.scale
        }
        let since = OverlayDiagnostics.sincePress()
        Self.logger.notice("frames delivered +\(since, privacy: .public) ms")
        OverlayDiagnostics.compareFrontAppWindows("at the frame")

        if let pending = pendingSelection {
            pendingSelection = nil
            Self.logger.notice("cutting the selection made before the frames")
            selectionView(pending.view, didSelect: pending.rect, windowID: pending.windowID)
        }
    }

    /// The frames could not be captured: the overlay goes, and the caller shows why.
    func fail() {
        guard isActive else { return }
        Self.logger.error("overlay closed: the frames never came")
        finish(with: nil)
    }

    func dismiss() {
        Self.logger.notice("overlay dismissed")
        OverlayDiagnostics.ended()
        // Not synced back: the overlay is going, and a sync would start the level meter again.
        stopEcho(resync: false)
        stopLevelMeter()
        OverlayHUD.hide()
        for window in windows {
            window.orderOut(nil)
            window.clear()
        }
        windows.removeAll()
        // A frame of a whole Retina display is tens of megabytes; there is no point holding it
        // until the next capture — the cut-out region already went to the editor as its own copy.
        frames.removeAll()
        hasFrames = false
        pendingSelection = nil
        completion = nil
        previousApp = nil
        NSCursor.arrow.set()
    }

    // MARK: - SelectionViewDelegate

    func selectionView(_ view: SelectionView, didSelect rect: CGRect, windowID: CGWindowID?) {
        // Released before the frames arrived — a fast flick. The overlay stays until they do.
        guard hasFrames else {
            Self.logger.notice("selection made before the frames: waiting for them")
            pendingSelection = (view, rect, windowID)
            return
        }
        guard
            let window = view.window,
            let screen = window.screen ?? windows.first(where: { $0 === window })?.screen,
            let displayID = Self.displayID(of: screen),
            purpose == .recording || frames[displayID] != nil
        else {
            Self.logger.error("selection dropped: no screen or frame for the overlay it was made on")
            finish(with: nil)
            return
        }

        let primaryMaxY = NSScreen.screens.first.map(\.frame.maxY) ?? 0
        let origin = Self.coreGraphicsOrigin(of: screen, primaryMaxY: primaryMaxY)
        // Coordinates inside the view already run top to bottom; all that's left is to shift them
        // by the screen origin.
        let globalRect = rect.offsetBy(dx: origin.x, dy: origin.y)
        let isWholeDisplay = windowID == nil && view.mode == .screen
        let kind = windowID != nil ? "window" : (isWholeDisplay ? "whole screen" : "region")
        // The toolbar said so before the take (`RecordingPreflight.Problem.zonesIgnored`).
        if windowID != nil || isWholeDisplay, !view.maskZones.isEmpty {
            let dropped = view.maskZones.count
            Self.logger.error("selection: \(dropped, privacy: .public) zone(s) to hide left out, a \(kind, privacy: .public) take has no region to count them from")
        }
        let width = Int(rect.width.rounded())
        let height = Int(rect.height.rounded())
        Self.logger.notice(
            "selection: \(kind, privacy: .public) \(width, privacy: .public)×\(height, privacy: .public) pt on display \(displayID, privacy: .public)"
        )

        finish(with: Selection(
            displayID: displayID,
            rect: globalRect,
            screen: screen,
            frame: frames[displayID],
            windowID: windowID,
            isWholeDisplay: isWholeDisplay,
            // Only a region has a picture to fraction the zones of.
            maskZones: windowID == nil && !isWholeDisplay ? view.maskZones : []
        ))
    }

    /// M, S and X are settings, not a state of one screen: they are stored, and every overlay
    /// and the toolbar follow.
    func selectionView(_ view: SelectionView, didToggle option: RecordingOverlayKey) {
        let settings = Settings.shared
        switch option {
        case .microphone:
            // A check of a microphone that has just been switched off would go on unseen.
            stopEcho()
            settings.recordsMicrophone.toggle()
        case .systemAudio:
            settings.recordsSystemAudio.toggle()
        case .scale:
            settings.recordsAtNativeResolution = view.nativeResolution
            for other in selectionViews where other !== view {
                other.nativeResolution = view.nativeResolution
            }
        case .profile:
            applyProfile(RecordingProfile.next(after: RecordingProfile.current(in: settings)), by: "P")
            return
        case .hideZone:
            // Not a setting: the view says its zones changed, and the toolbar follows.
            syncRecordingBar()
            return
        case .start, .aspect:
            break
        }
        let mic = settings.recordsMicrophone
        let system = settings.recordsSystemAudio
        let native = settings.recordsAtNativeResolution
        Self.logger.notice(
            "overlay option \(String(describing: option), privacy: .public) → mic \(mic, privacy: .public), system audio \(system, privacy: .public), native \(native, privacy: .public)"
        )
        syncRecordingBar()
    }

    // MARK: - Recording toolbar

    /// The overlay that holds the toolbar — the one on the screen the cursor is on.
    private var toolbarView: SelectionView? {
        OverlayHUD.recordingBarHost.superview as? SelectionView
    }

    private func prepareRecordingBar() {
        let bar = OverlayHUD.recordingBar
        let settings = Settings.shared
        bar.mode = .region
        bar.optionsShown = false
        bar.hoverPoint = nil
        bar.level = 0
        bar.microphoneIsSilent = false
        // The last overlay's list: a device unplugged since would stay ticked until Options open.
        bar.microphones = []
        bar.microphoneID = nil
        bar.zoneCount = 0
        bar.isMarkingZones = false
        bar.takenShortcuts = []
        bar.freeBytes = nil
        bar.echoPhase = .idle
        bar.setMode = { [weak self] mode in
            Self.logger.notice("toolbar: mode \(String(describing: mode), privacy: .public) pressed")
            self?.switchAll(to: mode)
        }
        bar.toggleOptions = { [weak self] in self?.toggleOptions() }
        bar.chooseMicrophone = { [weak self] device in
            let described = device ?? "none"
            Self.logger.notice("options: microphone \(described, privacy: .public) picked")
            settings.recordsMicrophone = device != nil
            if let device {
                settings.microphoneDeviceID = device
            }
            // A different microphone is a different thing to listen to.
            self?.stopEcho()
            self?.stopLevelMeter()
            self?.syncRecordingBar()
        }
        bar.toggleEcho = { [weak self] in self?.toggleEcho() }
        bar.chooseProfile = { [weak self] profile in self?.applyProfile(profile, by: "Options") }
        bar.toggleZoneMarking = { [weak self] in
            guard let view = self?.viewWithRegion else {
                Self.logger.notice("options: hide a zone pressed with no region to hide it in")
                return
            }
            view.setMarkingZones(!view.isMarkingZones, by: "Options")
        }
        bar.clearZones = { [weak self] in
            guard let view = self?.viewWithRegion else {
                Self.logger.error("options: clear zones pressed with no region holding any")
                return
            }
            view.clearZones(because: "Options")
        }
        bar.toggleSystemAudio = { [weak self] in self?.toggleFromBar(.systemAudio) }
        bar.toggleScale = { [weak self] in
            guard let self, let view = toolbarView else {
                Self.logger.error("options: scale pressed, but the toolbar is in no overlay")
                return
            }
            Self.logger.notice("options: scale pressed")
            view.nativeResolution.toggle()
            selectionView(view, didToggle: .scale)
        }
        bar.toggleClicks = { [weak self] in
            settings.showsClicks.toggle()
            let clicks = settings.showsClicks
            Self.logger.notice("options: clicks in the video → \(clicks, privacy: .public)")
            self?.syncRecordingBar()
        }
        bar.toggleKeystrokes = { [weak self] in
            settings.showsKeystrokes.toggle()
            let keys = settings.showsKeystrokes
            Self.logger.notice("options: pressed shortcuts in the video → \(keys, privacy: .public)")
            self?.syncRecordingBar()
        }
        // A region is recorded from the screen that holds it (`viewWithRegion`); a window or the
        // whole screen from the one the toolbar is on, where the cursor is.
        bar.start = { [weak self] in
            Self.logger.notice("toolbar: Record pressed")
            guard let self, let toolbar = toolbarView else {
                Self.logger.error("toolbar: Record pressed, but the toolbar is in no overlay")
                return
            }
            let view = toolbar.mode == .region ? (viewWithRegion ?? toolbar) : toolbar
            if view !== toolbar {
                Self.logger.notice("toolbar: Record takes the region on another screen, the one last pressed on")
            }
            view.commitRecording()
        }
        syncRecordingBar()
    }

    /// Works out what is wrong with the take before it starts — a shortcut of the take that macOS
    /// still holds, little room on the disk — and hands it to the toolbar, which shows a line for
    /// each. The microphone's part arrives on its own, from the level meter.
    private func runPreflight() {
        guard isActive, purpose == .recording else { return }
        let settings = Settings.shared
        let bindings: [(action: String, binding: HotKeyBinding?)] = [
            (String(localized: "stop recording"), settings.recordRegionHotKey),
            (String(localized: "stop a full-screen recording"), settings.recordFullScreenHotKey),
            (String(localized: "restart"), settings.restartHotKey),
            (String(localized: "pen"), settings.penHotKey),
            (String(localized: "bad take"), settings.badTakeHotKey),
            (String(localized: "spotlight"), settings.spotlightHotKey),
            (String(localized: "hide the picture"), settings.blurHotKey),
            (String(localized: "mute the microphone"), settings.muteHotKey),
        ]
        let taken = RecordingPreflight.taken(bindings: bindings, by: SystemScreenshotShortcuts.current())

        // Where the take will be written, so the volume is the right one.
        var free: Int64?
        do {
            let values = try FileManager.default.temporaryDirectory
                .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            free = values.volumeAvailableCapacityForImportantUsage
        } catch {
            Self.logger.error("preflight: the free space can't be read: \(String(describing: error), privacy: .public)")
        }

        let bar = OverlayHUD.recordingBar
        bar.takenShortcuts = taken
        bar.freeBytes = free
        let found = bar.problems.map(\.logDescription).joined(separator: "; ")
        let freeDescribed = free.map { "\($0) B" } ?? "unknown"
        Self.logger.notice(
            "preflight: \(bar.problems.count, privacy: .public) problem(s) [\(found, privacy: .public)], free \(freeDescribed, privacy: .public)"
        )
        // A line appearing changes the toolbar's size, and its frame is set by hand.
        relayOutToolbar()
    }

    private func toggleFromBar(_ option: RecordingOverlayKey) {
        Self.logger.notice("options: \(String(describing: option), privacy: .public) pressed")
        guard let view = toolbarView else {
            Self.logger.error("options: \(String(describing: option), privacy: .public) pressed, but the toolbar is in no overlay")
            return
        }
        selectionView(view, didToggle: option)
    }

    /// Opens or closes the Options panel. Opening it is when the microphones are listed: asking
    /// the system for them is not something to do between the hotkey and the dimming.
    private func toggleOptions() {
        let bar = OverlayHUD.recordingBar
        bar.optionsShown.toggle()
        let shown = bar.optionsShown
        if shown {
            bar.microphones = MicrophoneDevices.all()
            syncRecordingBar()
        } else {
            // Its button is inside the panel: closed, a check would go on with no way to stop it.
            stopEcho()
        }
        let count = bar.microphones.count
        Self.logger.notice("options \(shown ? "opened" : "closed", privacy: .public), \(count, privacy: .public) microphone(s)")
        // The panel changes the toolbar's size, and its frame is set by hand: once SwiftUI has
        // taken the change in, the overlay lays it out again.
        relayOutToolbar()
    }

    /// One screen's mode for every screen, the toolbar and the hints.
    private func switchAll(to mode: SelectionView.Mode) {
        if mode == .window {
            refreshWindows(reason: "window mode")
        }
        for view in selectionViews {
            view.apply(mode: mode)
        }
        OverlayHUD.hints.mode = mode
        OverlayHUD.recordingBar.mode = mode
        Self.logger.notice("overlay mode → \(String(describing: mode), privacy: .public)")
        // The zones' warning comes and goes with the mode.
        relayOutToolbar()
    }

    /// The recording overlay sits over the live screen, so the list taken at the hotkey goes stale
    /// as windows move under it. Read again — a couple of ms of `CGWindowList` — on each press
    /// and on entering window mode. Never for a screenshot: its list matches its frozen frame, and
    /// no window-server call belongs between its hotkey and its frame.
    private func refreshWindows(reason: String) {
        guard isActive, purpose == .recording else { return }
        let old = selectionViews.first?.windows ?? []
        let fresh = ScreenCaptureService.onScreenWindows()
        for view in selectionViews {
            view.windows = fresh
        }
        let changed = Self.changedWindows(from: old, to: fresh)
        Self.logger.notice(
            "window list refreshed (\(reason, privacy: .public)): \(old.count, privacy: .public) → \(fresh.count, privacy: .public) windows, \(changed, privacy: .public) moved or new"
        )
    }

    /// How many windows of `new` were not in `old` where they are now.
    nonisolated static func changedWindows(from old: [CapturedWindow], to new: [CapturedWindow]) -> Int {
        let before = Dictionary(old.map { ($0.windowID, $0.frame) }, uniquingKeysWith: { first, _ in first })
        return new.count { before[$0.windowID] != $0.frame }
    }

    /// A profile picked with P or in Options: written into the ordinary settings, then every
    /// screen and the toolbar follow, as they do for M, S and X.
    private func applyProfile(_ profile: RecordingProfile, by source: String) {
        let settings = Settings.shared
        profile.apply(to: settings)
        for view in selectionViews {
            view.nativeResolution = settings.recordsAtNativeResolution
        }
        let mic = settings.recordsMicrophone
        let system = settings.recordsSystemAudio
        let native = settings.recordsAtNativeResolution
        let preset = settings.videoPreset.rawValue
        Self.logger.notice(
            "profile \(profile.rawValue, privacy: .public) picked by \(source, privacy: .public) → mic \(mic, privacy: .public), system audio \(system, privacy: .public), native \(native, privacy: .public), format \(preset, privacy: .public)"
        )
        // The microphone may have just been turned on or off; the meter and the echo follow it.
        stopEcho()
        syncRecordingBar()
    }

    /// "Check the microphone": three seconds of listening, then the same three seconds back. Pressed
    /// again while it runs, it stops. The level meter steps aside for it (both would hold the
    /// input), and comes back by itself when the echo is over.
    private func toggleEcho() {
        let bar = OverlayHUD.recordingBar
        if echo != nil {
            Self.logger.notice("options: microphone check stopped by the person")
            stopEcho()
            return
        }
        let settings = Settings.shared
        guard settings.recordsMicrophone, MicrophonePermission.isGranted else {
            Self.logger.error("options: microphone check pressed without a microphone on and allowed")
            return
        }
        Self.logger.notice("options: microphone check started")
        stopLevelMeter()
        echoRun += 1
        let mine = echoRun
        let check = MicrophoneEcho(deviceUID: settings.microphoneDeviceID) { [weak self] phase in
            guard let self, echoRun == mine else { return }
            OverlayHUD.recordingBar.echoPhase = phase
            if phase == .idle {
                echo = nil
                syncRecordingBar()
            }
            relayOutToolbar()
        }
        echo = check
        bar.echoPhase = .listening
        check.start()
    }

    private func stopEcho(resync: Bool = true) {
        guard let echo else { return }
        echoRun += 1
        echo.cancel()
        self.echo = nil
        OverlayHUD.recordingBar.echoPhase = .idle
        if resync {
            syncRecordingBar()
        }
    }

    /// The toolbar's frame is set by hand, and SwiftUI changes its size on its own time: a line
    /// above it, a row in Options, a longer caption. Once SwiftUI has taken the change in, the
    /// overlay lays it out again — otherwise the new part hangs past the frame and its clicks go
    /// through to the overlay.
    private func relayOutToolbar() {
        DispatchQueue.main.async { [weak self] in
            self?.toolbarView?.needsDisplay = true
        }
    }

    private func stopLevelMeter() {
        levelMeter?.stop()
        levelMeter = nil
        OverlayHUD.recordingBar.level = 0
        OverlayHUD.recordingBar.microphoneIsSilent = false
    }

    /// Puts the stored settings on the toolbar and runs the level meter exactly while it is
    /// wanted: the microphone on and access already granted. Never asks for access here — the
    /// system prompt would open under the overlay. The recording asks, once the overlay is gone.
    private func syncRecordingBar() {
        let settings = Settings.shared
        let bar = OverlayHUD.recordingBar
        bar.microphoneIsOn = settings.recordsMicrophone
        bar.systemAudioIsOn = settings.recordsSystemAudio
        bar.showsClicks = settings.showsClicks
        bar.showsKeystrokes = settings.showsKeystrokes
        bar.keystrokesAllowed = InputMonitoringPermission.isGranted
        bar.nativeResolution = settings.recordsAtNativeResolution
        bar.profile = RecordingProfile.current(in: settings)
        bar.zoneCount = viewWithRegion?.maskZones.count ?? 0
        bar.isMarkingZones = viewWithRegion?.isMarkingZones ?? false
        bar.canSwitchScale = selectionViews.contains { $0.scale > 1 }
        // Which row is ticked: known only once the list is there, that is, once Options opened.
        if !bar.microphones.isEmpty {
            bar.microphoneID = MicrophoneDevices.resolved(
                stored: settings.microphoneDeviceID,
                among: bar.microphones,
                systemDefault: MicrophoneDevices.systemDefaultID
            )
        }

        bar.canCheckMicrophone = purpose == .recording && settings.recordsMicrophone && MicrophonePermission.isGranted
        // Not while the echo holds the input.
        let wantsMeter = bar.canCheckMicrophone && echo == nil
        if wantsMeter, levelMeter == nil {
            let meter = MicrophoneLevelMeter(deviceUID: settings.microphoneDeviceID) { [weak self] level, silent in
                let changed = OverlayHUD.recordingBar.microphoneIsSilent != silent
                if changed {
                    Self.logger.notice("mic meter: \(silent ? "silent" : "hearing sound", privacy: .public)")
                }
                OverlayHUD.recordingBar.level = level
                OverlayHUD.recordingBar.microphoneIsSilent = silent
                // The "hears nothing" line comes and goes above the toolbar.
                if changed {
                    self?.relayOutToolbar()
                }
            }
            meter.start()
            levelMeter = meter
        } else if !wantsMeter, levelMeter != nil {
            stopLevelMeter()
        }
        relayOutToolbar()
    }

    func selectionViewDidCancel(_: SelectionView) {
        if purpose == .screenshot {
            Stats.shared.add(.cancels)
        }
        let previous = previousApp
        let name = previous?.localizedName ?? "nobody"
        Self.logger.notice("overlay cancelled, focus back to \(name, privacy: .public)")
        finish(with: nil)
        // The overlay never activated Pawshot, so the app in front is normally still in front.
        // Should anything have activated Pawshot meanwhile, the focus goes back all the same.
        if NSApp.isActive, let previous, previous.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previous.activate()
        }
    }

    /// One screen switched modes — the rest follow, otherwise moving the cursor to another display
    /// would silently change what a click does.
    func selectionView(_: SelectionView, didSwitchTo mode: SelectionView.Mode) {
        switchAll(to: mode)
    }

    private func finish(with selection: Selection?) {
        let completion = completion
        if purpose == .recording {
            rememberRegions()
        }
        dismiss()
        completion?(selection)
    }

    /// The region on each display is what the next ⇧⌘3 starts with — however the overlay closed.
    /// It used to be stored only when a take started, so a region moved and then cancelled with
    /// Esc came back where the last take had it.
    private func rememberRegions() {
        let settings = Settings.shared
        for view in selectionViews {
            guard let region = view.recordingRegion else { continue }
            guard let screen = view.window?.screen, let displayID = Self.displayID(of: screen) else {
                Self.logger.error("region not remembered: its overlay has no screen")
                continue
            }
            settings.setLastRecordingArea(region, on: displayID)
            Self.logger.notice(
                "region remembered on display \(displayID, privacy: .public): \(Int(region.width), privacy: .public)×\(Int(region.height), privacy: .public) pt at \(Int(region.minX), privacy: .public),\(Int(region.minY), privacy: .public)"
            )
        }
    }

    // MARK: - Screens

    /// The screen origin in global CoreGraphics coordinates.
    static func coreGraphicsOrigin(of screen: NSScreen, primaryMaxY: CGFloat) -> CGPoint {
        CGPoint(x: screen.frame.minX, y: primaryMaxY - screen.frame.maxY)
    }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
