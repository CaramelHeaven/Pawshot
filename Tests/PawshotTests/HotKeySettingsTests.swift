import AppKit
import Carbon.HIToolbox
@testable import Pawshot
import XCTest

final class HotKeyBindingTests: XCTestCase {
    private func keyEvent(
        keyCode: Int,
        flags: NSEvent.ModifierFlags,
        characters: String
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: UInt16(keyCode)
        ))
    }

    /// The conversion is the one place where a mistake is silent: a wrong mask registers fine and
    /// the hotkey simply never fires.
    func testModifierConversionSurvivesBothDirections() {
        let flags: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
        let binding = HotKeyBinding(keyCode: 0, modifiers: flags, label: "A")

        XCTAssertEqual(binding.carbonModifiers, UInt32(cmdKey | shiftKey | optionKey | controlKey))
        XCTAssertEqual(binding.modifierFlags, flags)
    }

    /// macOS prints modifiers in a fixed order — ⌃⌥⇧⌘ — and a menu that disagrees looks foreign.
    func testDisplayStringFollowsTheMacOrder() {
        XCTAssertEqual(HotKeyBinding.regionDefault.displayString, "⇧⌘2")
        XCTAssertEqual(
            HotKeyBinding(keyCode: 0, modifiers: [.control, .option], label: "F5").displayString,
            "⌃⌥F5"
        )
        XCTAssertEqual(
            HotKeyBinding(keyCode: 0, modifiers: [.command, .control], label: "P").displayString,
            "⌃⌘P"
        )
    }

    /// A combination without ⌘/⌥/⌃ would fire while typing in any other app.
    func testShiftAloneIsNotAUsableHotKey() throws {
        let bare = try keyEvent(keyCode: kVK_ANSI_A, flags: [], characters: "a")
        let shifted = try keyEvent(keyCode: kVK_ANSI_A, flags: [.shift], characters: "A")
        let commanded = try keyEvent(keyCode: kVK_ANSI_A, flags: [.command], characters: "a")

        XCTAssertNil(HotKeyBinding.from(event: bare))
        XCTAssertNil(HotKeyBinding.from(event: shifted))
        XCTAssertNotNil(HotKeyBinding.from(event: commanded))
    }

    func testLabelComesFromTheKeyThatWasPressed() throws {
        let letter = try keyEvent(keyCode: kVK_ANSI_D, flags: [.command], characters: "d")
        let space = try keyEvent(keyCode: kVK_Space, flags: [.command], characters: " ")

        XCTAssertEqual(HotKeyBinding.from(event: letter)?.displayString, "⌘D")
        XCTAssertEqual(HotKeyBinding.from(event: space)?.displayString, "⌘Space")
    }

    /// The hotkey itself is registered by key code and never cared about the layout, but its label
    /// did: a combination recorded on ЙЦУКЕН used to read `⇧⌘Ф` in the settings window, naming a
    /// letter that is nowhere on the shortcut.
    func testLabelStaysLatinWhenRecordedOnACyrillicLayout() throws {
        let event = try keyEvent(keyCode: kVK_ANSI_A, flags: [.command, .shift], characters: "ф")

        XCTAssertEqual(HotKeyBinding.from(event: event)?.displayString, "⇧⌘A")
    }

    /// The recorder and the welcome window draw one cap per key; the order has to be the one macOS
    /// prints, the same as the joined string.
    func testKeyCapsSplitTheCombinationInMacOrder() {
        XCTAssertEqual(HotKeyBinding.regionDefault.keyCaps, ["⇧", "⌘", "2"])
        XCTAssertEqual(
            HotKeyBinding(keyCode: 0, modifiers: [.command, .control, .option], label: "Space").keyCaps,
            ["⌃", "⌥", "⌘", "Space"]
        )
        XCTAssertEqual(HotKeyBinding(keyCode: 0, modifiers: [.shift], label: "").keyCaps, ["⇧"])
    }

    /// The menu prints the global hotkey through a SwiftUI shortcut. A wrong mapping shows a
    /// combination that doesn't capture anything, which is worse than showing none.
    func testMenuShortcutMatchesTheHotKey() throws {
        let region = try XCTUnwrap(HotKeyBinding.regionDefault.keyboardShortcut)
        XCTAssertEqual(region.key, "2")
        XCTAssertEqual(region.modifiers, [.command, .shift])

        let letter = try XCTUnwrap(
            HotKeyBinding(keyCode: UInt32(kVK_ANSI_P), modifiers: [.control, .option], label: "P").keyboardShortcut
        )
        XCTAssertEqual(letter.key, "p", "menu key equivalents are lowercase; the modifiers carry ⇧")
        XCTAssertEqual(letter.modifiers, [.control, .option])

        let space = try XCTUnwrap(
            HotKeyBinding(keyCode: UInt32(kVK_Space), modifiers: [.command], label: "Space").keyboardShortcut
        )
        XCTAssertEqual(space.key, .space)
    }

    func testUnnameableKeyGetsNoMenuShortcut() {
        XCTAssertNil(HotKeyBinding(keyCode: 105, modifiers: [.command], label: "Key 105").keyboardShortcut)
    }
}

@MainActor
final class SettingsTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        // A suite of our own: a test must never touch the owner's real settings.
        suiteName = "PawshotTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testFreshInstallGetsTheDefaults() {
        let settings = Settings(defaults: defaults)

        XCTAssertEqual(settings.regionHotKey, .regionDefault)
        XCTAssertEqual(settings.fullScreenHotKey, .fullScreenDefault)
    }

    func testStoredHotKeySurvivesARestart() {
        let custom = HotKeyBinding(keyCode: UInt32(kVK_ANSI_P), modifiers: [.command, .option], label: "P")

        Settings(defaults: defaults).regionHotKey = custom

        XCTAssertEqual(Settings(defaults: defaults).regionHotKey, custom, "a new instance reads it back")
        XCTAssertEqual(Settings(defaults: defaults).fullScreenHotKey, .fullScreenDefault)
    }

    /// Garbage in the defaults must not leave the app without a hotkey at all.
    func testUnreadableValueFallsBackToTheDefault() {
        defaults.set(Data("not json".utf8), forKey: Settings.Key.regionHotKey.rawValue)

        XCTAssertEqual(Settings(defaults: defaults).regionHotKey, .regionDefault)
    }

    func testChangeIsAnnouncedSoTheHotKeyCanBeReRegistered() {
        let settings = Settings(defaults: defaults)
        var announced = 0
        settings.onHotKeysChange = { announced += 1 }

        settings.regionHotKey = HotKeyBinding(keyCode: 1, modifiers: [.command], label: "S")
        settings.resetHotKeysToDefaults()

        XCTAssertEqual(announced, 2)
        XCTAssertEqual(settings.regionHotKey, .regionDefault)
    }

    /// ⇧⌘3 and ⇧⌘4 record — the owner's choice, made knowing macOS takes them until they are
    /// unticked in Keyboard Shortcuts. The microphone is off until asked for, system audio is on.
    func testRecordingDefaults() {
        let settings = Settings(defaults: defaults)

        XCTAssertEqual(settings.recordRegionHotKey.displayString, "⇧⌘3")
        XCTAssertEqual(settings.recordFullScreenHotKey.displayString, "⇧⌘4")
        XCTAssertEqual(settings.zoomMarkHotKey, .zoomMarkDefault)
        XCTAssertEqual(settings.penHotKey, .penDefault)
        XCTAssertEqual(settings.restartHotKey.displayString, "⇧⌘5")
        XCTAssertEqual(settings.zoomMarkHotKey.displayString, "⇧⌘6")
        XCTAssertEqual(settings.penHotKey.displayString, "⇧⌘7")
        XCTAssertEqual(settings.allHotKeys.count, 7, "no separate stop: the start shortcut stops")
        let all = settings.allHotKeys
        for (index, binding) in all.enumerated() {
            XCTAssertFalse(all[(index + 1)...].contains(binding), "\(binding.displayString) is used twice")
        }
        XCTAssertFalse(settings.recordsMicrophone)
        XCTAssertTrue(settings.recordsSystemAudio)

        settings.recordsMicrophone = true
        settings.recordsSystemAudio = false
        XCTAssertTrue(Settings(defaults: defaults).recordsMicrophone)
        XCTAssertFalse(Settings(defaults: defaults).recordsSystemAudio)
    }

    /// The ghost is per display: the same rectangle means nothing on another screen.
    func testLastRecordingAreaIsRememberedPerDisplay() {
        let settings = Settings(defaults: defaults)
        XCTAssertNil(settings.lastRecordingArea(on: 1))
        XCTAssertTrue(settings.recordsAtNativeResolution, "2x by default")

        settings.setLastRecordingArea(CGRect(x: 10, y: 20, width: 300, height: 200), on: 1)
        settings.setLastRecordingArea(CGRect(x: 0, y: 0, width: 640, height: 360), on: 2)

        let reread = Settings(defaults: defaults)
        XCTAssertEqual(reread.lastRecordingArea(on: 1), CGRect(x: 10, y: 20, width: 300, height: 200))
        XCTAssertEqual(reread.lastRecordingArea(on: 2), CGRect(x: 0, y: 0, width: 640, height: 360))
        XCTAssertNil(reread.lastRecordingArea(on: 3))
    }

    /// Clicks and zooms go into the video unless switched off; the editor's key hints count the
    /// openings.
    func testVideoSettingsDefaults() {
        let settings = Settings(defaults: defaults)
        XCTAssertTrue(settings.showsClicks)
        XCTAssertTrue(settings.showsZooms)
        XCTAssertFalse(settings.showsKeystrokes, "reading the keyboard is never on by default")
        XCTAssertEqual(settings.videoEditorOpenCount, 0)

        settings.showsClicks = false
        settings.recordVideoEditorOpen()

        let reread = Settings(defaults: defaults)
        XCTAssertFalse(reread.showsClicks)
        XCTAssertEqual(reread.videoEditorOpenCount, 1)
    }

    func testResetBringsTheRecordingShortcutsBackToo() {
        let settings = Settings(defaults: defaults)
        settings.recordRegionHotKey = HotKeyBinding(keyCode: UInt32(kVK_ANSI_R), modifiers: [.command, .option], label: "R")
        settings.penHotKey = HotKeyBinding(keyCode: UInt32(kVK_ANSI_P), modifiers: [.control, .option], label: "P")
        settings.restartHotKey = HotKeyBinding(keyCode: UInt32(kVK_ANSI_Q), modifiers: [.control, .option], label: "Q")

        settings.resetHotKeysToDefaults()

        XCTAssertEqual(settings.recordRegionHotKey, .recordRegionDefault)
        XCTAssertEqual(settings.penHotKey, .penDefault)
        XCTAssertEqual(settings.restartHotKey, .restartDefault)
    }

    func testCaptureCountGrowsByOnePerShot() {
        let settings = Settings(defaults: defaults)
        XCTAssertEqual(settings.captureCount, 0)

        settings.recordCapture()
        settings.recordCapture()

        XCTAssertEqual(Settings(defaults: defaults).captureCount, 2)
    }
}
