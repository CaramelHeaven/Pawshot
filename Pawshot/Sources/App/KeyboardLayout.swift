import AppKit
import Carbon.HIToolbox

/// What key was pressed, regardless of the layout it was pressed in.
///
/// The editor drives everything off single letters, and reading them off the character the layout
/// produced meant that on ЙЦУКЕН `V` printed `м`, `B` printed `и`, and not one tool ever switched.
enum KeyboardLayout {
    /// The Latin character on the physical key. Cyrillic `с` on the `C` key comes back as `c`.
    ///
    /// A character that is already ASCII is handed back untouched rather than re-derived from the
    /// key code. That is deliberate: on Dvorak the letter printed on the key is the whole point,
    /// and the key code would name the ANSI position instead — turning `c` into `j`.
    static func latinCharacter(for event: NSEvent) -> String? {
        let typed = event.charactersIgnoringModifiers ?? ""
        if !typed.isEmpty, typed.allSatisfy(\.isASCII) {
            return typed
        }

        return latinCharacter(forKeyCode: event.keyCode)
    }

    /// The same key press as if it had been made on a Latin layout, or `nil` when it already was.
    ///
    /// ⌘-combinations are matched by the main menu and not by any view, so the fallback hands the
    /// menu a rewritten event instead of keeping a table of shortcuts of its own. One rewrite
    /// therefore covers every item there is — ⌘Q and ⌘, along with ⌘C, ⌘S and ⌘D — and nothing has
    /// to be kept in sync when a menu item is added.
    static func latinEquivalent(of event: NSEvent) -> NSEvent? {
        let typed = event.charactersIgnoringModifiers ?? ""
        guard typed.isEmpty || !typed.allSatisfy(\.isASCII) else { return nil }
        guard let latin = latinCharacter(forKeyCode: event.keyCode), latin != typed else {
            return nil
        }

        // Everything but the characters is carried over: the menu matches on the modifiers too,
        // and ⌘Z against ⇧⌘Z is the difference between undo and redo.
        return NSEvent.keyEvent(
            with: event.type,
            location: event.locationInWindow,
            modifierFlags: event.modifierFlags,
            timestamp: event.timestamp,
            windowNumber: event.windowNumber,
            context: nil,
            characters: latin,
            charactersIgnoringModifiers: latin,
            isARepeat: event.isARepeat,
            keyCode: event.keyCode
        )
    }

    /// Asks the current **ASCII-capable** layout what this key would print. That is the same
    /// fallback the system uses for menu key equivalents, which is why ⌘C keeps working in
    /// Cyrillic everywhere else on the Mac.
    ///
    /// Deliberately not cached. It only runs for a key that printed something non-ASCII — that is,
    /// once per keystroke and only while a non-Latin layout is on — and a cache would have to be
    /// invalidated when the input source changes, which is a whole class of stale-state bugs
    /// bought for microseconds.
    private static func latinCharacter(forKeyCode keyCode: UInt16) -> String? {
        guard
            let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
            let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }

        let layoutData = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(layoutData) else { return nil }

        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)

        // No modifier state: the canvas only ever asks about a bare key press, and the shifted
        // form of a letter is not what any of its shortcuts are keyed on.
        let status = UCKeyTranslate(
            layout,
            keyCode,
            UInt16(kUCKeyActionDisplay),
            0,
            UInt32(LMGetKbdType()),
            OptionBits(kUCKeyTranslateNoDeadKeysBit),
            &deadKeyState,
            characters.count,
            &length,
            &characters
        )

        guard status == noErr, length > 0 else { return nil }

        return String(utf16CodeUnits: characters, count: length)
    }
}
