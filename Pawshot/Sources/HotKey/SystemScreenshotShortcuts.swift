import AppKit
import Carbon.HIToolbox

/// Which of macOS's own screenshot shortcuts are switched on right now.
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
struct SystemScreenshotShortcuts: Equatable {
    struct Shortcut: Equatable {
        let id: Int
        let keyCode: UInt32
        let modifiers: NSEvent.ModifierFlags
        let isEnabled: Bool
        let name: String
    }

    let shortcuts: [Shortcut]

    /// The system's screenshot shortcuts as macOS ships them — used for any id missing from the
    /// preferences, which is what an untouched Mac looks like.
    static let factoryDefaults: [Shortcut] = [
        Shortcut(id: 28, keyCode: UInt32(kVK_ANSI_3), modifiers: [.shift, .command], isEnabled: true,
                 name: "Save picture of screen as a file"),
        Shortcut(id: 29, keyCode: UInt32(kVK_ANSI_3), modifiers: [.control, .shift, .command], isEnabled: true,
                 name: "Copy picture of screen to the clipboard"),
        Shortcut(id: 30, keyCode: UInt32(kVK_ANSI_4), modifiers: [.shift, .command], isEnabled: true,
                 name: "Save picture of selected area as a file"),
        Shortcut(id: 31, keyCode: UInt32(kVK_ANSI_4), modifiers: [.control, .shift, .command], isEnabled: true,
                 name: "Copy picture of selected area to the clipboard"),
        Shortcut(id: 184, keyCode: UInt32(kVK_ANSI_5), modifiers: [.shift, .command], isEnabled: true,
                 name: "Screenshot and recording options"),
        // The Touch Bar's own: the system takes ⇧⌘6 only on a Mac that has one, and there is no
        // public way to tell. So these count as off unless the preferences say otherwise — a
        // false warning about a key that works is worse than none. The ids are Apple's usual
        // ones, not checked on a Touch Bar Mac: the owner's has none.
        Shortcut(id: 181, keyCode: UInt32(kVK_ANSI_6), modifiers: [.shift, .command], isEnabled: false,
                 name: "Save picture of the Touch Bar as a file"),
        Shortcut(id: 182, keyCode: UInt32(kVK_ANSI_6), modifiers: [.control, .shift, .command], isEnabled: false,
                 name: "Copy picture of the Touch Bar to the clipboard"),
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

            let parameters = (entry["value"] as? [String: Any])?["parameters"] as? [NSNumber]
            guard let parameters, parameters.count == 3 else {
                return Shortcut(
                    id: fallback.id, keyCode: fallback.keyCode, modifiers: fallback.modifiers,
                    isEnabled: enabled, name: fallback.name
                )
            }

            let modifiers = NSEvent.ModifierFlags(rawValue: parameters[2].uintValue)
                .intersection([.shift, .control, .option, .command])
            return Shortcut(
                id: fallback.id,
                keyCode: parameters[1].uint32Value,
                modifiers: modifiers,
                isEnabled: enabled,
                name: fallback.name
            )
        }
    }

    /// Reads the live preferences.
    static func current() -> SystemScreenshotShortcuts {
        // Another app's domain is cached per process; without the sync an unticked item would
        // keep reading as enabled until Pawshot restarts.
        CFPreferencesAppSynchronize("com.apple.symbolichotkeys" as CFString)
        let value = CFPreferencesCopyAppValue(
            "AppleSymbolicHotKeys" as CFString,
            "com.apple.symbolichotkeys" as CFString
        )
        return SystemScreenshotShortcuts(symbolicHotKeys: value as? [String: Any])
    }

    /// The enabled system shortcut that takes this combination before Pawshot sees it, if any.
    func conflict(with binding: HotKeyBinding) -> Shortcut? {
        let flags = binding.modifierFlags.intersection([.shift, .control, .option, .command])
        return shortcuts.first { $0.isEnabled && $0.keyCode == binding.keyCode && $0.modifiers == flags }
    }
}
