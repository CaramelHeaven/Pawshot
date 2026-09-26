import AppKit

/// A field that records a key combination: click it, press the keys, done.
///
/// While it is recording, the app's own global hotkeys have to be unregistered — Carbon delivers
/// them before the key press ever reaches this view, so without that the old shortcut would fire
/// a capture instead of being replaced. `Settings.onHotKeyRecordingChange` is what carries that
/// news to `AppDelegate`.
final class HotKeyRecorderView: NSView {
    var binding: HotKeyBinding {
        didSet { needsDisplay = true }
    }

    /// Called with a new combination. Returning `false` means it wasn't accepted (already taken),
    /// and the field keeps showing the previous one.
    var onRecord: ((HotKeyBinding) -> Bool)?
    var onRecordingChange: ((Bool) -> Void)?

    /// macOS still takes this combination for its own screenshots (`SystemScreenshotShortcuts`);
    /// the capsule gets a red outline so the conflict shows where the shortcut is.
    var isTakenBySystem = false {
        didSet { needsDisplay = true }
    }

    private var isRecording = false {
        didSet {
            onRecordingChange?(isRecording)
            needsDisplay = true
        }
    }

    /// Modifiers held right now, drawn while the user is still reaching for the key.
    private var pendingFlags: NSEvent.ModifierFlags = []
    private var hint: String?

    init(binding: HotKeyBinding) {
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

    override func mouseDown(with _: NSEvent) {
        window?.makeFirstResponder(self)
        hint = nil
        isRecording = true
    }

    override func resignFirstResponder() -> Bool {
        stopRecording()
        return true
    }

    private func stopRecording() {
        pendingFlags = []
        isRecording = false
    }

    override func flagsChanged(with event: NSEvent) {
        guard isRecording else { return super.flagsChanged(with: event) }

        pendingFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { return super.keyDown(with: event) }

        // Esc leaves the old combination alone — the same escape hatch every macOS recorder has.
        if event.keyCode == 53 {
            stopRecording()
            return
        }

        guard let recorded = HotKeyBinding.from(event: event) else {
            hint = String(localized: "Add ⌘, ⌥ or ⌃")
            needsDisplay = true
            return
        }

        if onRecord?(recorded) ?? false {
            binding = recorded
            hint = nil
        } else {
            hint = String(localized: "Already taken")
        }
        stopRecording()
    }

    // MARK: - Drawing

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

        if let text = plainText {
            drawCentered(text, color: isRecording ? .secondaryLabelColor : .labelColor)
        } else {
            drawCaps(caps)
        }
    }

    private static let capFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
    private static let capHeight: CGFloat = 18
    private static let capSpacing: CGFloat = 3

    private func drawCaps(_ caps: [String]) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.capFont,
            .foregroundColor: NSColor.labelColor,
        ]
        let widths = caps.map { max(Self.capHeight, ($0 as NSString).size(withAttributes: attributes).width + 10) }
        let total = widths.reduce(0, +) + Self.capSpacing * CGFloat(max(0, caps.count - 1))
        var x = (bounds.width - total) / 2
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

    private func drawCentered(_ text: String, color: NSColor) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: color,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(
            at: CGPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
            withAttributes: attributes
        )
    }

    /// A message instead of caps: a hint after a rejected combination, or the prompt while
    /// recording with nothing held yet.
    private var plainText: String? {
        if let hint {
            return hint
        }
        if isRecording, pendingFlags.isEmpty {
            return String(localized: "Press keys…")
        }
        return nil
    }

    private var caps: [String] {
        guard isRecording else {
            return binding.keyCaps
        }

        return HotKeyBinding(keyCode: 0, modifiers: pendingFlags, label: "").keyCaps
    }
}
