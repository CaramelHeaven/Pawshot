import AppKit
import Carbon.HIToolbox

/// A key combination, stored the way `RegisterEventHotKey` wants it: a virtual key code plus a
/// Carbon modifier mask.
///
/// Carbon is the storage format on purpose. The alternative — keeping `NSEvent.ModifierFlags` and
/// converting on every registration — puts the conversion on the path where a mistake is silent:
/// the hotkey simply never fires. Here the conversion happens once, when the combination is
/// recorded, and both directions are covered by tests.
struct HotKeyBinding: Equatable, Codable {
    let keyCode: UInt32
    let carbonModifiers: UInt32
    /// What was printed on the key when it was recorded, e.g. `2` or `A`.
    ///
    /// Kept alongside the code because a key code alone doesn't say what to draw: on a non-US
    /// layout the same code is a different letter. The character comes straight from the event the
    /// user produced, so the label always matches what they pressed.
    let label: String

    /// `⌘⇧2` — what logs and warnings show.
    var displayString: String {
        keyCaps.joined()
    }

    /// One entry per key, in the order macOS prints them: `["⇧", "⌘", "2"]`. The recorder and the
    /// welcome window draw each entry as its own key cap.
    var keyCaps: [String] {
        var caps: [String] = []
        if carbonModifiers & UInt32(controlKey) != 0 {
            caps.append("⌃")
        }
        if carbonModifiers & UInt32(optionKey) != 0 {
            caps.append("⌥")
        }
        if carbonModifiers & UInt32(shiftKey) != 0 {
            caps.append("⇧")
        }
        if carbonModifiers & UInt32(cmdKey) != 0 {
            caps.append("⌘")
        }
        if !label.isEmpty {
            caps.append(label)
        }

        return caps
    }

    var modifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if carbonModifiers & UInt32(cmdKey) != 0 {
            flags.insert(.command)
        }
        if carbonModifiers & UInt32(shiftKey) != 0 {
            flags.insert(.shift)
        }
        if carbonModifiers & UInt32(optionKey) != 0 {
            flags.insert(.option)
        }
        if carbonModifiers & UInt32(controlKey) != 0 {
            flags.insert(.control)
        }

        return flags
    }

    init(keyCode: UInt32, carbonModifiers: UInt32, label: String) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
        self.label = label
    }

    init(keyCode: UInt32, modifiers: NSEvent.ModifierFlags, label: String) {
        self.init(
            keyCode: keyCode,
            carbonModifiers: Self.carbonModifiers(from: modifiers),
            label: label
        )
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mask: UInt32 = 0
        if flags.contains(.command) {
            mask |= UInt32(cmdKey)
        }
        if flags.contains(.shift) {
            mask |= UInt32(shiftKey)
        }
        if flags.contains(.option) {
            mask |= UInt32(optionKey)
        }
        if flags.contains(.control) {
            mask |= UInt32(controlKey)
        }

        return mask
    }

    /// A combination is only usable as a global hotkey when it carries at least one of ⌘ ⌃ ⌥.
    /// A bare letter, or one with only ⇧, would fire while typing in any other app.
    static func isUsable(_ flags: NSEvent.ModifierFlags) -> Bool {
        flags.contains(.command) || flags.contains(.control) || flags.contains(.option)
    }

    /// Builds a binding out of a key press caught by the recorder. Returns `nil` for combinations
    /// that must not become a global hotkey.
    static func from(event: NSEvent) -> HotKeyBinding? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard isUsable(flags) else { return nil }

        return HotKeyBinding(
            keyCode: UInt32(event.keyCode),
            modifiers: flags,
            label: label(for: event)
        )
    }

    /// The visible name of the key; keys that print nothing get a name from the table.
    ///
    /// The letter is the **Latin** one on that key, not the one the current layout prints. The
    /// hotkey is registered by key code and never cared about the layout, but the label did: a
    /// combination recorded on ЙЦУКЕН used to read `⇧⌘Ф` in the settings window, naming a letter
    /// that appears nowhere on the shortcut.
    private static func label(for event: NSEvent) -> String {
        if let named = namedKeys[Int(event.keyCode)] {
            return named
        }

        let characters = KeyboardLayout.latinCharacter(for: event) ?? ""
        return characters.isEmpty ? "Key \(event.keyCode)" : characters.uppercased()
    }

    private static let namedKeys: [Int: String] = [
        kVK_Space: "Space",
        kVK_Return: "↩",
        kVK_Tab: "⇥",
        kVK_Delete: "⌫",
        kVK_ForwardDelete: "⌦",
        kVK_Escape: "⎋",
        kVK_LeftArrow: "←",
        kVK_RightArrow: "→",
        kVK_UpArrow: "↑",
        kVK_DownArrow: "↓",
        kVK_Home: "↖",
        kVK_End: "↘",
        kVK_PageUp: "⇞",
        kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4",
        kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
        kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]
}

extension HotKeyBinding {
    /// ⌘⇧2 — what the app has always used for a region capture.
    static let regionDefault = HotKeyBinding(
        keyCode: UInt32(kVK_ANSI_2),
        carbonModifiers: UInt32(cmdKey | shiftKey),
        label: "2"
    )

    /// ⌘⇧1 for the full screen. Deliberately not ⌘⇧3: the system holds that one, and a default
    /// that silently never fires is worse than an unfamiliar one.
    static let fullScreenDefault = HotKeyBinding(
        keyCode: UInt32(kVK_ANSI_1),
        carbonModifiers: UInt32(cmdKey | shiftKey),
        label: "1"
    )

    /// ⌘⇧3 records a region — the owner's choice, taking the key from the system screenshot on
    /// purpose. It only fires once "Save picture of screen as a file" is switched off in Keyboard
    /// Shortcuts; `SystemScreenshotShortcuts` tells the settings window whether it still is.
    static let recordRegionDefault = HotKeyBinding(
        keyCode: UInt32(kVK_ANSI_3),
        carbonModifiers: UInt32(cmdKey | shiftKey),
        label: "3"
    )

    /// ⌘⇧4 records the whole screen, with the same caveat as ⌘⇧3.
    static let recordFullScreenDefault = HotKeyBinding(
        keyCode: UInt32(kVK_ANSI_4),
        carbonModifiers: UInt32(cmdKey | shiftKey),
        label: "4"
    )

    /// ⇧⌘6 marks a zoom in a recording. Registered only while a take runs.
    ///
    /// The recording-time shortcuts continue the ⇧⌘ + digit row the takes start on — the owner
    /// found ⌃⌥ + letter too awkward to press mid-take.
    static let zoomMarkDefault = HotKeyBinding(
        keyCode: UInt32(kVK_ANSI_6),
        carbonModifiers: UInt32(cmdKey | shiftKey),
        label: "6"
    )

    /// ⇧⌘5 throws the take away and starts over. Registered only while a take runs; the owner
    /// unticked the system's ⇧⌘5. There is no separate stop: the shortcut that started the take
    /// stops it.
    static let restartDefault = HotKeyBinding(
        keyCode: UInt32(kVK_ANSI_5),
        carbonModifiers: UInt32(cmdKey | shiftKey),
        label: "5"
    )

    /// ⇧⌘7 switches the pen in a recording. Registered only while a take runs.
    static let penDefault = HotKeyBinding(
        keyCode: UInt32(kVK_ANSI_7),
        carbonModifiers: UInt32(cmdKey | shiftKey),
        label: "7"
    )
}
