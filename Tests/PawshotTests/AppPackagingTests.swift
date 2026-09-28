import AppKit
@testable import Pawshot
import ServiceManagement
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
    /// The text is rewritten with every version bump (AGENTS.md, Releasing). A raised
    /// `MARKETING_VERSION` still carrying the last version's words fails here.
    func testTheTextIsForThisVersion() {
        XCTAssertEqual(WhatsNew.version, AboutPanel.version, "MARKETING_VERSION was raised: rewrite WhatsNew for it")
    }

    /// Once after an update — never on a fresh install, where the welcome window speaks first.
    func testShownOnceAfterAnUpdateOnly() {
        func shows(_ lastSeen: String?, welcomed: Bool = true, text: String = "News") -> Bool {
            WhatsNew.shouldShow(lastSeen: lastSeen, welcomeCompleted: welcomed, current: "0.4.7", text: text)
        }

        XCTAssertFalse(shows(nil, welcomed: false), "a fresh install gets the welcome window")
        XCTAssertTrue(shows(nil), "an update from 0.4.6, which never stored a version")
        XCTAssertTrue(shows("0.4.6"))
        XCTAssertFalse(shows("0.4.7"), "already seen")
        XCTAssertFalse(shows("0.4.6", text: ""), "a release with nothing to tell")
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
