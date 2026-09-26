import AppKit
import Carbon.HIToolbox
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let logger = Logger(subsystem: "com.caramelheaven.pawshot", category: "app")

    private let overlayController = SelectionOverlayController()
    let recordingController = RecordingController()
    private let settings = Settings.shared
    private let state = AppState.shared
    private var regionHotKey: GlobalHotKey?
    private var fullScreenHotKey: GlobalHotKey?
    private var recordRegionHotKey: GlobalHotKey?
    private var recordFullScreenHotKey: GlobalHotKey?
    /// While frames are being captured there is no overlay yet, so a second press would start
    /// a second capture.
    private var isCapturing = false

    func applicationDidFinishLaunching(_: Notification) {
        // A background utility: it lives in the menu bar and shows windows on demand. The menu
        // bar item, the main menu and the small windows are SwiftUI scenes in `PawshotApp`.
        NSApp.setActivationPolicy(.accessory)
        replaceOlderInstances()

        settings.onHotKeysChange = { [weak self] in self?.registerHotKeys() }
        settings.onHotKeyRecordingChange = { [weak self] isRecording in
            // Carbon hands a registered hotkey to us before any view sees the key press, so while
            // the user is typing a new combination the old ones must not exist.
            if isRecording {
                self?.unregisterHotKeys()
            } else {
                self?.registerHotKeys()
            }
        }
        registerHotKeys()
        recordingController.onRecorded = { movie, size, screen in
            VideoEditorWindowController(movieURL: movie, videoSize: size, on: screen).show()
        }
        recordingController.onFailure = { [weak self] error in
            self?.presentFailure(error, title: "The recording ran into a problem")
        }

        // The first capture of a session is the slow one; pay for it now, while nobody waits.
        ScreenCaptureService.beginObservingDisplayChanges()
        Task { await ScreenCaptureService.warmUp() }
        SelectionView.prepareCursors()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        false
    }

    /// Two copies of Pawshot — the installed one and a fresh Debug build, say — both register ⇧⌘2
    /// (Carbon lets them), and one press then puts up two overlays that fight over the mouse: the
    /// capture ends in neither editor. The newest launch wins: older copies are asked to quit.
    ///
    /// Not under tests: the test host is this app, and it must not close the owner's running copy.
    private func replaceOlderInstances() {
        let environment = ProcessInfo.processInfo.environment
        let isTestHost = ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier"]
            .contains { environment[$0] != nil }
        guard !isTestHost, let bundleID = Bundle.main.bundleIdentifier else { return }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        for other in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            where other.processIdentifier != ownPID
        {
            Self.logger.info("asking an older Pawshot (pid \(other.processIdentifier, privacy: .public)) to quit")
            other.terminate()
        }
    }

    // MARK: - Hotkeys

    /// Re-registers every hotkey from the current settings — also how a shortcut gets replaced.
    ///
    /// The old ones are dropped first: dropping a `GlobalHotKey` is what unregisters it, and Carbon
    /// refuses a combination this app still holds. Assigning over the old one would register the
    /// new object while the old is alive, and an unchanged shortcut — ⇧⌘2 when only ⇧⌘3 was edited
    /// — would fail against itself and be lost.
    private func registerHotKeys() {
        unregisterHotKeys()
        regionHotKey = Self.register(settings.regionHotKey) { [weak self] in
            self?.beginCapture()
        }
        fullScreenHotKey = Self.register(settings.fullScreenHotKey) { [weak self] in
            self?.beginFullScreenCapture()
        }
        recordRegionHotKey = Self.register(settings.recordRegionHotKey) { [weak self] in
            self?.beginRegionRecording()
        }
        recordFullScreenHotKey = Self.register(settings.recordFullScreenHotKey) { [weak self] in
            self?.beginFullScreenRecording()
        }
    }

    private func unregisterHotKeys() {
        regionHotKey = nil
        fullScreenHotKey = nil
        recordRegionHotKey = nil
        recordFullScreenHotKey = nil
    }

    private static func register(
        _ binding: HotKeyBinding,
        action: @escaping () -> Void
    ) -> GlobalHotKey? {
        do {
            return try GlobalHotKey.register(binding, action: action)
        } catch {
            // The settings window explains this to the user; here it is only worth a log line.
            logger.error("hotkey \(binding.displayString) not registered: \(error)")
            return nil
        }
    }

    // MARK: - Capture

    func beginCapture() {
        startCapture { [weak self] frames in
            await self?.selectRegion(in: frames) { selection in
                self?.openEditor(for: selection)
            }
        }
    }

    /// The whole screen, straight into the editor: no overlay, no selection. The frame of the
    /// display under the cursor is already captured in full, so the shot is just its crop — and
    /// the edges can still be dragged in afterwards.
    func beginFullScreenCapture() {
        startCapture { [weak self] frames in
            self?.openEditorForWholeDisplay(from: frames)
        }
    }

    /// Everything both capture paths share: the guard against a second run, the permission check
    /// and freezing every display before anything appears on screen.
    private func startCapture(then handle: @escaping ([CGDirectDisplayID: CapturedFrame]) async -> Void) {
        guard !isCapturing, !overlayController.isActive else { return }
        // Check the permission before the overlay: otherwise the region is selected for nothing.
        guard ScreenRecordingPermission.ensureGranted() else { return }

        isCapturing = true
        state.isCapturing = true
        let pressed = Date()
        Task {
            if let frames = await freezeDisplays() {
                await handle(frames)
                // The number that matters: everything between the hotkey and something visible.
                let elapsed = Int(Date().timeIntervalSince(pressed) * 1000)
                Self.logger.info("ready \(elapsed, privacy: .public) ms after the hotkey")
            } else {
                state.isCapturing = false
            }
            isCapturing = false
        }
    }

    /// Capture the screen first, and only then show anything of our own.
    ///
    /// The order is the whole point here: the overlay activates Pawshot, and that closes an open
    /// menu or dropdown in whatever app was in front. A frame captured before the activation
    /// catches them alive — the region is then selected on a frozen picture.
    private func freezeDisplays() async -> [CGDirectDisplayID: CapturedFrame]? {
        let displayIDs = NSScreen.screens.compactMap(SelectionOverlayController.displayID(of:))
        let started = Date()

        do {
            let frames = try await ScreenCaptureService.captureDisplays(displayIDs)
            // This pause sits between the hotkey and the crosshair, so the hand can feel it.
            let elapsed = Int(Date().timeIntervalSince(started) * 1000)
            Self.logger.info(
                "freeze took \(elapsed, privacy: .public) ms for \(frames.count) display(s)"
            )

            return frames
        } catch {
            // Failures used to surface after the region was selected — now they surface before it.
            Self.logger.error("freeze failed: \(error.localizedDescription)")
            presentCaptureFailure(error)
            return nil
        }
    }

    private func selectRegion(
        in frames: [CGDirectDisplayID: CapturedFrame],
        purpose: OverlayPurpose = .screenshot,
        then use: @escaping (SelectionOverlayController.Selection) -> Void
    ) async {
        // The window list is taken here, still before the overlay is up: once it is, our own
        // full-screen window is the one under the cursor.
        let capturedWindows = ScreenCaptureService.onScreenWindows()

        overlayController.begin(
            frames: frames,
            capturedWindows: capturedWindows,
            purpose: purpose
        ) { [weak self] selection in
            guard let self else { return }
            state.isCapturing = false
            guard let selection else { return }
            use(selection)
        }
    }

    /// Opens the editor on the display the cursor is on, showing all of it.
    private func openEditorForWholeDisplay(from frames: [CGDirectDisplayID: CapturedFrame]) {
        state.isCapturing = false
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main

        guard
            let screen,
            let displayID = SelectionOverlayController.displayID(of: screen),
            let frame = frames[displayID]
        else {
            Self.logger.error("full screen capture failed: no frame for the display under cursor")
            presentCaptureFailure(ScreenCaptureError.cropFailed)
            return
        }

        openEditor(
            frame: frame,
            crop: CGRect(origin: .zero, size: frame.displayFrame.size),
            on: screen
        )
    }

    /// Hands the frozen frame to the editor together with the region to show.
    ///
    /// The whole frame goes along, not just the cutout: the editor lets the shot be resized later,
    /// and the pixels around the selection are exactly what makes that possible.
    private func openEditor(for selection: SelectionOverlayController.Selection) {
        let frame = selection.frame
        let crop = SelectionGeometry
            .sourceRect(displayRect: selection.rect, displayFrame: frame.displayFrame)
            .intersection(CGRect(origin: .zero, size: frame.displayFrame.size))

        openEditor(frame: frame, crop: crop, on: selection.screen)
    }

    private func openEditor(
        frame: CapturedFrame,
        crop: CGRect,
        on screen: NSScreen
    ) {
        guard
            !crop.isEmpty,
            let document = EditorDocument(frame: frame, cropRect: crop)
        else {
            Self.logger.error("crop failed: the region is outside the captured frame")
            presentCaptureFailure(ScreenCaptureError.cropFailed)
            return
        }

        EditorWindowController(document: document, on: screen).show()
        settings.recordCapture()
    }

    // MARK: - Recording

    /// ⇧⌘3: pick a region on the overlay, then record it. Pressed again while recording, it stops —
    /// the same key starts and ends a take.
    func beginRegionRecording() {
        guard !recordingController.isActive else {
            recordingController.stop()
            return
        }
        // The overlay activates Pawshot; whatever the user was recording must be back in front
        // when the recording starts.
        let previous = NSWorkspace.shared.frontmostApplication
        startCapture { [weak self] frames in
            await self?.selectRegion(in: frames, purpose: .recording) { selection in
                self?.startRecording(
                    RecordingTarget(
                        displayID: selection.displayID,
                        rect: selection.rect,
                        screen: selection.screen,
                        windowID: selection.windowID
                    ),
                    returningTo: previous
                )
                if selection.windowID == nil {
                    self?.rememberRecordingArea(of: selection)
                }
            }
        }
    }

    /// The ghost the next ⇧⌘3 shows: this region, in the display's own points.
    private func rememberRecordingArea(of selection: SelectionOverlayController.Selection) {
        let primaryMaxY = NSScreen.screens.first.map(\.frame.maxY) ?? 0
        let origin = SelectionOverlayController.coreGraphicsOrigin(of: selection.screen, primaryMaxY: primaryMaxY)
        settings.setLastRecordingArea(
            selection.rect.offsetBy(dx: -origin.x, dy: -origin.y),
            on: selection.displayID
        )
    }

    /// ⇧⌘4: the display under the cursor, at once — no overlay, the way ⇧⌘1 takes a shot.
    func beginFullScreenRecording() {
        guard !recordingController.isActive else {
            recordingController.stop()
            return
        }
        guard !isCapturing, !overlayController.isActive, ScreenRecordingPermission.ensureGranted() else { return }

        let mouse = NSEvent.mouseLocation
        guard
            let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main,
            let displayID = SelectionOverlayController.displayID(of: screen)
        else { return }

        startRecording(RecordingTarget(displayID: displayID, rect: nil, screen: screen), returningTo: nil)
    }

    func stopRecording() {
        recordingController.stop()
    }

    func toggleRecordingPause() {
        recordingController.togglePause()
    }

    func restartRecording() {
        recordingController.restart()
    }

    private func startRecording(_ target: RecordingTarget, returningTo previous: NSRunningApplication?) {
        if let previous, previous.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previous.activate()
        }
        Task {
            do {
                try await recordingController.start(target)
            } catch {
                Self.logger.error("recording not started: \(error.localizedDescription, privacy: .public)")
                presentFailure(error, title: "Couldn't start recording")
            }
        }
    }

    private func presentCaptureFailure(_ error: Error) {
        presentFailure(error, title: "Couldn't capture the region")
    }

    private func presentFailure(_ error: Error, title: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        NSApp.activate()
        alert.runModal()
    }
}
