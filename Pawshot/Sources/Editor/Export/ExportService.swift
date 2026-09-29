import AppKit
import ImageIO
import os
import UniformTypeIdentifiers

enum ExportError: LocalizedError {
    case encodingFailed
    case folderUnavailable(URL, Error)

    var errorDescription: String? {
        switch self {
        case .encodingFailed:
            String(localized: "Couldn't build an image file out of the shot.")
        case let .folderUnavailable(folder, underlying):
            String(localized: "Couldn't write the file to “\(FileManager.default.displayName(atPath: folder.path))”: \(underlying.localizedDescription)")
        }
    }
}

/// Hands the finished picture to the outside world: to the clipboard or as a file in the folder
/// Settings name.
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
        if !pasteboard.setData(png, forType: .png) {
            logger.error("clipboard write failed: PNG")
        }
        // TIFF goes right after it: some older apps can only paste that.
        let tiff = NSBitmapImageRep(cgImage: image).tiffRepresentation
        let tiffWritten = pasteboard.setData(tiff, forType: .tiff)
        if tiff == nil {
            logger.error("clipboard write failed: no TIFF representation")
        } else if !tiffWritten {
            logger.error("clipboard write failed: TIFF")
        }
    }

    /// What ⌘D puts on the clipboard: the text read off the shot, and nothing else.
    ///
    /// `clearContents()` is the whole point of the method. ⌘C and ⌘D share one pasteboard, and an
    /// app that prefers an image — Mail, Slack — would paste the screenshot left there by an
    /// earlier ⌘C instead of the words just asked for.
    static func copy(text: String, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        if !pasteboard.setString(text, forType: .string) {
            logger.error("clipboard write failed: text, \(text.count) chars")
        }
    }

    private static var logger: Logger {
        .pawshot("editor")
    }

    /// The shot as a file of `format`. JPEG and HEIC at 0.9: screenshot text stays crisp, and the
    /// file is still a fraction of a PNG's.
    static func data(from image: CGImage, format: ImageFormat) throws -> Data {
        if format == .png {
            return try pngData(from: image)
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, format.type.identifier as CFString, 1, nil) else {
            throw ExportError.encodingFailed
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ExportError.encodingFailed
        }
        return data as Data
    }

    /// ⌘S: a new file named by the date in `folder`.
    @discardableResult
    static func save(_ image: CGImage, to folder: URL, format: ImageFormat) throws -> URL {
        try write(image, to: folder.appendingPathComponent(ExportNaming.fileName(extension: format.fileExtension)), format: format)
    }

    /// Save As…: exactly this file.
    @discardableResult
    static func write(_ image: CGImage, to url: URL, format: ImageFormat) throws -> URL {
        let data = try data(from: image, format: format)
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            // A TCC denial lands here too: macOS guards the Desktop, Documents and Downloads with
            // a permission of their own.
            throw ExportError.folderUnavailable(url.deletingLastPathComponent(), error)
        }
    }
}
