import AppKit
import AVFoundation
import IOKit.ps
import os
import SwiftUI

/// Settings → General → "Save Logs…": one text file a person can send with a bug report.
///
/// Four parts: a header with what the log alone can't say (the build, the Mac, the displays, the
/// permissions, every shortcut and whether macOS still takes it), Pawshot's own log for the last
/// three days, the latest crash reports, and the main thread's stack from the last stalls. The log comes from `/usr/bin/log show`: the app has no
/// sandbox, so that needs no rights, and it reads what was persisted — `.notice` and above. That
/// is why every milestone in the code is logged at `.notice` and every interpolation `.public`:
/// `.info` never reaches the disk, and a redacted `<private>` tells nobody anything.
@MainActor
enum LogExport {
    static let subsystem = Logger.pawshotSubsystem
    private static var logger: Logger {
        .pawshot("app")
    }

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
        /// Name, shortcut (`none` when cleared), and the macOS item that still takes it, if any.
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
        /// Every macOS shortcut switched on with ⌘, ⌥ or ⌃, `item 27: ⌘1` — a key macOS takes never
        /// reaches Pawshot, and the tester's window switcher on ⌘1 was one.
        var systemShortcuts: [String] = []
        /// The input source in use when the log was saved.
        var keyboardLayout = ""

        var otherCaptureAppsText: String {
            otherCaptureApps.isEmpty ? "none" : otherCaptureApps.joined(separator: ", ")
        }

        var systemShortcutsText: String {
            systemShortcuts.isEmpty ? "none listed" : systemShortcuts.joined(separator: ", ")
        }
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
        lines.append("Keyboard layout: \(facts.keyboardLayout)")
        lines.append("macOS shortcuts on, with ⌘, ⌥ or ⌃: \(facts.systemShortcutsText)")
        lines.append("")
        lines.append("Settings:")
        for setting in facts.settings {
            lines.append("  \(setting.name): \(setting.value)")
        }
        lines.append("Other running copies: \(facts.otherCopies.isEmpty ? "none" : facts.otherCopies.joined(separator: ", "))")
        lines.append("Other capture apps: \(facts.otherCaptureAppsText)")
        lines.insert("Hardware: \(facts.hardware); now: \(facts.system)", at: 4)
        return lines.joined(separator: "\n")
    }

    static func currentFacts() -> Facts {
        let settings = Settings.shared
        // One read for both: two syncs cost twice, and the two could disagree in between.
        let symbolicHotKeys = SystemScreenshotShortcuts.liveSymbolicHotKeys()
        let system = SystemScreenshotShortcuts(symbolicHotKeys: symbolicHotKeys)
        let enabled = SystemScreenshotShortcuts.enabledShortcuts(in: symbolicHotKeys)
        /// A screenshot item first — it has a name and a factory default — then any item at all.
        func takenBy(_ binding: HotKeyBinding) -> String? {
            let id = system.conflict(with: binding)?.id
                ?? enabled.first { $0.binding.keyCode == binding.keyCode && $0.binding.carbonModifiers == binding.carbonModifiers }?.id
            return id.map { "item \($0)" }
        }
        let named: [(String, HotKeyBinding?)] = [
            ("Capture a region", settings.regionHotKey),
            ("Capture the full screen", settings.fullScreenHotKey),
            ("Record a region", settings.recordRegionHotKey),
            ("Record the full screen", settings.recordFullScreenHotKey),
            ("Pen (while recording)", settings.penHotKey),
            ("Restart (while recording)", settings.restartHotKey),
            ("Bad take (while recording)", settings.badTakeHotKey),
            ("Spotlight, held (while recording)", settings.spotlightHotKey),
            ("Blur, held (while recording)", settings.blurHotKey),
            ("Mute, held (while recording)", settings.muteHotKey),
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
                (name, binding?.logString ?? "none", binding.flatMap(takenBy))
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
            otherCaptureApps: SystemState.otherCaptureApps,
            systemShortcuts: enabled.map { "item \($0.id): \($0.binding.logString)" },
            keyboardLayout: KeyboardLayout.currentInputSourceID
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
        SystemState.sysctlString("hw.model") ?? "?"
    }

    /// The last few crash reports of Pawshot, whole: a crash is the one thing the log can't show.
    static func crashReports(limit: Int = 3) -> String {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/DiagnosticReports")
        let ours = newestFirst(in: folder, prefix: "Pawshot").prefix(limit)
        guard !ours.isEmpty else { return "No crash reports." }
        return ours.map { url in
            "=== \(url.lastPathComponent) ===\n" + ((try? String(contentsOf: url, encoding: .utf8)) ?? "(unreadable)")
        }.joined(separator: "\n\n")
    }

    /// The main thread's stacks from the last stalls the overlay's watchdog caught — see
    /// `StallSamples`.
    static func stallSamples(limit: Int = 2) -> String {
        let files = StallSamples.folder.map { newestFirst(in: $0, prefix: StallSamples.prefix) } ?? []
        guard !files.isEmpty else { return "No stall samples." }
        return files.prefix(limit).map { url in
            let report = (try? String(contentsOf: url, encoding: .utf8)).map(StallSamples.mainThreadPart)
            return "=== \(url.lastPathComponent) ===\n" + (report ?? "(unreadable)")
        }.joined(separator: "\n\n")
    }

    /// The files in a folder whose names start with `prefix`, the newest first.
    nonisolated static func newestFirst(in folder: URL, prefix: String) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        return files
            .filter { $0.lastPathComponent.hasPrefix(prefix) }
            .sorted { lhs, rhs in
                let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return left > right
            }
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
                return "log show could not start: \(String(describing: error))"
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
            "",
            "=== Main-thread stalls (the stack while the overlay's main thread stood still) ===",
            stallSamples(),
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
            presentWriteFailure(error)
        }
    }

    /// Where "Send by Email…" puts the file: the draft reads it after the call returns, so it
    /// can't be a temporary one. Only the latest is kept.
    static var mailFolder: URL? {
        try? FileManager.default
            .url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("com.caramelheaven.pawshot/Logs", isDirectory: true)
    }

    /// The same file as Save Logs, attached to a new message to the developer. Without a mail
    /// account the file is shown in the Finder and a plain `mailto:` opens, to drag it into.
    static func sendByEmail() async {
        guard let folder = mailFolder else { return }
        let url = folder.appendingPathComponent(suggestedFileName)
        logger.notice("send logs: collecting into \(url.path, privacy: .public)")
        let text = await report()
        do {
            try? FileManager.default.removeItem(at: folder)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            presentWriteFailure(error)
            return
        }

        let subject = "Pawshot \(AboutPanel.versionLine) logs"
        let items: [Any] = [String(localized: "What happened, and what did you do just before?"), url]
        NSApp.activate()
        if let mail = NSSharingService(named: .composeEmail), mail.canPerform(withItems: items) {
            mail.recipients = [AboutPanel.contactEmail]
            mail.subject = subject
            mail.perform(withItems: items)
            logger.notice("send logs: mail opened with \(text.utf8.count) bytes attached")
        } else {
            logger.notice("send logs: no mail account, showing the file and a mailto")
            NSWorkspace.shared.activateFileViewerSelecting([url])
            var mailto = URLComponents()
            mailto.scheme = "mailto"
            mailto.path = AboutPanel.contactEmail
            mailto.queryItems = [URLQueryItem(name: "subject", value: subject)]
            if let link = mailto.url {
                NSWorkspace.shared.open(link)
            }
        }
    }

    /// Switched off, what Pawshot itself kept goes too: the stall stacks and the last mailed file.
    /// The lines macOS already holds stay with it until it rotates them — that takes root.
    static func forgetCollected() {
        for folder in [StallSamples.folder, mailFolder].compactMap(\.self) {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    /// The "Collect Logs" switch, the same in Settings and in the welcome window.
    static var collectingBinding: Binding<Bool> {
        Binding {
            Settings.shared.collectsLogs
        } set: { isOn in
            Settings.shared.collectsLogs = isOn
            if !isOn {
                forgetCollected()
            }
        }
    }

    private static func presentWriteFailure(_ error: Error) {
        logger.error("logs: write failed: \(String(describing: error), privacy: .public)")
        let alert = NSAlert()
        alert.messageText = String(localized: "Couldn't save the logs")
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
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
        return "thermal \(thermal), memory pressure \(memoryPressure), low power \(lowPower), \(powerSource), \(loadAverage)"
    }

    /// "load 3.4" — the one-minute load average: how many threads wanted a core. On an 8-core M1
    /// anything near 8 means a busy Mac, whatever Pawshot does.
    static var loadAverage: String {
        var loads = [Double](repeating: 0, count: 1)
        guard getloadavg(&loads, 1) == 1 else { return "load ?" }
        return "load \(loads[0].formatted(.number.precision(.fractionLength(1)).locale(Locale(identifier: "en_US_POSIX"))))"
    }

    /// "waiting, priority 31 (base 47)" for a thread — the main thread, in practice. `running`
    /// means runnable: on a core or queued for one.
    static func threadState(_ thread: thread_act_t) -> String {
        var info = thread_extended_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<thread_extended_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_info(thread, thread_flavor_t(THREAD_EXTENDED_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return "state ?" }
        return describeThread(runState: info.pth_run_state, current: info.pth_curpri, base: info.pth_priority)
    }

    static func describeThread(runState: Int32, current: Int32, base: Int32) -> String {
        let state = switch runState {
        case TH_STATE_RUNNING: "running"
        case TH_STATE_WAITING: "waiting"
        case TH_STATE_UNINTERRUPTIBLE: "in an uninterruptible wait"
        case TH_STATE_STOPPED: "stopped"
        case TH_STATE_HALTED: "halted"
        default: "in state \(runState)"
        }
        return "\(state), priority \(current) (base \(base))"
    }

    /// When the kernel started this process. The gap to `didFinishLaunching` is how long macOS
    /// held the launch: a tester's freshly replaced build took 9 s to get there.
    static var processStart: Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
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

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
    }
}
