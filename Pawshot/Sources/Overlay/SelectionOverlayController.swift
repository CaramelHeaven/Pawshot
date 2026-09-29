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
        /// it.
        let frame: CapturedFrame
        /// Set when a whole window was picked: a recording follows the window, not the region.
        var windowID: CGWindowID?
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
    /// The app that was in front when the overlay went up. The overlay never activates Pawshot,
    /// so after a cancel this one is still in front; kept for the log and for safety.
    private var previousApp: NSRunningApplication?

    private var selectionViews: [SelectionView] {
        windows.compactMap(\.selectionView)
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
        guard !isActive else { return }
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
        hasFrames = false
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
            guard let displayID = Self.displayID(of: screen), let window = prepared[displayID] else { continue }

            let view = SelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
            view.delegate = self
            view.screenOrigin = Self.coreGraphicsOrigin(of: screen, primaryMaxY: primaryMaxY)
            view.windows = capturedWindows
            view.scale = screen.backingScaleFactor
            view.showsHints = showsHints
            view.purpose = purpose
            if purpose == .recording {
                view.nativeResolution = settings.recordsAtNativeResolution
                view.ghost = settings.lastRecordingArea(on: displayID)
                    .map { $0.intersection(CGRect(origin: .zero, size: screen.frame.size)) }
                    .flatMap { $0.isEmpty ? nil : $0 }
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
            if screen.frame.contains(mouseLocation) {
                window.makeKey()
                window.makeFirstResponder(view)
            }
            let number = window.windowNumber
            let visible = window.isVisible
            let onSpace = window.isOnActiveSpace
            let key = window.isKeyWindow
            let described = LogExport.describe(screen)
            Self.logger.notice(
                "overlay window \(number, privacy: .public) on \(described, privacy: .public): visible \(visible, privacy: .public), on active space \(onSpace, privacy: .public), key \(key, privacy: .public)"
            )
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
                }
            }
        }

        // The overlay has to be alive the moment it appears: badge, highlight and cursor come
        // from where the mouse already is, not from where it moves next.
        for view in selectionViews {
            view.syncToCurrentMouseLocation()
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
        levelMeter?.stop()
        levelMeter = nil
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
            let frame = frames[displayID]
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

        finish(with: Selection(
            displayID: displayID,
            rect: globalRect,
            screen: screen,
            frame: frame,
            windowID: windowID
        ))
    }

    /// M, S and X are settings, not a state of one screen: they are stored, and every overlay
    /// and the sound bar follow.
    func selectionView(_ view: SelectionView, didToggle option: RecordingOverlayKey) {
        let settings = Settings.shared
        switch option {
        case .microphone:
            settings.recordsMicrophone.toggle()
        case .systemAudio:
            settings.recordsSystemAudio.toggle()
        case .scale:
            settings.recordsAtNativeResolution = view.nativeResolution
            for other in selectionViews where other !== view {
                other.nativeResolution = view.nativeResolution
            }
        case .start, .aspect:
            break
        }
        syncRecordingBar()
    }

    // MARK: - Recording bar

    private func prepareRecordingBar() {
        let bar = OverlayHUD.recordingBar
        bar.level = 0
        bar.microphoneIsSilent = false
        bar.toggleMicrophone = { [weak self] in self?.toggleFromBar(.microphone) }
        bar.toggleSystemAudio = { [weak self] in self?.toggleFromBar(.systemAudio) }
        // The bar lives inside the overlay that has the region; that one records.
        bar.start = {
            Self.logger.notice("sound bar: Record pressed")
            (OverlayHUD.recordingBarHost.superview as? SelectionView)?.commitRecording()
        }
        syncRecordingBar()
    }

    private func toggleFromBar(_ option: RecordingOverlayKey) {
        Self.logger.notice("sound bar: \(String(describing: option), privacy: .public) pressed")
        guard let view = OverlayHUD.recordingBarHost.superview as? SelectionView else { return }
        selectionView(view, didToggle: option)
    }

    /// Puts the stored settings on the bar and runs the level meter exactly while it is wanted:
    /// the microphone on and access already granted. Never asks for access here — the system
    /// prompt would open under the overlay. The recording asks, once the overlay is gone.
    private func syncRecordingBar() {
        let settings = Settings.shared
        let bar = OverlayHUD.recordingBar
        bar.microphoneIsOn = settings.recordsMicrophone
        bar.systemAudioIsOn = settings.recordsSystemAudio

        let wantsMeter = purpose == .recording && settings.recordsMicrophone && MicrophonePermission.isGranted
        if wantsMeter, levelMeter == nil {
            let meter = MicrophoneLevelMeter { level, silent in
                OverlayHUD.recordingBar.level = level
                OverlayHUD.recordingBar.microphoneIsSilent = silent
            }
            meter.start()
            levelMeter = meter
        } else if !wantsMeter, let meter = levelMeter {
            meter.stop()
            levelMeter = nil
            bar.level = 0
            bar.microphoneIsSilent = false
        }
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
    func selectionView(_ view: SelectionView, didSwitchTo mode: SelectionView.Mode) {
        Self.logger.notice("overlay mode → \(String(describing: mode), privacy: .public)")
        for other in selectionViews where other !== view {
            other.apply(mode: mode)
        }
    }

    private func finish(with selection: Selection?) {
        let completion = completion
        dismiss()
        completion?(selection)
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
