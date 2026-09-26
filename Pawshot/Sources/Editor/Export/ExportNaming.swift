import Foundation

/// The file name for a saved shot or recording: date, time and a UUID tail. The date and the UUID
/// arrive as parameters so the function can be covered by a test.
enum ExportNaming {
    static func fileName(
        date: Date = Date(),
        uuid: UUID = UUID(),
        timeZone: TimeZone = .current,
        extension fileExtension: String = "png"
    ) -> String {
        let formatter = DateFormatter()
        // The POSIX locale is mandatory: otherwise the format drifts with the system language,
        // and in some calendars even the year changes.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"

        let stamp = formatter.string(from: date)
        let tail = uuid.uuidString
            .replacingOccurrences(of: "-", with: "")
            .prefix(6)
            .lowercased()

        return "pawshot-\(stamp)-\(tail).\(fileExtension)"
    }
}
