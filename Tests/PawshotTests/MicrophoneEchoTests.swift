@testable import Pawshot
import XCTest

/// The microphone check keeps three seconds and not a frame more. The audio path itself needs a
/// microphone and its permission, so it is left to the owner's ears.
final class MicrophoneEchoTests: XCTestCase {
    func testKeepsExactlyTheSecondsAsked() {
        var buffer = EchoBuffer(seconds: 3, sampleRate: 48000)
        XCTAssertEqual(buffer.capacity, 144_000)
        XCTAssertFalse(buffer.isFull)

        XCTAssertEqual(buffer.take(100_000), 100_000)
        XCTAssertFalse(buffer.isFull)
        // The last chunk is cut to what still fits.
        XCTAssertEqual(buffer.take(100_000), 44000)
        XCTAssertTrue(buffer.isFull)
        XCTAssertEqual(buffer.frames, 144_000)
    }

    func testAFullBufferTakesNothingMore() {
        var buffer = EchoBuffer(seconds: 1, sampleRate: 10)
        XCTAssertEqual(buffer.take(10), 10)
        XCTAssertEqual(buffer.take(4), 0)
        XCTAssertEqual(buffer.frames, 10)
    }

    func testANegativeOrEmptyChunkKeepsNothing() {
        var buffer = EchoBuffer(seconds: 1, sampleRate: 10)
        XCTAssertEqual(buffer.take(0), 0)
        XCTAssertEqual(buffer.take(-5), 0)
        XCTAssertEqual(buffer.frames, 0)
    }
}
