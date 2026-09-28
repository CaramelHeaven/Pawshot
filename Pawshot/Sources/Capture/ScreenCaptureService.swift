import AppKit
import os
import ScreenCaptureKit

enum ScreenCaptureError: LocalizedError {
    case displayNotFound(CGDirectDisplayID)
    case cropFailed

    var errorDescription: String? {
        switch self {
        case let .displayNotFound(id):
            String(localized: "ScreenCaptureKit didn't return display \(id) — screen recording access is probably missing.")
        case .cropFailed:
            String(localized: "The selected region didn't land inside the captured frame.")
        }
    }
}

/// A frozen display frame: a shot of the whole screen the selection is later cut out of.
struct CapturedFrame: Sendable {
    /// The entire display in pixels.
    let image: CGImage
    /// Display bounds in global CoreGraphics coordinates, in points.
    let displayFrame: CGRect
    /// Pixels per point. Taken from the filter itself rather than from
    /// `NSScreen.backingScaleFactor` — they rarely disagree, but this is the value that
    /// determines the frame size.
    let scale: CGFloat
}

/// An on-screen window as it was at the moment of the capture.
///
/// Only what the window mode needs: where it is, and who owns it. The pixels come from the display
/// frame, same as everything else.
struct CapturedWindow: Sendable, Equatable {
    /// Window bounds in global CoreGraphics coordinates, in points — the same system as
    /// `CapturedFrame.displayFrame`.
    let frame: CGRect
    let ownerPID: pid_t
    /// `kCGWindowNumber` — what a window recording finds its `SCWindow` by.
    let windowID: CGWindowID
}

/// One-shot screen captures through ScreenCaptureKit.
///
/// Main actor isolated because of the cache below: `SCShareableContent` isn't `Sendable`, so it
/// can't be kept anywhere it would have to cross an isolation boundary. Nothing is blocked by
/// this — every call here is `async` and the work happens inside ScreenCaptureKit.
@MainActor
enum ScreenCaptureService {
    private static let logger = Logger(subsystem: "com.caramelheaven.pawshot", category: "capture")

    /// The last enumeration of shareable content.
    ///
    /// Only `displays` is ever read from it, and the set of displays changes when a monitor is
    /// plugged in or its resolution changes — not between two captures. Measured in Release on a
    /// working machine, this enumeration costs 17–26 ms, a third of the whole wait from hotkey to
    /// crosshair, so it is worth not paying twice.
    ///
    /// The window list inside it does go stale, and that is fine: window mode gets its own,
    /// freshly taken through `onScreenWindows()`.
    private static var cachedContent: SCShareableContent?
    private static var displayChangeObserver: NSObjectProtocol?

    /// Drops the cache whenever the display setup changes — a monitor plugged in, unplugged, or
    /// switched to another resolution.
    static func beginObservingDisplayChanges() {
        guard displayChangeObserver == nil else { return }

        displayChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                cachedContent = nil
                let displays = NSScreen.screens.map(LogExport.describe).joined(separator: "; ")
                logger.notice("display setup changed: \(displays, privacy: .public)")
            }
        }
    }

    /// Cached shareable content, re-fetched when a display we need isn't in it.
    ///
    /// The miss check is the safety net: a cache that outlived its displays would otherwise turn
    /// into `displayNotFound` on a perfectly valid screen.
    private static func shareableContent(
        including displayIDs: [CGDirectDisplayID]
    ) async throws -> SCShareableContent {
        if let cachedContent, displayIDs.allSatisfy({ displayID in
            cachedContent.displays.contains { $0.displayID == displayID }
        }) {
            return cachedContent
        }

        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        cachedContent = content

        return content
    }

    /// The list of windows as it was when the screen was frozen, front to back.
    ///
    /// Taken **before** the overlay is shown, for the same reason the frames are: once our own
    /// full-screen overlay is up, it is the window under the cursor, and every other window is
    /// behind it.
    ///
    /// `CGWindowListCopyWindowInfo` rather than `SCShareableContent.windows`: its order is
    /// documented to be front to back, and picking the window under the cursor is exactly a
    /// question of who is in front.
    static func onScreenWindows() -> [CapturedWindow] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard
            let entries = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
        else { return [] }

        let ownPID = ProcessInfo.processInfo.processIdentifier

        return entries.compactMap { entry in
            guard
                // Layer 0 is ordinary app windows; everything else is the Dock, menus, shadows
                // and other furniture nobody wants to screenshot on its own.
                let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
                let pid = entry[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                let windowID = entry[kCGWindowNumber as String] as? CGWindowID,
                let bounds = entry[kCGWindowBounds as String] as? [String: CGFloat],
                let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                frame.width > 1, frame.height > 1
            else { return nil }

            return CapturedWindow(frame: frame, ownerPID: pid, windowID: windowID)
        }
    }

    /// Takes one throwaway full-size shot at launch, so the first real capture isn't the slow one.
    ///
    /// It goes through `capture(_:)` — the very same path a real capture takes — and that is the
    /// point. A 1×1 warm-up was tried first and measured: it wakes ScreenCaptureKit, but the first
    /// real capture still cost 125–142 ms against 67–73 ms once warm. The buffers for a full
    /// display frame are what has to be paid for, and they are size-specific.
    ///
    /// The price is one display frame's worth of memory for an instant, in the background, where
    /// nobody is waiting for it.
    ///
    /// Silent by design: without the screen recording permission this would fail, and the app must
    /// not nag about a permission before the user has asked for anything.
    /// Whether the launch warm-up is still capturing — a hotkey then shares ScreenCaptureKit with it.
    private(set) static var isWarmingUp = false

    static func warmUp() async {
        guard CGPreflightScreenCaptureAccess() else {
            logger.notice("warm-up skipped: no screen recording access yet")
            return
        }

        isWarmingUp = true
        defer { isWarmingUp = false }
        do {
            let started = Date()
            let content = try await shareableContent(including: [])
            guard let display = content.displays.first else { return }

            _ = try await capture(display)

            let elapsed = Int(Date().timeIntervalSince(started) * 1000)
            logger.notice("warm-up took \(elapsed, privacy: .public) ms")
        } catch {
            logger.error("warm-up failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Captures every display in full.
    ///
    /// Called **before** the overlay appears on screen: while the app is not activated yet, the
    /// other app's open list or menu is still alive and makes it into the frame. For the same
    /// reason our own windows are not excluded by the filter — there would be a hole where they
    /// are, and both an open Pawshot editor and our own menu bar icon belong in the frame.
    ///
    /// - Parameter hiding: windows of ours that are already on screen and must not be in the frame
    ///   — the overlay, which now goes up before the frame is taken. Leaving them out takes a fresh
    ///   window list (tens of ms), but the dimming is already on screen while it runs.
    static func captureDisplays(
        _ displayIDs: [CGDirectDisplayID],
        hiding: [CGWindowID] = []
    ) async throws -> [CGDirectDisplayID: CapturedFrame] {
        // Served from the cache in the common case — see `shareableContent(including:)`. The
        // overlay's windows are new, so leaving them out needs a list taken after they appeared.
        let contentStarted = Date()
        let content = if hiding.isEmpty {
            try await shareableContent(including: displayIDs)
        } else {
            try await freshContent()
        }
        let contentElapsed = Int(Date().timeIntervalSince(contentStarted) * 1000)
        let exclusion = hiding.isEmpty ? nil : Self.exclusion(hiding: hiding, in: content)

        let captureStarted = Date()
        var frames: [CGDirectDisplayID: CapturedFrame] = [:]

        // Sequential on purpose. Capturing displays side by side would need `SCDisplay` to cross
        // a task boundary, and it isn't `Sendable` — the only way around that is an unsafe
        // wrapper, which buys nothing on a single monitor and hides a real concurrency question
        // on several.
        for displayID in displayIDs {
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                let known = content.displays.map { String($0.displayID) }.joined(separator: ", ")
                logger.error("display \(displayID) not in shareable content (has \(known, privacy: .public))")
                throw ScreenCaptureError.displayNotFound(displayID)
            }

            let shotStarted = Date()
            frames[displayID] = try await capture(display, excluding: exclusion)
            let shotElapsed = Int(Date().timeIntervalSince(shotStarted) * 1000)
            let size = "\(Int(display.frame.width))×\(Int(display.frame.height))"
            logger.notice("display \(displayID, privacy: .public) (\(size, privacy: .public) pt) captured in \(shotElapsed, privacy: .public) ms")
        }

        // Split on purpose: these two numbers say whether the wait is the enumeration or the
        // screenshot itself, and only one of them is worth optimising.
        let captureElapsed = Int(Date().timeIntervalSince(captureStarted) * 1000)
        logger.notice("content \(contentElapsed, privacy: .public) ms, shot \(captureElapsed, privacy: .public) ms")

        return frames
    }

    private static func freshContent() async throws -> SCShareableContent {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        cachedContent = content
        return content
    }

    /// Pawshot left out of the frame, except its windows that belong in it: an open editor, the
    /// paw in the menu bar. Leaving the app out, rather than the overlay's windows one by one,
    /// doesn't depend on ScreenCaptureKit having noticed windows that appeared milliseconds ago.
    private struct Exclusion {
        let application: SCRunningApplication
        let keeping: [SCWindow]
    }

    private static func exclusion(hiding: [CGWindowID], in content: SCShareableContent) -> Exclusion? {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        guard let application = content.applications.first(where: { $0.processID == ownPID }) else {
            logger.notice("capture: Pawshot not in the window list, nothing of ours to leave out")
            return nil
        }
        let ours = content.windows.filter { $0.owningApplication?.processID == ownPID }
        let keptIDs = Set(windowsToKeep(ours.map(\.windowID), hiding: hiding))
        let keeping = ours.filter { keptIDs.contains($0.windowID) }
        logger.notice("capture: leaving out \(hiding.count, privacy: .public) overlay window(s), keeping \(keeping.count, privacy: .public) of ours")
        return Exclusion(application: application, keeping: keeping)
    }

    /// Of our own windows, the ones that stay in the frame: every one but the overlay's.
    nonisolated static func windowsToKeep(_ ours: [CGWindowID], hiding: [CGWindowID]) -> [CGWindowID] {
        let hidden = Set(hiding)
        return ours.filter { !hidden.contains($0) }
    }

    private static func capture(_ display: SCDisplay, excluding exclusion: Exclusion? = nil) async throws -> CapturedFrame {
        let filter = if let exclusion {
            SCContentFilter(display: display, excludingApplications: [exclusion.application], exceptingWindows: exclusion.keeping)
        } else {
            SCContentFilter(display: display, excludingWindows: [])
        }
        let scale = CGFloat(filter.pointPixelScale)
        let sourceRect = CGRect(origin: .zero, size: display.frame.size)
        let pixelSize = SelectionGeometry.pixelSize(of: sourceRect, scale: scale)

        let configuration = SCStreamConfiguration()
        configuration.sourceRect = sourceRect
        configuration.width = pixelSize.width
        configuration.height = pixelSize.height
        configuration.scalesToFit = false
        configuration.showsCursor = false
        configuration.captureResolution = .best

        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )

        return CapturedFrame(image: image, displayFrame: display.frame, scale: scale)
    }
}
