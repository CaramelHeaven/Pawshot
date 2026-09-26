import CoreGraphics
import Foundation
import Vision

enum TextRecognitionError: LocalizedError {
    case renderFailed
    case recognitionFailed(Error)

    var errorDescription: String? {
        switch self {
        case .renderFailed:
            "Couldn't build a picture of the shot to read."
        case let .recognitionFailed(underlying):
            "Couldn't read the text: \(underlying.localizedDescription)"
        }
    }
}

/// The only place that knows about the Vision framework.
///
/// VisionKit's `ImageAnalyzer` was tried first and dropped: its `transcript` scans the shot line by
/// line across the full width, so two columns come back interleaved, neighbouring lines get glued
/// together and every indent is stripped. Vision hands over one observation per line, already
/// grouped by column, and its boxes are what `TextLayout` rebuilds the shape from.
enum TextRecognitionService {
    /// Reads the shot. An empty string is a legitimate answer — a screenshot of a photo has no
    /// text in it — and what to do about that belongs to the caller.
    static func text(for image: CGImage) async throws -> String {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        // Off on purpose. With the correction on, the recogniser "helpfully" turns
        // `dropTarget(from` into `dropTarget (from`, and code is exactly what suffers most.
        request.usesLanguageCorrection = false

        let languages = RecognitionLanguages.choose(
            preferred: Locale.preferredLanguages.map { Locale.Language(identifier: $0) },
            supported: request.supportedRecognitionLanguages
        )
        if languages.isEmpty {
            request.automaticallyDetectsLanguage = true
        } else {
            request.recognitionLanguages = languages
        }

        let observations: [RecognizedTextObservation]
        do {
            observations = try await request.perform(on: image, orientation: .up)
        } catch {
            throw TextRecognitionError.recognitionFailed(error)
        }

        return TextLayout.assemble(lines(from: observations, imagePixelSize: image.pixelSize))
    }

    /// Vision reports boxes in normalized coordinates; `TextLayout` wants pixels, because there X
    /// and Y are scaled by different numbers on any shot that isn't square.
    private static func lines(
        from observations: [RecognizedTextObservation],
        imagePixelSize size: CGSize
    ) -> [TextLayout.Line] {
        observations.compactMap { observation in
            guard let best = observation.topCandidates(1).first else { return nil }

            let box = observation.boundingBox.cgRect
            return TextLayout.Line(
                text: best.string,
                box: CGRect(
                    x: box.minX * size.width,
                    y: box.minY * size.height,
                    width: box.width * size.width,
                    height: box.height * size.height
                )
            )
        }
    }
}

private extension CGImage {
    var pixelSize: CGSize {
        CGSize(width: width, height: height)
    }
}
