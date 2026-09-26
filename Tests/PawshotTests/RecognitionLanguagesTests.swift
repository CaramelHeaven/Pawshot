@testable import Pawshot
import XCTest

final class RecognitionLanguagesTests: XCTestCase {
    private func languages(_ identifiers: [String]) -> [Locale.Language] {
        identifiers.map { Locale.Language(identifier: $0) }
    }

    /// The reason this function exists at all. On the owner's machine `Locale.preferredLanguages`
    /// hands back `["en-US", "ru-GB"]` — Russian with a British region — and Vision's supported
    /// list carries `ru-RU`. Compared whole, the two never meet and Russian drops out in silence,
    /// which looks like "the OCR just can't read Cyrillic".
    func testRegionMismatchStillMatchesTheLanguage() {
        let chosen = RecognitionLanguages.choose(
            preferred: languages(["en-US", "ru-GB"]),
            supported: languages(["en-US", "fr-FR", "ru-RU"])
        )

        XCTAssertEqual(chosen, languages(["en-US", "ru-RU"]))
    }

    /// The order is the user's, not Vision's: what they read most comes first.
    func testPreferredOrderIsKept() {
        let chosen = RecognitionLanguages.choose(
            preferred: languages(["ru-RU", "en-US"]),
            supported: languages(["en-US", "ru-RU"])
        )

        XCTAssertEqual(chosen, languages(["ru-RU", "en-US"]))
    }

    /// Two regions of one language must not ask Vision to recognise it twice.
    func testTheSameLanguageTwiceCollapses() {
        let chosen = RecognitionLanguages.choose(
            preferred: languages(["en-US", "en-GB"]),
            supported: languages(["en-US"])
        )

        XCTAssertEqual(chosen, languages(["en-US"]))
    }

    /// An empty result is the caller's signal to let Vision detect the language itself.
    func testNothingInCommonGivesNothing() {
        let chosen = RecognitionLanguages.choose(
            preferred: languages(["ja-JP"]),
            supported: languages(["en-US", "ru-RU"])
        )

        XCTAssertTrue(chosen.isEmpty)
    }
}
