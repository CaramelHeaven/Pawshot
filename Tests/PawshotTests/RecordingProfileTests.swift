@testable import Pawshot
import XCTest

/// A profile is a handful of the recording settings picked in one move. It states only what it
/// cares about; everything else stays as the person left it.
@MainActor
final class RecordingProfileTests: XCTestCase {
    private var suite = ""
    private var settings: Settings!

    override func setUp() async throws {
        suite = "pawshot.profile-tests.\(UUID().uuidString)"
        settings = Settings(defaults: UserDefaults(suiteName: suite)!)
    }

    override func tearDown() async throws {
        UserDefaults().removePersistentDomain(forName: suite)
    }

    func testBugReportIsAGifWithClicksAndNoSound() {
        settings.recordsMicrophone = true
        settings.recordsSystemAudio = true
        settings.showsClicks = false
        settings.recordingFramesPerSecond = 60
        settings.videoPreset = .original

        RecordingProfile.bugReport.apply(to: settings)
        XCTAssertEqual(settings.recordingFramesPerSecond, 30)

        XCTAssertFalse(settings.recordsMicrophone)
        XCTAssertFalse(settings.recordsSystemAudio)
        XCTAssertTrue(settings.showsClicks)
        XCTAssertEqual(settings.videoPreset, .gif)
    }

    func testDemoIsFullResolutionWithVoice() {
        settings.recordsMicrophone = false
        settings.recordsAtNativeResolution = false
        settings.recordingFramesPerSecond = 15
        settings.videoPreset = .gif

        RecordingProfile.demo.apply(to: settings)
        XCTAssertEqual(settings.recordingFramesPerSecond, 60)

        XCTAssertTrue(settings.recordsMicrophone)
        XCTAssertTrue(settings.recordsAtNativeResolution)
        XCTAssertEqual(settings.videoPreset, .original)
    }

    func testWhatAProfileDoesNotStateIsLeftAlone() {
        settings.showsKeystrokes = true
        settings.recordsAtNativeResolution = false
        RecordingProfile.bugReport.apply(to: settings)
        XCTAssertTrue(settings.showsKeystrokes)
        XCTAssertFalse(settings.recordsAtNativeResolution)
    }

    func testTheCurrentProfileIsRecognisedUntilOneSettingMovesAway() {
        for profile in RecordingProfile.allCases {
            profile.apply(to: settings)
            XCTAssertEqual(RecordingProfile.current(in: settings), profile, "\(profile)")
        }

        RecordingProfile.bugReport.apply(to: settings)
        settings.recordsMicrophone = true
        XCTAssertNil(RecordingProfile.current(in: settings), "a hand-changed setting is nobody's profile")
    }

    func testPCyclesThroughTheProfilesAndStartsWithTheFirstFromCustom() {
        XCTAssertEqual(RecordingProfile.next(after: nil), .bugReport)
        XCTAssertEqual(RecordingProfile.next(after: .bugReport), .demo)
        XCTAssertEqual(RecordingProfile.next(after: .demo), .bugReport)
    }

    func testEveryProfileHasWords() {
        for profile in RecordingProfile.allCases {
            XCTAssertFalse(profile.title.isEmpty)
            XCTAssertFalse(profile.summary.isEmpty)
        }
    }
}
