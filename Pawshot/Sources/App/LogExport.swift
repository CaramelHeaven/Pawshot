import AppKit
import AVFoundation
import IOKit.ps
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
        /// The chip and the memory: "Apple M1, 8 GB".
        var hardware = ""
        /// The Mac's state right now — see `SystemState`.
        var system = ""
        /// Other screenshot and screen-recording apps running: they may take the hotkey or share
        /// ScreenCaptureKit.
        var otherCaptureApps: [String] = []
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
        lines.append("Other capture apps: \(facts.otherCaptureApps.isEmpty ? "none" : facts.otherCaptureApps.joined(separator: ", "))")
        lines.insert("Hardware: \(facts.hardware); now: \(facts.system)", at: 4)
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
            otherCopies: others,
            hardware: SystemState.hardware,
            system: SystemState.now,
            otherCaptureApps: SystemState.otherCaptureApps
        )
    }

    static func describe(_ screen: NSScreen) -> String {
        let size = screen.frame.size
        let main = screen == NSScreen.screens.first ? " (main)" : ""
        // The refresh rate: at 60 Hz a frame is 16 ms, at 120 Hz 8 — what a draw has to fit in.
        let hertz = screen.maximumFramesPerSecond
        return "\(Int(size.width))×\(Int(size.height)) pt @\(screen.backingScaleFactor)x \(hertz) Hz\(main)"
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

/// What the Mac itself is doing, read without asking for any permission: whether "it lags" is
/// Pawshot or a Mac that was throttled, short of memory or saving power at that moment.
enum SystemState {
    /// "Apple M1, 8 GB".
    static var hardware: String {
        let memory = ProcessInfo.processInfo.physicalMemory / 1_073_741_824
        return "\(sysctlString("machdep.cpu.brand_string") ?? "?"), \(memory) GB"
    }

    /// "thermal nominal, memory pressure normal, low power off, on AC" — cheap enough to log with
    /// every capture.
    static var now: String {
        let thermal = switch ProcessInfo.processInfo.thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "SERIOUS"
        case .critical: "CRITICAL"
        @unknown default: "unknown"
        }
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled ? "ON" : "off"
        return "thermal \(thermal), memory pressure \(memoryPressure), low power \(lowPower), \(powerSource)"
    }

    /// The kernel's own verdict: 1 normal, 2 warn, 4 critical.
    static var memoryPressure: String {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return "?" }
        return switch level {
        case 1: "normal"
        case 2: "WARN"
        case 4: "CRITICAL"
        default: "\(level)"
        }
    }

    static var powerSource: String {
        guard
            let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        else { return "power ?" }
        return type == kIOPMBatteryPowerKey ? "on battery" : "on AC"
    }

    /// Screenshot and screen-recording apps that may take a shortcut or share ScreenCaptureKit.
    static let captureAppNames = [
        "CleanShot", "Shottr", "Snagit", "Xnapper", "Monosnap", "Lightshot", "Skitch",
        "OBS Studio", "Screen Studio", "screencaptureui",
    ]
    /// Names too short to look for inside others: "OBS" would catch Obsidian.
    static let exactCaptureAppNames: Set = ["OBS", "Kap", "Loom", "Screenshot"]

    @MainActor
    static var otherCaptureApps: [String] {
        let running = NSWorkspace.shared.runningApplications.compactMap(\.localizedName)
        return matchingCaptureApps(running)
    }

    static func matchingCaptureApps(_ names: [String]) -> [String] {
        names.filter { name in
            exactCaptureAppNames.contains(name) || captureAppNames.contains { name.localizedCaseInsensitiveContains($0) }
        }
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}
