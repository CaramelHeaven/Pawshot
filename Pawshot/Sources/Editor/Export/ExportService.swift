import AppKit

enum ExportError: LocalizedError {
    case encodingFailed
    case desktopUnavailable(Error)

    var errorDescription: String? {
        switch self {
        case .encodingFailed:
            String(localized: "Couldn't build a PNG out of the shot.")
        case let .desktopUnavailable(underlying):
            String(localized: "Couldn't write the file to the Desktop: \(underlying.localizedDescription)")
        }
    }
}

/// Hands the finished picture to the outside world: to the clipboard or as a file on the
/// Desktop.
enum ExportService {
    static func pngData(from image: CGImage) throws -> Data {
        let representation = NSBitmapImageRep(cgImage: image)
        guard let data = representation.representation(using: .png, properties: [:]) else {
            throw ExportError.encodingFailed
        }
        return data
    }

    /// The pasteboard is a parameter with a default so tests don't clobber the owner's real
    /// clipboard.
    static func copy(_ image: CGImage, to pasteboard: NSPasteboard = .general) throws {
        let png = try pngData(from: image)

        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
        // TIFF goes right after it: some older apps can only paste that.
        pasteboard.setData(NSBitmapImageRep(cgImage: image).tiffRepresentation, forType: .tiff)
    }

    /// What ⌘D puts on the clipboard: the text read off the shot, and nothing else.
    ///
    /// `clearContents()` is the whole point of the method. ⌘C and ⌘D share one pasteboard, and an
    /// app that prefers an image — Mail, Slack — would paste the screenshot left there by an
    /// earlier ⌘C instead of the words just asked for.
    static func copy(text: String, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    @discardableResult
    static func saveToDesktop(_ image: CGImage, fileName: String = ExportNaming.fileName()) throws -> URL {
        let png = try pngData(from: image)

        do {
            let desktop = try FileManager.default.url(
                for: .desktopDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: false
            )
            let url = desktop.appendingPathComponent(fileName)
            try png.write(to: url, options: .atomic)
            return url
        } catch {
            // A TCC denial lands here too: macOS has a separate permission for the Desktop
            // folder.
            throw ExportError.desktopUnavailable(error)
        }
    }
}
