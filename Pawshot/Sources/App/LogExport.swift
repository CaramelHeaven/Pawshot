import AppKit
import AVFoundation
import os

/// Settings → General → "Save Logs…": one text file a person can send with a bug report.
///
/// Three parts: a header with what the log alone can't say (the build, the Mac, the displays, the
/// permissions, every shortcut and whether macOS still takes it), Pawshot's own log for the last
/// three days, and the latest crash reports. The log comes from `/usr/bin/log show`: the app has no
/// sandbox, so that needs no rights, and it reads what was persisted — `.notice` and above. That
/// is why every milestone in the code is logged at `.notice` and every interpolation `.public`:
/// `.info` never reaches the disk, and a redacted `<private>` tells nobody anything.
@MainActor
enum LogExport {
    static let subsystem = "com.caramelheaven.pawshot"
    private static let logger = Logger(subsystem: subsystem, category: "app")

    /// How far back the log goes.
    static let period = "3d"

    static var logArguments: [String] {
        ["show", "--predicate", "subsystem == \"\(subsystem)\"", "--last", period, "--info", "--style", "compact"]
    }

    /// Everything the header says, gathered apart from how it is written, so the writing is tested.
    struct Facts {
        var version: String
        var build: String
        var macOS: String
        var model: String
        var bundlePath: String
        var displays: [String]
        var screenRecording: Bool
        var microphone: Bool
        var inputMonitoring: Bool
        /// Name, shortcut, and the macOS screenshot item that still takes it, if any.
        var hotKeys: [(name: String, shortcut: String, takenBy: String?)]
        var settings: [(name: String, value: String)]
        var otherCopies: [String]
    }

    static func header(_ facts: Facts, generatedAt date: Date) -> String {
        func yes(_ value: Bool) -> String {
            value ? "yes" : "NO"
        }
        var lines = [
            "Pawshot logs — \(date.formatted(.iso8601))",
            "",
            "Pawshot \(facts.version) (\(facts.build)) at \(facts.bundlePath)",
            "macOS \(facts.macOS), \(facts.model)",
            "Displays: \(facts.displays.joined(separator: "; "))",
            "Screen recording: \(yes(facts.screenRecording)), microphone: \(yes(facts.microphone)), "
                + "input monitoring: \(yes(facts.inputMonitoring))",
            "",
            "Shortcuts:",
        ]
        for hotKey in facts.hotKeys {
            let taken = hotKey.takenBy.map { " — TAKEN BY macOS: \($0)" } ?? ""
            lines.append("  \(hotKey.name): \(hotKey.shortcut)\(taken)")
        }
        lines.append("")
        lines.append("Settings:")
        for setting in facts.settings {
            lines.append("  \(setting.name): \(setting.value)")
        }
        lines.append("Other running copies: \(facts.otherCopies.isEmpty ? "none" : facts.otherCopies.joined(separator: ", "))")
        return lines.joined(separator: "\n")
    }

    static func currentFacts() -> Facts {
        let settings = Settings.shared
        let system = SystemScreenshotShortcuts.current()
        let named: [(String, HotKeyBinding)] = [
            ("Capture a region", settings.regionHotKey),
            ("Capture the full screen", settings.fullScreenHotKey),
            ("Record a region", settings.recordRegionHotKey),
            ("Record the full screen", settings.recordFullScreenHotKey),
            ("Mark a zoom (while recording)", settings.zoomMarkHotKey),
            ("Pen (while recording)", settings.penHotKey),
            ("Restart (while recording)", settings.restartHotKey),
        ]
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != ownPID }
            .map { "pid \($0.processIdentifier) at \($0.bundleURL?.path ?? "?")" }

        return Facts(
            version: AboutPanel.version,
            build: AboutPanel.build,
            macOS: ProcessInfo.processInfo.operatingSystemVersionString,
            model: hardwareModel,
            bundlePath: Bundle.main.bundlePath,
            displays: NSScreen.screens.map(describe),
            screenRecording: CGPreflightScreenCaptureAccess(),
            microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
            inputMonitoring: CGPreflightListenEventAccess(),
            hotKeys: named.map { name, binding in
                (name, binding.displayString, system.conflict(with: binding)?.name)
            },
            settings: [
                ("Warn before quitting (⌘Q)", "\(settings.warnsBeforeQuitting)"),
                ("Language", "\(settings.language)"),
                ("Tools and colours", "\(settings.toolsPlacement)"),
                ("Label font", settings.labelFontFamily ?? "system"),
                ("Microphone in recordings", "\(settings.recordsMicrophone)"),
                ("System audio in recordings", "\(settings.recordsSystemAudio)"),
                ("Native resolution", "\(settings.recordsAtNativeResolution)"),
                ("Captures so far", "\(settings.captureCount)"),
            ],
            otherCopies: others
        )
    }

    static func describe(_ screen: NSScreen) -> String {
        let size = screen.frame.size
        let main = screen == NSScreen.screens.first ? " (main)" : ""
        return "\(Int(size.width))×\(Int(size.height)) pt @\(screen.backingScaleFactor)x\(main)"
    }

    private static var hardwareModel: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return String(cString: model)
    }

    /// The last few crash reports of Pawshot, whole: a crash is the one thing the log can't show.
    static func crashReports(limit: Int = 3) -> String {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/DiagnosticReports")
        let reports = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        let ours = reports
            .filter { $0.lastPathComponent.hasPrefix("Pawshot") }
            .sorted { lhs, rhs in
                let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return left > right
            }
            .prefix(limit)
        guard !ours.isEmpty else { return "No crash reports." }
        return ours.map { url in
            "=== \(url.lastPathComponent) ===\n" + ((try? String(contentsOf: url, encoding: .utf8)) ?? "(unreadable)")
        }.joined(separator: "\n\n")
    }

    /// `log show` in a child process, off the main thread: three days of log take a few seconds.
    nonisolated static func readLog(arguments: [String]) async -> String {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/log")
            process.arguments = arguments
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            do {
                try process.run()
            } catch {
                return "log show could not start: \(error.localizedDescription)"
            }
            // Read before waiting: a full pipe would otherwise stall the child for good.
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        }.value
    }

    static func report() async -> String {
        let header = header(currentFacts(), generatedAt: Date())
        let log = await readLog(arguments: logArguments)
        return [
            header,
            "",
            "=== Log, last \(period) (log \(logArguments.joined(separator: " "))) ===",
            log,
            "",
            "=== Crash reports ===",
            crashReports(),
        ].joined(separator: "\n")
    }

    static var suggestedFileName: String {
        let stamp = Date().formatted(.verbatim(
            "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits)-\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased))\(minute: .twoDigits)",
            timeZone: .current,
            calendar: .current
        ))
        return "pawshot-logs-\(stamp).txt"
    }

    /// Asks where to put the file, then gathers and writes it, and shows it in the Finder so it
    /// can be dragged into a message straight away.
    static func saveWithPanel() async {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedFileName
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        panel.allowedContentTypes = [.plainText]
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else {
            logger.notice("save logs: cancelled")
            return
        }

        logger.notice("save logs: collecting into \(url.path, privacy: .public)")
        let text = await report()
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            logger.notice("save logs: wrote \(text.utf8.count) bytes")
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            logger.error("save logs: write failed: \(error.localizedDescription, privacy: .public)")
            let alert = NSAlert()
            alert.messageText = String(localized: "Couldn't save the logs")
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }
}
