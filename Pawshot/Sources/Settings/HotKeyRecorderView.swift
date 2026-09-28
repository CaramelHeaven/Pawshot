import AppKit
import os

/// A field that records a key combination: click it, press the keys, done. The × on its right
/// takes the shortcut away altogether — the action then has none and is reached from the menu.
///
/// While it is recording, the app's own global hotkeys have to be unregistered — Carbon delivers
/// them before the key press ever reaches this view, so without that the old shortcut would fire
/// a capture instead of being replaced. `Settings.onHotKeyRecordingChange` is what carries that
/// news to `AppDelegate`.
///
/// A combination macOS or another app takes first never reaches this view at all — a tester's
/// ⇧⌘1, held by her window switcher, left not one key press in the log. The view can't get it
/// back, only tell: modifiers held and released with no key in between, or the window losing
/// focus mid-chord, put up "Didn't reach Pawshot". While recording, a local monitor logs every
/// key event the app receives, so a saved log shows where a press went missing.
final class HotKeyRecorderView: NSView {
    private static var logger: Logger {
        .pawshot("settings")
    }

    /// `nil` — no shortcut: cleared with the ×.
    var binding: HotKeyBinding? {
        didSet { needsDisplay = true }
    }

    /// The action in English, for the log.
    var logName = "shortcut"

    /// Called with a new combination. Returning `false` means it wasn't accepted (already taken),
    /// and the field keeps showing the previous one.
    var onRecord: ((HotKeyBinding) -> Bool)?
    var onRecordingChange: ((Bool) -> Void)?
    /// The × was clicked: the action is left with no shortcut.
    var onClear: (() -> Void)?

    /// macOS still takes this combination for its own screenshots (`SystemScreenshotShortcuts`);
    /// the capsule gets a red outline so the conflict shows where the shortcut is.
    var isTakenBySystem = false {
        didSet { needsDisplay = true }
    }

    private(set) var isRecording = false {
        didSet {
            onRecordingChange?(isRecording)
            needsDisplay = true
        }
    }

    /// Modifiers held right now, drawn while the user is still reaching for the key.
    private var pendingFlags: NSEvent.ModifierFlags = []
    private(set) var hint: String?

    /// What one chord — modifiers down until they are all up — delivered. Reset when it ends.
    /// Every modifier held since the chord began, so a release one by one still names them all.
    private var chordFlags: NSEvent.ModifierFlags = []
    /// A key press reached this view.
    private var chordReachedField = false
    /// A key press reached the app (the monitor): it went somewhere else if not to this view.
    private var chordReachedApp = false
    /// Keys the monitor saw go down, to tell a key up whose press was taken before Pawshot.
    private var keysDown: Set<UInt16> = []
    private var recordingStarted = Date()
    private var monitor: Any?

    init(binding: HotKeyBinding?) {
        self.binding = binding
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is unused — the UI is built in code")
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: 150, height: 26)
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    // MARK: - Recording

    override func mouseDown(with event: NSEvent) {
        let name = logName
        let point = convert(event.locationInWindow, from: nil)
        if !isRecording, let binding, clearButtonRect.contains(point) {
            let current = binding.logString
            Self.logger.notice("shortcut field (\(name, privacy: .public)): cleared with ×, was \(current, privacy: .public)")
            setHint(nil)
            onClear?()
            return
        }
        // A second click on a recording field used to announce the recording again and
        // unregister hotkeys that were already gone.
        guard !isRecording else {
            Self.logger.notice("shortcut field (\(name, privacy: .public)): clicked again, still recording")
            return
        }

        let current = binding?.logString ?? "none"
        let layout = KeyboardLayout.currentInputSourceID
        let active = NSApp.isActive
        Self.logger.notice("shortcut field (\(name, privacy: .public)): recording, was \(current, privacy: .public), layout \(layout, privacy: .public), app active \(active, privacy: .public)")
        window?.makeFirstResponder(self)
        setHint(nil)
        startRecording()
    }

    override func resignFirstResponder() -> Bool {
        stopRecording(because: "focus moved to another control")
        return true
    }

    private var windowObservers: [NSObjectProtocol] = []

    /// Closing the window, leaving it — another Settings tab — or the window losing focus ends a
    /// recording too. None of them sends `resignFirstResponder`, and a recording that never ended
    /// left every global hotkey unregistered: a tester's log shows 35 s of it, the field still
    /// recording while she was in other apps. `HotKeyRecorderViewTests` pins all three.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        windowObservers.forEach { NotificationCenter.default.removeObserver($0) }
        windowObservers = []
        guard let newWindow else {
            stopRecording(because: "left its window")
            return
        }
        windowObservers = [
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: newWindow,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.stopRecording(because: "window closed")
                }
            },
            NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: newWindow,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.windowLostFocus()
                }
            },
        ]
    }

    /// A window switcher that owns the chord takes the focus with it: modifiers held, no key in
    /// the field, and the window is no longer key. That is the missing key, not a change of mind.
    private func windowLostFocus() {
        guard isRecording else { return }
        if HotKeyBinding.isUsable(chordFlags), !chordReachedField {
            let held = Self.modifiersText(chordFlags)
            let name = logName
            Self.logger.error("shortcut field (\(name, privacy: .public)): the window lost focus with \(held, privacy: .public) held and no key in the field — macOS or another app took the combination")
            showNotDelivered()
        }
        stopRecording(because: "window lost focus")
    }

    private func startRecording() {
        pendingFlags = []
        endChord()
        keysDown = []
        recordingStarted = Date()
        installMonitor()
        isRecording = true
    }

    private func stopRecording(because reason: String) {
        pendingFlags = []
        // Only an actual recording ends: every "ended" re-registers all the hotkeys.
        guard isRecording else { return }
        removeMonitor()
        let name = logName
        let lasted = Int(Date().timeIntervalSince(recordingStarted) * 1000)
        Self.logger.notice("shortcut field (\(name, privacy: .public)): stopped, \(reason, privacy: .public), after \(lasted, privacy: .public) ms")
        isRecording = false
    }

    override func flagsChanged(with event: NSEvent) {
        guard isRecording else { return super.flagsChanged(with: event) }

        pendingFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let flags = event.modifierFlags.intersection([.shift, .control, .option, .command])
        if flags.isEmpty {
            chordEnded()
        } else {
            if hint != nil {
                setHint(nil)
            }
            // A new chord starts clean: a plain key pressed before it (refused, no chord running)
            // left "reached the field" set, and the next chord macOS took went unreported.
            if chordFlags.isEmpty {
                endChord()
            }
            chordFlags.formUnion(flags)
        }
        needsDisplay = true
    }

    /// All modifiers are up. A chord with ⌘, ⌥ or ⌃ that brought no key to the field either lost
    /// its key before Pawshot, or to something inside Pawshot — the monitor tells which.
    private func chordEnded() {
        defer { endChord() }
        guard HotKeyBinding.isUsable(chordFlags), !chordReachedField else { return }

        let held = Self.modifiersText(chordFlags)
        let name = logName
        if chordReachedApp {
            Self.logger.error("shortcut field (\(name, privacy: .public)): \(held, privacy: .public) held and released; a key reached Pawshot but not the field — a menu item took it")
        } else {
            Self.logger.error("shortcut field (\(name, privacy: .public)): \(held, privacy: .public) held and released, no key reached Pawshot — macOS or another app takes the combination, or none was pressed")
            showNotDelivered()
        }
    }

    private func endChord() {
        chordFlags = []
        chordReachedField = false
        chordReachedApp = false
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { return super.keyDown(with: event) }
        chordReachedField = true
        let name = logName

        // Esc leaves the old combination alone — the same escape hatch every macOS recorder has.
        if event.keyCode == 53 {
            Self.logger.notice("shortcut field (\(name, privacy: .public)): Esc, kept the old one")
            stopRecording(because: "Esc")
            return
        }

        guard let recorded = HotKeyBinding.from(event: event) else {
            Self.logger.notice("shortcut field (\(name, privacy: .public)): key \(event.keyCode, privacy: .public) without ⌘, ⌥ or ⌃ refused")
            setHint(String(localized: "Add ⌘, ⌥ or ⌃"))
            return
        }

        let shortcut = recorded.logString
        if onRecord?(recorded) ?? false {
            Self.logger.notice("shortcut field (\(name, privacy: .public)): recorded \(shortcut, privacy: .public), key \(event.keyCode, privacy: .public)")
            binding = recorded
            setHint(nil)
            stopRecording(because: "recorded")
        } else {
            Self.logger.notice("shortcut field (\(name, privacy: .public)): \(shortcut, privacy: .public) already taken by another action")
            setHint(String(localized: "Already taken"))
            stopRecording(because: "taken")
        }
    }

    // MARK: - What reaches the app

    /// Sees every key event Pawshot receives while the field records, before any menu or view
    /// does, and hands it on untouched: it only watches. Its log lines are the proof a key
    /// arrived — or, missing, that it never did.
    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            MainActor.assumeIsolated {
                self?.observe(event)
            }
            return event
        }
    }

    private func removeMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    private func observe(_ event: NSEvent) {
        let name = logName
        let code = event.keyCode
        let modifiers = Self.modifiersText(event.modifierFlags)
        switch event.type {
        case .keyDown:
            chordReachedApp = true
            keysDown.insert(code)
            let characters = event.characters ?? ""
            let latin = KeyboardLayout.latinCharacter(for: event) ?? "?"
            let keyWindow = NSApp.keyWindow?.title ?? "none"
            let isFirstResponder = window?.firstResponder === self
            Self.logger.notice("shortcut field (\(name, privacy: .public)): key down \(code, privacy: .public), modifiers \(modifiers, privacy: .public), characters \"\(characters, privacy: .public)\", latin \"\(latin, privacy: .public)\", repeat \(event.isARepeat, privacy: .public), key window \"\(keyWindow, privacy: .public)\", field first responder \(isFirstResponder, privacy: .public)")
        case .keyUp:
            if keysDown.remove(code) == nil {
                Self.logger.error("shortcut field (\(name, privacy: .public)): key up \(code, privacy: .public) with no key down, modifiers \(modifiers, privacy: .public) — the press was taken before Pawshot")
            } else {
                Self.logger.notice("shortcut field (\(name, privacy: .public)): key up \(code, privacy: .public)")
            }
        case .flagsChanged:
            Self.logger.notice("shortcut field (\(name, privacy: .public)): modifiers \(modifiers, privacy: .public) (key \(code, privacy: .public))")
        default:
            break
        }
    }

    /// "⇧⌘", or "none".
    private static func modifiersText(_ flags: NSEvent.ModifierFlags) -> String {
        let text = HotKeyBinding(keyCode: 0, modifiers: flags, label: "").keyCaps.joined()
        return text.isEmpty ? "none" : text
    }

    // MARK: - Hints

    private func setHint(_ text: String?) {
        hint = text
        toolTip = nil
        needsDisplay = true
    }

    private func showNotDelivered() {
        setHint(String(localized: "Didn't reach Pawshot"))
        // Holding modifiers and letting go with no key looks exactly the same, so the words hold
        // for both.
        toolTip = String(localized: "No key reached Pawshot. If you pressed one, macOS or another app takes this combination first: pick another one, or free it there.")
    }

    // MARK: - Drawing

    /// Where the × sits and takes a click: the right end of the capsule.
    private var clearButtonRect: CGRect {
        CGRect(x: bounds.maxX - 24, y: 0, width: 24, height: bounds.height)
    }

    private var showsClearButton: Bool {
        binding != nil && !isRecording
    }

    /// A capsule with each key drawn as its own cap: ⇧ ⌘ 2. While recording, the capsule takes the
    /// accent colour and shows the modifiers held so far; a combination macOS keeps for its own
    /// screenshots gets a red outline, so the conflict is visible where the shortcut is.
    override func draw(_: CGRect) {
        let box = bounds.insetBy(dx: 0.5, dy: 0.5)
        let capsule = NSBezierPath(roundedRect: box, xRadius: box.height / 2, yRadius: box.height / 2)

        (isRecording ? NSColor.controlAccentColor.withAlphaComponent(0.12) : NSColor.quaternarySystemFill)
            .setFill()
        capsule.fill()

        let outline: NSColor = if isRecording {
            .controlAccentColor
        } else if isTakenBySystem, hint == nil {
            .systemRed
        } else {
            .separatorColor
        }
        outline.setStroke()
        capsule.lineWidth = isRecording ? 2 : 1
        capsule.stroke()

        // The caps and the text centre in what the × leaves.
        var content = bounds
        if showsClearButton {
            content.size.width -= clearButtonRect.width - 6
            drawClearButton()
        }

        if let text = plainText {
            let color: NSColor = isRecording || binding == nil && hint == nil ? .secondaryLabelColor : .labelColor
            drawCentered(text, color: color, in: content)
        } else {
            drawCaps(caps, in: content)
        }
    }

    private func drawClearButton() {
        let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.tertiaryLabelColor]))
        guard let image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return }
        let rect = clearButtonRect
        image.draw(in: CGRect(
            x: rect.midX - image.size.width / 2 - 3,
            y: rect.midY - image.size.height / 2,
            width: image.size.width,
            height: image.size.height
        ))
    }

    private static let capFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
    private static let capHeight: CGFloat = 18
    private static let capSpacing: CGFloat = 3

    private func drawCaps(_ caps: [String], in content: CGRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.capFont,
            .foregroundColor: NSColor.labelColor,
        ]
        let widths = caps.map { max(Self.capHeight, ($0 as NSString).size(withAttributes: attributes).width + 10) }
        let total = widths.reduce(0, +) + Self.capSpacing * CGFloat(max(0, caps.count - 1))
        var x = content.minX + (content.width - total) / 2
        let y = (bounds.height - Self.capHeight) / 2

        for (cap, width) in zip(caps, widths) {
            let rect = CGRect(x: x, y: y, width: width, height: Self.capHeight)
            NSColor.tertiarySystemFill.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()

            let size = (cap as NSString).size(withAttributes: attributes)
            (cap as NSString).draw(
                at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
                withAttributes: attributes
            )
            x += width + Self.capSpacing
        }
    }

    private func drawCentered(_ text: String, color: NSColor, in content: CGRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: color,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(
            at: CGPoint(x: content.minX + (content.width - size.width) / 2, y: (bounds.height - size.height) / 2),
            withAttributes: attributes
        )
    }

    /// A message instead of caps: a hint after a rejected combination, the prompt while
    /// recording with nothing held yet, or the placeholder of a field with no shortcut.
    private var plainText: String? {
        if let hint {
            return hint
        }
        if isRecording, pendingFlags.isEmpty {
            return String(localized: "Press keys…")
        }
        if !isRecording, binding == nil {
            return String(localized: "Record Shortcut")
        }
        return nil
    }

    private var caps: [String] {
        guard isRecording else {
            return binding?.keyCaps ?? []
        }

        return HotKeyBinding(keyCode: 0, modifiers: pendingFlags, label: "").keyCaps
    }
}
