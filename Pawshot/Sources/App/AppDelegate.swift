import AppKit
import Carbon.HIToolbox
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static var logger: Logger {
        .pawshot("app")
    }

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
        logLaunch()
        replaceOlderInstances()
        if !Self.isTestHost {
            Updater.start()
        }

        settings.onHotKeysChange = { [weak self] in self?.registerHotKeys() }
        LabelFont.family = settings.labelFontFamily
        settings.onLabelFontChange = { [settings] in
            LabelFont.family = settings.labelFontFamily
            EditorWindowController.labelFontDidChange()
        }
        settings.onToolsPlacementChange = {
            EditorWindowController.toolsPlacementDidChange()
        }
        settings.onHotKeyRecordingChange = { [weak self] isRecording in
            // Carbon hands a registered hotkey to us before any view sees the key press, so while
            // the user is typing a new combination the old ones must not exist.
            Self.logger.notice("shortcut field \(isRecording ? "started" : "stopped", privacy: .public) recording")
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
            self?.presentFailure(error, title: String(localized: "The recording ran into a problem"))
        }

        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                let since = OverlayDiagnostics.sincePressNote()
                Self.logger.notice("active space changed\(since, privacy: .public)")
            }
        }

        // The first capture of a session is the slow one; pay for it now, while nobody waits.
        ScreenCaptureService.beginObservingDisplayChanges()
        prepareOverlay()
        Task { await ScreenCaptureService.warmUp() }
        SelectionView.prepareCursors()
    }

    func applicationWillTerminate(_: Notification) {
        Self.logger.notice("quitting")
    }

    // Whether activation arrives, and when relative to the hotkey: the overlay asks for it, and
    // macOS 14+ may grant it late or not at all. `+N ms` is from the last capture's hotkey.

    func applicationDidBecomeActive(_: Notification) {
        let since = OverlayDiagnostics.sincePressNote()
        Self.logger.notice("app became active\(since, privacy: .public)")
    }

    func applicationDidResignActive(_: Notification) {
        let since = OverlayDiagnostics.sincePressNote()
        Self.logger.notice("app resigned active\(since, privacy: .public)")
    }

    private var spaceObserver: NSObjectProtocol?

    /// What a saved log has to open with: which build, on what, allowed to do what.
    private func logLaunch() {
        let facts = LogExport.currentFacts()
        if let started = SystemState.processStart {
            let held = Int(Date().timeIntervalSince(started) * 1000)
            Self.logger.notice("launch: finished \(held, privacy: .public) ms after the process started")
        }
        Self.logger.notice(
            "launch: Pawshot \(facts.version, privacy: .public) (\(facts.build, privacy: .public)), macOS \(facts.macOS, privacy: .public), \(facts.model, privacy: .public), at \(facts.bundlePath, privacy: .public)"
        )
        Self.logger.notice(
            "launch: displays \(facts.displays.joined(separator: "; "), privacy: .public); screen recording \(facts.screenRecording, privacy: .public), microphone \(facts.microphone, privacy: .public), input monitoring \(facts.inputMonitoring, privacy: .public)"
        )
        Self.logger.notice(
            "launch: \(facts.hardware, privacy: .public); \(facts.system, privacy: .public); other capture apps: \(facts.otherCaptureAppsText, privacy: .public)"
        )
        for hotKey in facts.hotKeys where hotKey.takenBy != nil {
            Self.logger.error(
                "launch: \(hotKey.name, privacy: .public) \(hotKey.shortcut, privacy: .public) is taken by macOS (\(hotKey.takenBy ?? "", privacy: .public)) — Pawshot never sees it"
            )
        }
    }

    /// The overlay's windows exist before the first hotkey: creating them was part of the wait.
    func prepareOverlay() {
        overlayController.prepareWindows()
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
        guard !Self.isTestHost, let bundleID = Bundle.main.bundleIdentifier else {
            Self.logger.notice("older copies: not checked (test host)")
            return
        }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        for other in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            where other.processIdentifier != ownPID
        {
            Self.logger.notice("asking an older Pawshot (pid \(other.processIdentifier, privacy: .public)) to quit")
            other.terminate()
        }
    }

    /// The unit tests run inside this app, so whatever reaches outside it — other running copies,
    /// the update feed, the welcome window — has to know.
    static let isTestHost = {
        let environment = ProcessInfo.processInfo.environment
        return ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier"]
            .contains { environment[$0] != nil }
    }()

    // MARK: - Hotkeys

    /// Re-registers every hotkey from the current settings — also how a shortcut gets replaced.
    ///
    /// The old ones are dropped first: dropping a `GlobalHotKey` is what unregisters it, and Carbon
    /// refuses a combination this app still holds. Assigning over the old one would register the
    /// new object while the old is alive, and an unchanged shortcut — ⇧⌘2 when only ⇧⌘3 was edited
    /// — would fail against itself and be lost.
    private func registerHotKeys() {
        unregisterHotKeys()
        let shortcuts = [
            "region \(settings.regionHotKey.logString)",
            "full screen \(settings.fullScreenHotKey.logString)",
            "record region \(settings.recordRegionHotKey.logString)",
            "record full screen \(settings.recordFullScreenHotKey.logString)",
        ].joined(separator: ", ")
        Self.logger.notice("registering hotkeys: \(shortcuts, privacy: .public)")
        regionHotKey = Self.register(settings.regionHotKey) { [weak self] in
            Self.logger.notice("hotkey pressed: capture a region")
            self?.beginCapture()
        }
        fullScreenHotKey = Self.register(settings.fullScreenHotKey) { [weak self] in
            Self.logger.notice("hotkey pressed: capture the full screen")
            self?.beginFullScreenCapture()
        }
        recordRegionHotKey = Self.register(settings.recordRegionHotKey) { [weak self] in
            Self.logger.notice("hotkey pressed: record a region")
            self?.beginRegionRecording()
        }
        recordFullScreenHotKey = Self.register(settings.recordFullScreenHotKey) { [weak self] in
            Self.logger.notice("hotkey pressed: record the full screen")
            self?.beginFullScreenRecording()
        }
    }

    private func unregisterHotKeys() {
        Self.logger.notice("unregistering hotkeys")
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
            logger.error("hotkey \(binding.logString, privacy: .public) not registered: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    // MARK: - Capture

    func beginCapture() {
        startOverlayCapture(purpose: .screenshot) { [weak self] selection in
            self?.openEditor(for: selection)
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
        let pressed = Date()
        let warmingUp = ScreenCaptureService.isWarmingUp
        if warmingUp {
            Self.logger.notice("capture asked while the launch warm-up is still running")
        }
        guard !isCapturing, !overlayController.isActive else {
            let reason = isCapturing ? "a capture is still freezing the screen" : "the overlay is already up"
            Self.logger.notice("capture ignored: \(reason, privacy: .public)")
            return
        }
        // Check the permission before the overlay: otherwise the region is selected for nothing.
        guard ScreenRecordingPermission.ensureGranted() else {
            Self.logger.notice("capture refused: no screen recording access")
            return
        }

        isCapturing = true
        state.isCapturing = true
        OverlayDiagnostics.pressed(at: pressed)
        Task {
            let started = OverlayDiagnostics.sincePress()
            Self.logger.notice("capture task started +\(started, privacy: .public) ms")
            if let frames = await freezeDisplays() {
                let frozen = OverlayDiagnostics.sincePress()
                Self.logger.notice("freeze done +\(frozen, privacy: .public) ms")
                await handle(frames)
                // The number that matters: everything between the hotkey and something visible.
                let elapsed = Int(Date().timeIntervalSince(pressed) * 1000)
                Self.logger.notice("ready \(elapsed, privacy: .public) ms after the hotkey")
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
            Self.logger.notice(
                "freeze took \(elapsed, privacy: .public) ms for \(frames.count) display(s)"
            )

            return frames
        } catch {
            // Failures used to surface after the region was selected — now they surface before it.
            Self.logger.error("freeze failed: \(String(describing: error), privacy: .public)")
            presentCaptureFailure(error)
            return nil
        }
    }

    /// A region or a window, picked on the overlay — for a shot or for a recording.
    ///
    /// The overlay goes up first, over the live screen, and the frames are captured behind it with
    /// the overlay left out: the dimming appears the instant the hotkey is pressed instead of after
    /// the capture — 99–140 ms on a MacBook Air's 20-megapixel screen. The overlay never activates
    /// Pawshot, so an open menu of the app in front is still open when the frame is taken.
    private func startOverlayCapture(
        purpose: OverlayPurpose,
        then use: @escaping (SelectionOverlayController.Selection) -> Void
    ) {
        let pressed = Date()
        if ScreenCaptureService.isWarmingUp {
            Self.logger.notice("capture asked while the launch warm-up is still running")
        }
        guard !isCapturing, !overlayController.isActive else {
            let reason = isCapturing ? "the last capture's frames are still coming" : "the overlay is already up"
            Self.logger.notice("capture ignored: \(reason, privacy: .public)")
            return
        }
        guard ScreenRecordingPermission.ensureGranted() else {
            Self.logger.notice("capture refused: no screen recording access")
            return
        }

        isCapturing = true
        state.isCapturing = true
        OverlayDiagnostics.pressed(at: pressed)
        let system = SystemState.now
        let mainThread = SystemState.threadState(pthread_mach_thread_np(pthread_self()))
        Self.logger.notice("capture on a Mac with \(system, privacy: .public); main thread \(mainThread, privacy: .public)")

        // The window list is taken before the overlay is up: once it is, our own full-screen
        // window is the one under the cursor. `CGWindowList` answers in a couple of ms.
        let capturedWindows = ScreenCaptureService.onScreenWindows()
        overlayController.begin(capturedWindows: capturedWindows, purpose: purpose) { [weak self] selection in
            guard let self else { return }
            state.isCapturing = false
            guard let selection else {
                Self.logger.notice("overlay cancelled")
                return
            }
            let window = selection.windowID.map { ", window \($0)" } ?? ""
            Self.logger.notice(
                "selected \(Int(selection.rect.width))×\(Int(selection.rect.height)) pt on display \(selection.displayID)\(window, privacy: .public)"
            )
            use(selection)
        }
        let shown = OverlayDiagnostics.sincePress()
        Self.logger.notice("overlay shown live +\(shown, privacy: .public) ms, \(capturedWindows.count) windows for window mode")

        let displayIDs = NSScreen.screens.compactMap(SelectionOverlayController.displayID(of:))
        let hiding = overlayController.windowNumbers
        Task {
            defer { isCapturing = false }
            let started = OverlayDiagnostics.sincePress()
            Self.logger.notice("capture task started +\(started, privacy: .public) ms")
            do {
                let frames = try await ScreenCaptureService.captureDisplays(displayIDs, hiding: hiding)
                let frozen = OverlayDiagnostics.sincePress()
                Self.logger.notice("freeze done +\(frozen, privacy: .public) ms")
                overlayController.deliver(frames: frames)
            } catch {
                Self.logger.error("freeze failed: \(String(describing: error), privacy: .public)")
                overlayController.fail()
                state.isCapturing = false
                presentCaptureFailure(error)
            }
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
            on: screen,
            mode: .fullScreen
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

        openEditor(frame: frame, crop: crop, on: selection.screen, mode: selection.windowID == nil ? .region : .window)
    }

    private func openEditor(
        frame: CapturedFrame,
        crop: CGRect,
        on screen: NSScreen,
        mode: Stats.Mode
    ) {
        guard
            !crop.isEmpty,
            let document = EditorDocument(frame: frame, cropRect: crop)
        else {
            Self.logger.error("crop failed: the region is outside the captured frame")
            presentCaptureFailure(ScreenCaptureError.cropFailed)
            return
        }

        Self.logger.notice(
            "editor opens: crop \(Int(crop.width))×\(Int(crop.height)) pt at \(Int(crop.minX)),\(Int(crop.minY)), scale \(frame.scale, privacy: .public)"
        )
        EditorWindowController(document: document, on: screen).show()
        settings.recordCapture()
        Stats.shared.noteShot(mode)
    }

    // MARK: - Recording

    /// ⇧⌘3: pick a region on the overlay, then record it. Pressed again while recording, it stops —
    /// the same key starts and ends a take.
    func beginRegionRecording() {
        guard !recordingController.isActive else {
            Self.logger.notice("record-region shortcut while recording: stop")
            recordingController.stop()
            return
        }
        // Whatever the user was recording must be in front when the recording starts. The overlay
        // no longer activates Pawshot, but a window picked on it might have.
        let previous = NSWorkspace.shared.frontmostApplication
        startOverlayCapture(purpose: .recording) { [weak self] selection in
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
            Self.logger.notice("record-full-screen shortcut while recording: stop")
            recordingController.stop()
            return
        }
        guard !isCapturing, !overlayController.isActive else {
            Self.logger.notice("full screen recording ignored: a capture or the overlay is in the way")
            return
        }
        guard ScreenRecordingPermission.ensureGranted() else {
            Self.logger.notice("full screen recording refused: no screen recording access")
            return
        }

        let mouse = NSEvent.mouseLocation
        guard
            let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main,
            let displayID = SelectionOverlayController.displayID(of: screen)
        else {
            Self.logger.error("full screen recording: no display under the cursor")
            return
        }

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
            Self.logger.notice("recording: back to \(previous.localizedName ?? "?", privacy: .public) first")
            previous.activate()
        }
        Task {
            do {
                try await recordingController.start(target)
            } catch {
                Self.logger.error("recording not started: \(String(describing: error), privacy: .public)")
                presentFailure(error, title: String(localized: "Couldn't start recording"))
            }
        }
    }

    private func presentCaptureFailure(_ error: Error) {
        presentFailure(error, title: String(localized: "Couldn't capture the region"))
    }

    private func presentFailure(_ error: Error, title: String) {
        Self.logger.error("alert: \(title, privacy: .public) — \(String(describing: error), privacy: .public)")
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        NSApp.activate()
        alert.runModal()
    }
}
