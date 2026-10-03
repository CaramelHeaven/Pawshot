import CoreGraphics
import Foundation
import os
import Vision

enum TextRecognitionError: LocalizedError {
    case renderFailed
    case recognitionFailed(Error)

    var errorDescription: String? {
        switch self {
        case .renderFailed:
            String(localized: "Couldn't build a picture of the shot to read.")
        case let .recognitionFailed(underlying):
            String(localized: "Couldn't read the text: \(underlying.localizedDescription)")
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
    /// Reads the shot: what its QR codes and barcodes hold, then its text
    /// (`TextLayout.clipboardText`). An empty string is a legitimate answer — a screenshot of a
    /// photo has no text in it — and what to do about that belongs to the caller.
    static func text(for image: CGImage) async throws -> String {
        async let codes = codes(in: image)
        let text = try await lines(in: image)
        return try await TextLayout.clipboardText(codes: codes, text: text)
    }

    /// The payloads of every code Vision finds, in its order. The same request family as the
    /// text, so it runs in the same few milliseconds.
    static func codes(in image: CGImage) async throws -> [String] {
        let request = DetectBarcodesRequest()
        let started = ContinuousClock.now
        do {
            let payloads = try await request.perform(on: image, orientation: .up).compactMap(\.payloadString)
            let took = started.duration(to: .now).milliseconds
            logger.notice("\(payloads.count) codes in \(took, privacy: .public) ms")
            return payloads
        } catch {
            throw TextRecognitionError.recognitionFailed(error)
        }
    }

    private static var logger: Logger {
        .pawshot("text")
    }

    private static func lines(in image: CGImage) async throws -> String {
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
        let started = ContinuousClock.now
        do {
            observations = try await request.perform(on: image, orientation: .up)
            let took = started.duration(to: .now).milliseconds
            logger.notice("recognised \(observations.count) lines in \(took, privacy: .public) ms")
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

private extension Duration {
    var milliseconds: Int {
        Int(components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000)
    }
}
