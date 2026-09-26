import Foundation

/// Which languages the recogniser is asked to look for.
///
/// Pulled out of the service because the matching has a trap in it and the trap is testable.
enum RecognitionLanguages {
    /// The user's preferred languages narrowed down to what the recogniser actually supports,
    /// **matched by language code and not by the whole identifier**.
    ///
    /// `Locale.preferredLanguages` returns things like `ru-GB` — the language of one place with
    /// the region of another — while the supported list carries `ru-RU`. Compared whole, the two
    /// never meet, Russian quietly falls out, and the result reads as "it can't do Cyrillic".
    ///
    /// An empty result is meaningful: it tells the caller to let the recogniser work the language
    /// out on its own rather than handing it a list of nothing.
    static func choose(
        preferred: [Locale.Language],
        supported: [Locale.Language]
    ) -> [Locale.Language] {
        var chosen: [Locale.Language] = []

        for language in preferred {
            guard let code = language.languageCode else { continue }
            guard let match = supported.first(where: { $0.languageCode == code }) else { continue }
            guard !chosen.contains(match) else { continue }

            chosen.append(match)
        }

        return chosen
    }
}
