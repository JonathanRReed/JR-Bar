import Foundation

/// Foundation-only wording shared by daemon facts and every app view.
public enum UsageNumber {
    public static func percent(_ used: Double?, showUnit: Bool = true) -> String {
        guard let used else { return "—" }
        let number = String(UsageWindowLabel.wholeUsed(used))
        return number + (showUnit ? "%" : "")
    }

    public static func rate(_ value: Double, approximate: Bool = false) -> String {
        guard value.isFinite, value >= 0 else { return "—" }
        let number = String(format: value >= 10 ? "%.0f" : "%.1f", value)
        return (approximate ? "≈ " : "") + number + "%/h"
    }

    /// A budget rounds down so its displayed limit never promises extra quota.
    public static func rateLimit(_ value: Double) -> String {
        guard value.isFinite, value > 0 else { return "≤ 0.0%/h" }
        var places = value >= 10 ? 0 : 1
        var scale = pow(10.0, Double(places))
        while value * scale < 1, places < 6 { places += 1; scale *= 10 }
        return String(format: "≤ %.*f%%/h", places, floor(value * scale) / scale)
    }
}

public enum UsageTime {
    public static func settingMinutes(_ value: Double) -> String {
        "\(Int(saturating: value.rounded())) min" // jrbar-token-exception: a setting value keeps the SI space
    }

    public static func spokenMinutes(_ value: Int) -> String {
        value == 1 ? "1 minute" : "\(value) minutes"
    }

    /// The calendar heads-up is part of the frozen notch copy.
    public static func notchCalendarCountdown(to start: Double, now: Date) -> String {
        let seconds = start - now.timeIntervalSince1970
        guard seconds > 30 else { return "now" }
        return "in \(Int(saturating: ceil(seconds / 60))) min" // jrbar-token-exception: frozen notch calendar copy
    }

    public static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "unknown" }
        let whole = Int(saturating: max(0, seconds))
        if whole < 60 { return "\(whole)s" }
        let minutes = whole / 60
        if minutes < 60 {
            let rest = whole % 60
            return rest == 0 ? "\(minutes)m" : "\(minutes)m \(rest)s"
        }
        let hours = minutes / 60
        if hours < 24 { return String(format: "%dh %02dm", hours, minutes % 60) }
        return "\(hours / 24)d \(hours % 24)h"
    }

    public static func ago(_ seconds: Double) -> String {
        seconds < 30 ? "now" : "\(duration(seconds)) ago"
    }

    public static func relative(to epoch: Double, now: Date) -> String {
        let seconds = epoch - now.timeIntervalSince1970
        return seconds < 30 ? "now" : "in \(duration(seconds))"
    }

    /// The notch rounds reset countdowns to minutes and keeps the legacy text.
    public static func countdown(to epoch: Double, now: Date) -> String {
        let seconds = Int(saturating: epoch - now.timeIntervalSince1970)
        if seconds < 1 { return "reset — waiting for a new reading" }
        let minutes = max(1, (seconds + 30) / 60)
        return "resets in \(duration(Double(minutes) * 60))"
    }

    public static func clock(_ epoch: Double, locale: Locale = .autoupdatingCurrent,
                             timeZone: TimeZone = .current) -> String {
        guard epoch.isFinite else { return "" }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate("jm")
        return formatter.string(from: Date(timeIntervalSince1970: epoch))
    }

    public static func clock(minutes: Int, now: Date = Date(), calendar: Calendar = .current,
                             locale: Locale = .autoupdatingCurrent) -> String {
        let normalized = ((minutes % 1440) + 1440) % 1440
        let date = calendar.date(bySettingHour: normalized / 60, minute: normalized % 60, second: 0, of: now) ?? now
        return clock(date.timeIntervalSince1970, locale: locale, timeZone: calendar.timeZone)
    }

    public static func resetLine(_ epoch: Double?, now: Double, locale: Locale = .autoupdatingCurrent,
                                 timeZone: TimeZone = .current, fix: String? = nil) -> String {
        guard let epoch, epoch.isFinite, now.isFinite else { return "Waiting for a new reading" }
        let remaining = epoch - now
        if remaining < 1, let fix, !fix.isEmpty { return fix }
        if remaining <= 0 { return remaining > -30 ? "Reset now" : "Reset \(ago(-remaining))" }
        if remaining < 3600 { return relative(to: epoch, now: Date(timeIntervalSince1970: now)) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let date = Date(timeIntervalSince1970: epoch)
        if calendar.isDate(date, inSameDayAs: Date(timeIntervalSince1970: now)) {
            return clock(epoch, locale: locale, timeZone: timeZone)
        }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate(remaining < 7 * 86400 ? "EEEjm" : "MMM d jm")
        return formatter.string(from: date)
    }

    public static func runsOut(at epoch: Double, now: Double, locale: Locale = .autoupdatingCurrent,
                               timeZone: TimeZone = .current) -> String {
        "\(UsageStatus.runsOut.word) \(runOutWhen(at: epoch, now: now, locale: locale, timeZone: timeZone))"
    }

    public static func runOutWhen(at epoch: Double, now: Double, locale: Locale = .autoupdatingCurrent,
                                 timeZone: TimeZone = .current) -> String {
        if epoch - now < 3600 {
            let minutes = max(1, Int(saturating: ceil(max(0, epoch - now) / 60)))
            return "in \(duration(Double(minutes) * 60))"
        }
        return clock(epoch, locale: locale, timeZone: timeZone)
    }

    public static func spokenAge(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "a while" }
        if seconds < 60 { return "under a minute" }
        let minutes = Int(saturating: seconds / 60)
        if minutes < 60 { return spokenMinutes(minutes) }
        let hours = Int(saturating: seconds / 3600)
        if hours < 48 { return hours == 1 ? "1 hour" : "\(hours) hours" }
        return "\(Int(saturating: seconds / 86400)) days"
    }
}

public enum UsageFormat {
    /// 1234 → "1.2k", 4_560_000 → "4.6M".
    public static func tokens(_ count: Int) -> String {
        let value = Double(count)
        // Each tier starts where the one below would round up to 1000, so
        // 999_999 reads "1.0M" and never "1000k", and 9_999 reads "10k".
        if value >= 999_500_000 { return String(format: "%.1fB", value / 1_000_000_000) }
        if value >= 999_500 { return String(format: value >= 9_950_000 ? "%.0fM" : "%.1fM", value / 1_000_000) }
        if value >= 1_000 { return String(format: value >= 9_950 ? "%.0fk" : "%.1fk", value / 1_000) }
        return "\(count)"
    }

    public static func cost(_ usd: Double, currency: String = "USD") -> String {
        let symbol = currencySymbol(currency)
        if usd < 0.01, usd > 0 { return "<\(symbol)0.01" }
        // Past a thousand the cents are noise and the digits run together:
        // "$253,305" reads, "$253305" does not.
        if usd >= 999.995 { return symbol + grouped(usd.rounded()) }
        return String(format: "%@%.2f", symbol, usd)
    }

    private static func currencySymbol(_ currency: String) -> String {
        switch currency {
        case "USD": "$"
        case "EUR": "€"
        case "GBP": "£"
        default: currency + " "
        }
    }

    public static func price(perMillion value: Double?, currency: String = "USD") -> String {
        guard let value, value.isFinite, value >= 0 else { return "No price" }
        return cost(value, currency: currency)
    }

    /// 253305 → "253,305", in the reader's own locale.
    static let groupingFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    public static func grouped(_ value: Double) -> String {
        groupingFormatter.string(from: NSNumber(value: value)) ?? String(format: "%.0f", value)
    }
}
