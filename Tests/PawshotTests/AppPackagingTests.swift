import AppKit
@testable import Pawshot
import ServiceManagement
import SwiftUI
import XCTest

final class LoginItemTests: XCTestCase {
    /// The real `SMAppService` must not be touched in tests — it would register a system login
    /// item. So what is checked here is exactly the mapping of system statuses to UI state.
    func testStatusMapping() {
        XCTAssertEqual(LoginItem.state(from: .enabled), .enabled)
        XCTAssertEqual(LoginItem.state(from: .notRegistered), .disabled)
        XCTAssertEqual(LoginItem.state(from: .notFound), .disabled)
        XCTAssertEqual(LoginItem.state(from: .requiresApproval), .requiresApproval)
    }

    func testOnlyEnabledCountsAsOn() {
        XCTAssertTrue(LoginItem.State.enabled.isOn)
        XCTAssertFalse(LoginItem.State.requiresApproval.isOn, "waiting for approval means it's off")
        XCTAssertFalse(LoginItem.State.disabled.isOn)
        XCTAssertFalse(LoginItem.State.unavailable.isOn)
    }

    /// Launch at login remembers the bundle path, so a copy in a build folder doesn't get it.
    func testApplicationsFolderCheckRejectsBuildFolder() {
        XCTAssertFalse(
            LoginItem.isInApplicationsFolder,
            "tests run from DerivedData, so the check has to return false"
        )
    }
}

@MainActor
final class AboutPanelTests: XCTestCase {
    func testVersionComesFromBundle() {
        let expected = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String

        XCTAssertEqual(AboutPanel.version, expected)
        XCTAssertNotEqual(AboutPanel.version, "—", "the version wasn't read from Info.plist")
    }

    /// Since Sparkle the build number is the version; "0.4.5 (0.4.5)" is not a version line.
    func testVersionLineShowsTheBuildOnlyWhenItDiffers() {
        XCTAssertEqual(AboutPanel.versionLine(version: "0.4.5", build: "0.4.5"), "0.4.5")
        XCTAssertEqual(AboutPanel.versionLine(version: "0.4.5", build: "7"), "0.4.5 (7)")
    }

    func testCopyrightComesFromInfoPlist() {
        XCTAssertTrue(AboutPanel.copyright.contains("CaramelHeaven"), AboutPanel.copyright)
    }

    func testCreditsCarryRepositoryLink() {
        XCTAssertTrue(AboutPanel.repositoryURL.hasPrefix("https://"))
        XCTAssertNotNil(URL(string: AboutPanel.repositoryURL))
    }
}

final class WhatsNewTests: XCTestCase {
    /// A new entry goes on top with every version bump (AGENTS.md, Releasing). A raised
    /// `MARKETING_VERSION` with no entry of its own fails here.
    func testTheNewestEntryIsForThisVersion() {
        XCTAssertEqual(WhatsNew.history.first?.version, AboutPanel.version, "MARKETING_VERSION was raised: add its WhatsNew entry")
    }

    private let history = [
        WhatsNew.Entry(version: "0.4.10", text: "Ten"),
        WhatsNew.Entry(version: "0.4.9", text: "Nine"),
        WhatsNew.Entry(version: "0.4.8", text: ""),
        WhatsNew.Entry(version: "0.4.7", text: "Seven"),
    ]

    /// From 0.4.6 to 0.4.9 is everything in between, not only 0.4.9's words.
    func testEverySkippedVersionIsTold() {
        func versions(since: String?) -> [String] {
            WhatsNew.entries(in: history, since: since).map(\.version)
        }

        XCTAssertEqual(versions(since: nil), ["0.4.10", "0.4.9", "0.4.7"], "0.4.6 and older stored no version: all of it")
        XCTAssertEqual(versions(since: "0.4.6"), ["0.4.10", "0.4.9", "0.4.7"])
        XCTAssertEqual(versions(since: "0.4.7"), ["0.4.10", "0.4.9"], "a release with nothing to tell is left out")
        XCTAssertEqual(versions(since: "0.4.9"), ["0.4.10"], "0.4.10 is after 0.4.9, not before it")
        XCTAssertEqual(versions(since: "0.4.10"), [])
    }

    /// What the launch records as seen only ever goes up: a 0.4.8 build run after 0.4.9 used to
    /// write 0.4.8 back, and 0.4.9's news showed a second time.
    func testAnOlderBuildIsNotNewerThanTheVersionSeen() {
        XCTAssertFalse(WhatsNew.isNewer("0.4.8", than: "0.4.9"))
        XCTAssertFalse(WhatsNew.isNewer("0.4.9", than: "0.4.9"))
        XCTAssertTrue(WhatsNew.isNewer("0.4.10", than: "0.4.9"))
        XCTAssertTrue(WhatsNew.isNewer("0.4.9", than: nil))
    }

    /// Once after an update — never on a fresh install, where the welcome window speaks first.
    func testShownOnceAfterAnUpdateOnly() {
        func shows(_ lastSeen: String?, welcomed: Bool = true) -> Bool {
            WhatsNew.shouldShow(lastSeen: lastSeen, welcomeCompleted: welcomed, current: "0.4.10", history: history)
        }

        XCTAssertFalse(shows(nil, welcomed: false), "a fresh install gets the welcome window")
        XCTAssertTrue(shows(nil), "an update from 0.4.6, which never stored a version")
        XCTAssertTrue(shows("0.4.9"))
        XCTAssertFalse(shows("0.4.10"), "already seen")
        let upToEight = Array(history.drop { $0.version != "0.4.8" })
        XCTAssertFalse(
            WhatsNew.shouldShow(lastSeen: "0.4.7", welcomeCompleted: true, current: "0.4.8", history: upToEight),
            "a release with nothing to tell"
        )
    }

    /// Many skipped versions scroll inside a window of bounded height; a few don't scroll at all.
    /// A `ScrollView` that collapsed to nothing, or grew with its content, fails here.
    @MainActor
    func testALongHistoryScrollsInsteadOfGrowingTheWindow() {
        func height(_ count: Int) -> CGFloat {
            let paragraph = String(repeating: "A change a person would notice, told in plain words. ", count: 4)
            let entries = (0 ..< count).map { WhatsNew.Entry(version: "0.4.\(40 - $0)", text: paragraph) }
            let view = NSHostingView(rootView: WhatsNewContent(from: "0.4.6", current: "0.4.40", entries: entries) {})
            return view.fittingSize.height
        }

        let one = height(1)
        let three = height(3)
        let many = height(12)
        XCTAssertGreaterThan(three, one, "the list takes the room its text needs")
        XCTAssertLessThanOrEqual(many, one + WhatsNewContent.listMaxHeight, "the list stops growing and scrolls")
        XCTAssertGreaterThan(many, three)
    }

    /// After Sparkle's relaunch nobody activates Pawshot, and 0.4.7's What's New opened behind
    /// the app in front. The test host is a background app too: a window nobody ordered in has
    /// to come up by itself.
    @MainActor
    func testTheWindowComesForwardByItself() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = NSHostingView(rootView: Color.clear.background(ComesForward("test")))
        window.contentView?.layoutSubtreeIfNeeded()

        let deadline = Date().addingTimeInterval(1)
        while !window.isVisible, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(window.isVisible)
    }
}

final class AppIconTests: XCTestCase {
    /// Catches the "the PNGs never made it into the bundle" case: the icon is in the repository,
    /// but the asset didn't get into the build and Finder shows a grey rectangle.
    func testApplicationIconIsPresentAndSquare() throws {
        let icon = try XCTUnwrap(NSImage(named: NSImage.applicationIconName))

        XCTAssertGreaterThan(icon.size.width, 0)
        XCTAssertEqual(icon.size.width, icon.size.height, accuracy: 0.001)
    }
}
