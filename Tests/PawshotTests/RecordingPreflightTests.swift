import Carbon.HIToolbox
@testable import Pawshot
import XCTest

/// What the recording overlay says before the take: only what is wrong, only when it is wrong.
final class RecordingPreflightTests: XCTestCase {
    private let gigabyte: Int64 = 1_000_000_000
    /// An untouched Mac: ⇧⌘5, the system's "Screenshot and recording options", is on.
    private let untouched = SystemScreenshotShortcuts(symbolicHotKeys: nil)
    private let restart = HotKeyBinding(keyCode: UInt32(kVK_ANSI_5), modifiers: [.shift, .command], label: "5")

    func testNothingWrongSaysNothing() {
        let problems = RecordingPreflight.problems(
            microphoneIsOn: true, microphoneIsSilent: false, taken: [], freeBytes: 100 * gigabyte
        )
        XCTAssertTrue(problems.isEmpty)
    }

    func testASilentMicrophoneCountsOnlyWhileItIsOn() {
        XCTAssertEqual(
            RecordingPreflight.problems(microphoneIsOn: true, microphoneIsSilent: true, taken: [], freeBytes: nil),
            [.microphoneSilent]
        )
        // Off, it is meant to be silent; the meter's verdict is about a microphone nobody wants.
        XCTAssertTrue(
            RecordingPreflight.problems(microphoneIsOn: false, microphoneIsSilent: true, taken: [], freeBytes: nil).isEmpty
        )
    }

    func testTheDiskIsLowBelowTheThresholdAndUnknownIsNotLow() {
        let below = RecordingPreflight.lowDiskBytes - 1
        XCTAssertEqual(
            RecordingPreflight.problems(microphoneIsOn: false, microphoneIsSilent: false, taken: [], freeBytes: below),
            [.lowDisk(freeBytes: below)]
        )
        XCTAssertTrue(
            RecordingPreflight.problems(
                microphoneIsOn: false, microphoneIsSilent: false, taken: [], freeBytes: RecordingPreflight.lowDiskBytes
            ).isEmpty
        )
        // Could not be read: no warning out of thin air (the read itself is logged where it happens).
        XCTAssertTrue(
            RecordingPreflight.problems(microphoneIsOn: false, microphoneIsSilent: false, taken: [], freeBytes: nil).isEmpty
        )
    }

    func testAShortcutMacOSStillHoldsIsNamedWithTheItemToUntick() throws {
        let item = try XCTUnwrap(untouched.conflict(with: restart)?.name, "precondition: ⇧⌘5 is the system's")
        let taken = RecordingPreflight.taken(bindings: [("restart", restart)], by: untouched)
        XCTAssertEqual(
            taken,
            [RecordingPreflight.Taken(action: "restart", shortcut: restart.displayString, item: item)]
        )
    }

    func testAShortcutMacOSHasLetGoOfIsNotReported() {
        let unticked = SystemScreenshotShortcuts(symbolicHotKeys: [
            "184": [
                "enabled": NSNumber(value: false),
                "value": ["parameters": [NSNumber(value: 53), NSNumber(value: kVK_ANSI_5), NSNumber(value: 0x120000)]],
            ],
        ])
        XCTAssertNil(unticked.conflict(with: restart), "precondition: the item is off")
        XCTAssertTrue(RecordingPreflight.taken(bindings: [("restart", restart)], by: unticked).isEmpty)
    }

    func testAClearedShortcutHasNothingToTake() {
        XCTAssertTrue(RecordingPreflight.taken(bindings: [("restart", nil)], by: untouched).isEmpty)
    }

    func testEveryProblemHasWordsForThePill() {
        let taken = RecordingPreflight.Taken(action: "restart", shortcut: "⇧⌘5", item: "Screenshot and recording options")
        for problem in [RecordingPreflight.Problem.microphoneSilent, .shortcutsTaken([taken]), .lowDisk(freeBytes: gigabyte)] {
            XCTAssertFalse(problem.message.isEmpty, "\(problem)")
            XCTAssertFalse(problem.logDescription.isEmpty, "\(problem)")
        }
        XCTAssertTrue(RecordingPreflight.Problem.shortcutsTaken([taken]).message.contains("⇧⌘5"))
    }
}

extension RecordingPreflightTests {
    /// Everything wrong at once comes in reading order: what would show what it shouldn't first.
    func testProblemsComeInReadingOrder() {
        let taken = RecordingPreflight.Taken(action: "restart", shortcut: "⇧⌘5", item: "Options")
        let problems = RecordingPreflight.problems(
            microphoneIsOn: true, microphoneIsSilent: true, taken: [taken], freeBytes: 1, ignoredZones: 2
        )
        XCTAssertEqual(problems, [.zonesIgnored(2), .microphoneSilent, .shortcutsTaken([taken]), .lowDisk(freeBytes: 1)])
    }

    func testMoreThanOneShortcutTakenIsCounted() {
        let taken = (1 ... 3).map { RecordingPreflight.Taken(action: "a\($0)", shortcut: "⇧⌘\($0)", item: "Item \($0)") }
        let message = RecordingPreflight.Problem.shortcutsTaken(taken).message
        XCTAssertTrue(message.contains("⇧⌘1"), message)
        XCTAssertTrue(message.contains("2"), "the rest are counted: \(message)")
        XCTAssertFalse(RecordingPreflight.Problem.zonesIgnored(2).message.isEmpty)
    }
}
