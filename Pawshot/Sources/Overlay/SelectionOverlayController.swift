import AppKit
import os

/// Full-screen region selection mode: one window per display.
@MainActor
final class SelectionOverlayController: NSObject, SelectionViewDelegate {
    private static let logger = Logger(subsystem: "com.caramelheaven.pawshot", category: "overlay")

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

    private var windows: [OverlayWindow] = []
    private var frames: [CGDirectDisplayID: CapturedFrame] = [:]
    private var completion: ((Selection?) -> Void)?
    private var purpose: OverlayPurpose = .screenshot
    private var levelMeter: MicrophoneLevelMeter?

    private var selectionViews: [SelectionView] {
        windows.compactMap { $0.contentView as? SelectionView }
    }

    var isActive: Bool {
        !windows.isEmpty
    }

    /// Shows the overlay on top of the already captured frames and waits for a selection.
    ///
    /// The overlay draws a frozen frame rather than the live screen: while the frame is being
    /// dragged, the screen underneath has time to change — activating Pawshot closes other apps'
    /// menus and lists — but in the frame everything stays as it was at the moment of the hotkey.
    /// The result is cut out of that same frame, so nothing has to be captured after the selection
    /// and the overlay closes immediately.
    ///
    /// - Parameters:
    ///   - frames: one frame per display. A screen without a frame gets no overlay.
    ///   - capturedWindows: the window list frozen at the same moment, for the window mode.
    func begin(
        frames: [CGDirectDisplayID: CapturedFrame],
        capturedWindows: [CapturedWindow] = [],
        purpose: OverlayPurpose = .screenshot,
        completion: @escaping (Selection?) -> Void
    ) {
        guard !isActive else { return }
        self.completion = completion
        self.frames = frames
        self.purpose = purpose

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

        for screen in NSScreen.screens {
            guard
                let displayID = Self.displayID(of: screen),
                let frame = frames[displayID]
            else { continue }

            let window = OverlayWindow(screen: screen)
            let view = SelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
            view.autoresizingMask = [.width, .height]
            view.delegate = self
            view.screenOrigin = Self.coreGraphicsOrigin(of: screen, primaryMaxY: primaryMaxY)
            view.windows = capturedWindows
            view.background = NSImage(cgImage: frame.image, size: screen.frame.size)
            view.frameImage = frame.image
            view.scale = frame.scale
            view.showsHints = showsHints
            view.purpose = purpose
            if purpose == .recording {
                view.nativeResolution = settings.recordsAtNativeResolution
                view.ghost = settings.lastRecordingArea(on: displayID)
                    .map { $0.intersection(CGRect(origin: .zero, size: screen.frame.size)) }
                    .flatMap { $0.isEmpty ? nil : $0 }
            }
            window.contentView = view
            windows.append(window)

            window.orderFrontRegardless()
            // The screen under the cursor becomes key — that's where Esc and the first click go.
            if screen.frame.contains(mouseLocation) {
                window.makeKey()
                window.makeFirstResponder(view)
            }
        }

        // Without activation an accessory app gets no keyboard, and Esc stops working.
        NSApp.activate()
        // macOS 14+ activation is cooperative and may be refused; whether it was decides whether
        // the first click on the overlay's buttons does anything. Logged a moment later, once
        // the answer is in.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, isActive else { return }
            let key = windows.contains(where: \.isKeyWindow)
            Self.logger.info("overlay up: app active \(NSApp.isActive, privacy: .public), key window \(key, privacy: .public)")
        }

        // The overlay has to be alive the moment it appears: badge, highlight and cursor come
        // from where the mouse already is, not from where it moves next.
        for view in selectionViews {
            view.syncToCurrentMouseLocation()
        }
    }

    func dismiss() {
        levelMeter?.stop()
        levelMeter = nil
        OverlayHUD.hide()
        for window in windows {
            window.orderOut(nil)
        }
        windows.removeAll()
        // A frame of a whole Retina display is tens of megabytes; there is no point holding it
        // until the next capture — the cut-out region already went to the editor as its own copy.
        frames.removeAll()
        completion = nil
        NSCursor.arrow.set()
    }

    // MARK: - SelectionViewDelegate

    func selectionView(_ view: SelectionView, didSelect rect: CGRect, windowID: CGWindowID?) {
        guard
            let window = view.window,
            let screen = window.screen ?? windows.first(where: { $0 === window })?.screen,
            let displayID = Self.displayID(of: screen),
            let frame = frames[displayID]
        else {
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
            Self.logger.info("sound bar: Record pressed")
            (OverlayHUD.recordingBarHost.superview as? SelectionView)?.commitRecording()
        }
        syncRecordingBar()
    }

    private func toggleFromBar(_ option: RecordingOverlayKey) {
        Self.logger.info("sound bar: \(String(describing: option), privacy: .public) pressed")
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
        finish(with: nil)
    }

    /// One screen switched modes — the rest follow, otherwise moving the cursor to another display
    /// would silently change what a click does.
    func selectionView(_ view: SelectionView, didSwitchTo mode: SelectionView.Mode) {
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
