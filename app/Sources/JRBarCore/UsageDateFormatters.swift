import Foundation
import Synchronization

/// Reuses formatter setup without caching a clock's changing text.
final class UsageDateFormatters: Sendable {
    enum Format: Hashable, Sendable {
        case template(String)
        case shortTime
    }

    private struct Key: Hashable {
        let locale: Locale
        let timeZone: TimeZone
        let calendar: Calendar?
        let format: Format
    }

    static let shared = UsageDateFormatters()
    static let capacity = 16
    private let entries = Mutex<[Key: DateFormatter]>([:])

    func withFormatter<T>(locale: Locale, timeZone: TimeZone, calendar: Calendar? = nil,
                          format: Format, _ read: (DateFormatter) -> T) -> T {
        // Store snapshots as keys so a preferences change cannot mutate a key.
        let locale = locale == .autoupdatingCurrent ? Locale.current : locale
        let timeZone = timeZone == .autoupdatingCurrent ? TimeZone.current : timeZone
        let calendar = calendar.map { $0 == .autoupdatingCurrent ? Calendar.current : $0 }
        let key = Key(locale: locale, timeZone: timeZone, calendar: calendar, format: format)
        return entries.withLock { entries in
            if let formatter = entries[key] { return read(formatter) }
            if entries.count >= Self.capacity { entries.removeAll(keepingCapacity: true) }
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.timeZone = timeZone
            if let calendar { formatter.calendar = calendar }
            switch format {
            case .template(let template): formatter.setLocalizedDateFormatFromTemplate(template)
            case .shortTime:
                formatter.dateStyle = .none
                formatter.timeStyle = .short
            }
            entries[key] = formatter
            return read(formatter)
        }
    }
}
