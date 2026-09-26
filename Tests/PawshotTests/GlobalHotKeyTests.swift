import Carbon.HIToolbox
@testable import Pawshot
import XCTest

/// A hotkey must let go of its combination the moment its owner lets go of it. The registry used to
/// hold every hotkey strongly, so dropping one never ran its `deinit`: the combination stayed taken
/// for good, and the next registration of it failed with -9878 — which is what every recording
/// after the first ran into.
@MainActor
final class GlobalHotKeyTests: XCTestCase {
    private let binding = HotKeyBinding(
        keyCode: UInt32(kVK_ANSI_K),
        modifiers: [.control, .option, .shift, .command],
        label: "K"
    )

    func testDroppedHotKeyFreesItsCombination() throws {
        var first: GlobalHotKey? = try GlobalHotKey.register(binding) {}
        XCTAssertNotNil(first)
        first = nil

        let second = try? GlobalHotKey.register(binding) {}
        XCTAssertNotNil(second, "the combination is free again once the first hotkey is gone")
    }

    func testTheSameCombinationCannotBeHeldTwice() throws {
        let held = try GlobalHotKey.register(binding) {}
        defer { _ = held }

        XCTAssertThrowsError(try GlobalHotKey.register(binding) {})
    }
}
