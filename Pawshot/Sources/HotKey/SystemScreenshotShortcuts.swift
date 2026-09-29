import AppKit
import Carbon.HIToolbox
import os

/// Which of macOS's own shortcuts that take ours are switched on right now: the screenshot ones,
/// and "Move focus to next window".
///
/// The owner records with ⇧⌘3 and ⇧⌘4 — keys the system takes for its screenshots before Carbon
/// ever hands them to us. They start working the moment the matching item is unticked in
/// System Settings → Keyboard → Keyboard Shortcuts → Screenshots, and that state lives in the
/// `com.apple.symbolichotkeys` preferences. Reading it lets the settings window warn only while
/// the system still holds the key, instead of warning forever by pattern.
///
/// Checked on the owner's machine: id 28 is ⇧⌘3, 29 ⌃⇧⌘3, 30 ⇧⌘4, 31 ⌃⇧⌘4, 184 ⇧⌘5 (181 and 182, the
/// Touch Bar's ⇧⌘6 and ⌃⇧⌘6, are absent there — it has no Touch Bar). Each entry
/// carries `enabled` and `value.parameters = (character, key code, modifier flags)`.
///
/// Item 27, "Move focus to next window", came from a tester who had moved it from ⌘` to ⌘1: macOS
/// then took ⇧⌘1 too, as the other direction, and the default full-screen shortcut never fired.
/// That ⇧ goes along with a moved item is read off her log, not tried on a Mac.
struct SystemScreenshotShortcuts: Equatable {
    struct Shortcut: Equatable {
        let id: Int
        var keyCode: UInt32
        var modifiers: NSEvent.ModifierFlags
        var isEnabled: Bool
        let name: String
        /// Apple's name for the part of Keyboard Shortcuts the item is in.
        var section = String(localized: "System Settings section: Screenshots", defaultValue: "Screenshots")
        /// The same keys with ⇧ go the other way, and macOS takes them as well.
        var reversesWithShift = false
    }

    let shortcuts: [Shortcut]

    /// Keyboard → Keyboard Shortcuts, where the Screenshots items are unticked.
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")

    /// The system's screenshot shortcuts as macOS ships them — used for any id missing from the
    /// preferences, which is what an untouched Mac looks like.
    static let factoryDefaults: [Shortcut] = [
        Shortcut(id: 28, keyCode: UInt32(kVK_ANSI_3), modifiers: [.shift, .command], isEnabled: true,
                 name: String(localized: "Save picture of screen as a file")),
        Shortcut(id: 29, keyCode: UInt32(kVK_ANSI_3), modifiers: [.control, .shift, .command], isEnabled: true,
                 name: String(localized: "Copy picture of screen to the clipboard")),
        Shortcut(id: 30, keyCode: UInt32(kVK_ANSI_4), modifiers: [.shift, .command], isEnabled: true,
                 name: String(localized: "Save picture of selected area as a file")),
        Shortcut(id: 31, keyCode: UInt32(kVK_ANSI_4), modifiers: [.control, .shift, .command], isEnabled: true,
                 name: String(localized: "Copy picture of selected area to the clipboard")),
        Shortcut(id: 184, keyCode: UInt32(kVK_ANSI_5), modifiers: [.shift, .command], isEnabled: true,
                 name: String(localized: "Screenshot and recording options")),
        // The Touch Bar's own: the system takes ⇧⌘6 only on a Mac that has one, and there is no
        // public way to tell. So these count as off unless the preferences say otherwise — a
        // false warning about a key that works is worse than none. The ids are Apple's usual
        // ones, not checked on a Touch Bar Mac: the owner's has none.
        Shortcut(id: 181, keyCode: UInt32(kVK_ANSI_6), modifiers: [.shift, .command], isEnabled: false,
                 name: String(localized: "Save picture of the Touch Bar as a file")),
        Shortcut(id: 182, keyCode: UInt32(kVK_ANSI_6), modifiers: [.control, .shift, .command], isEnabled: false,
                 name: String(localized: "Copy picture of the Touch Bar to the clipboard")),
        Shortcut(id: 27, keyCode: UInt32(kVK_ANSI_Grave), modifiers: [.command], isEnabled: true,
                 name: String(localized: "Move focus to next window"),
                 section: String(localized: "System Settings section: Keyboard", defaultValue: "Keyboard"),
                 reversesWithShift: true),
    ]

    /// Parses the `AppleSymbolicHotKeys` dictionary. Anything unreadable falls back to the
    /// factory default for that id — a wrong "the system holds it" warning is better than a
    /// hotkey that silently never fires.
    init(symbolicHotKeys: [String: Any]?) {
        shortcuts = Self.factoryDefaults.map { fallback in
            guard
                let entry = symbolicHotKeys?[String(fallback.id)] as? [String: Any],
                let enabled = (entry["enabled"] as? NSNumber)?.boolValue
            else { return fallback }

            var shortcut = fallback
            shortcut.isEnabled = enabled
            let parameters = (entry["value"] as? [String: Any])?["parameters"] as? [NSNumber]
            guard let parameters, parameters.count == 3 else { return shortcut }

            shortcut.keyCode = parameters[1].uint32Value
            shortcut.modifiers = NSEvent.ModifierFlags(rawValue: parameters[2].uintValue)
                .intersection([.shift, .control, .option, .command])
            return shortcut
        }
    }

    /// Reads the live preferences.
    static func current() -> SystemScreenshotShortcuts {
        SystemScreenshotShortcuts(symbolicHotKeys: liveSymbolicHotKeys())
    }

    /// The raw table, read once where both it and `enabledShortcuts(in:)` are wanted.
    static func liveSymbolicHotKeys() -> [String: Any]? {
        // Another app's domain is cached per process; without the sync an unticked item would
        // keep reading as enabled until Pawshot restarts.
        CFPreferencesAppSynchronize("com.apple.symbolichotkeys" as CFString)
        let value = CFPreferencesCopyAppValue(
            "AppleSymbolicHotKeys" as CFString,
            "com.apple.symbolichotkeys" as CFString
        )
        let table = value as? [String: Any]
        if table == nil {
            let isFirst = unreadableReported.withLock { reported in
                defer { reported = true }
                return !reported
            }
            if isFirst {
                logger.error("macOS shortcuts unreadable: no AppleSymbolicHotKeys in com.apple.symbolichotkeys, factory defaults assumed")
            }
        }
        return table
    }

    /// Read on every redraw of Settings and the welcome window: said once per process.
    private static let unreadableReported = OSAllocatedUnfairLock(initialState: false)

    private static var logger: Logger {
        .pawshot("hotkey")
    }

    /// Every macOS shortcut in the preferences that is switched on and holds ⌘, ⌥ or ⌃ — any
    /// item, not just the screenshots. A combination macOS takes this way reaches Pawshot neither
    /// in the recorder nor through Carbon, so the saved log lists them all: a tester's ⇧⌘1 that
    /// never arrived is exactly the case. Only items the Mac's preferences mention are here — an
    /// untouched factory default isn't — and there is no table of names for them: the id is
    /// what System Settings' item is looked up by.
    static func enabledShortcuts(in symbolicHotKeys: [String: Any]?) -> [(id: Int, binding: HotKeyBinding)] {
        (symbolicHotKeys ?? [:]).compactMap { key, value in
            guard
                let id = Int(key),
                let entry = value as? [String: Any],
                (entry["enabled"] as? NSNumber)?.boolValue == true,
                let parameters = (entry["value"] as? [String: Any])?["parameters"] as? [NSNumber],
                parameters.count == 3,
                parameters[1].intValue != 0xFFFF
            else { return nil }

            let modifiers = NSEvent.ModifierFlags(rawValue: parameters[2].uintValue)
                .intersection([.shift, .control, .option, .command])
            guard HotKeyBinding.isUsable(modifiers) else { return nil }

            let character = parameters[0].intValue
            let label = switch character {
            case 32: "Space"
            case 33 ..< 0xFFFF: UnicodeScalar(character).map { String($0).uppercased() } ?? "Key \(parameters[1])"
            default: "Key \(parameters[1])"
            }
            return (id, HotKeyBinding(keyCode: parameters[1].uint32Value, modifiers: modifiers, label: label))
        }
        .sorted { $0.id < $1.id }
    }

    /// The enabled system shortcut that takes this combination before Pawshot sees it, if any.
    func conflict(with binding: HotKeyBinding) -> Shortcut? {
        let flags = binding.modifierFlags.intersection([.shift, .control, .option, .command])
        return shortcuts.first { shortcut in
            shortcut.isEnabled && shortcut.keyCode == binding.keyCode
                && (shortcut.modifiers == flags || shortcut.reversesWithShift && shortcut.modifiers.union(.shift) == flags)
        }
    }

    /// Each system item any of `bindings` runs into, once: "Move focus to next window" can hold
    /// two of ours, ⌘1 and ⇧⌘1, and is still one item to untick.
    func conflicts(with bindings: [HotKeyBinding]) -> [Shortcut] {
        Self.unique(bindings.compactMap(conflict(with:)))
    }

    /// In order, each item once.
    static func unique(_ items: [Shortcut]) -> [Shortcut] {
        items.reduce(into: []) { unique, item in
            if !unique.contains(where: { $0.id == item.id }) {
                unique.append(item)
            }
        }
    }
}
