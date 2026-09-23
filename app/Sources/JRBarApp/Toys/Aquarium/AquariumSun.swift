import Foundation
import JRBarCore

/// The tank's real sun (docs/TOYS.md): sunrise and sunset worked out on
/// this Mac, for the city the time zone is named after. The tz
/// database's own `zone.tab` carries every zone's principal city as a
/// coordinate, so there is no location permission, no network and no
/// third-party lookup — only the time zone the Mac already knows. A
/// zone the table doesn't list (an alias, plain UTC) has no sun, and the
/// tank falls back to the fixed hours.
enum AquariumSun {
    /// A place on the globe: degrees, north and east positive.
    struct Coordinate: Equatable, Sendable {
        var latitude: Double
        var longitude: Double
    }

    /// One day's sun. `nil` times are the poles' days: `alwaysDark` is a
    /// polar night, otherwise a midnight sun.
    struct Day: Equatable, Sendable {
        var sunrise: Date?
        var sunset: Date?
        var alwaysDark = false
    }

    // MARK: zone.tab

    /// The table's path on macOS.
    static let zoneTabPath = "/usr/share/zoneinfo/zone.tab"

    /// zone.tab's rows: `CC<tab>±DDMM[SS]±DDDMM[SS]<tab>Zone/Name[<tab>…]`,
    /// `#` comments. Rows that don't parse are skipped, never fatal.
    static func parseZoneTab(_ text: String) -> [String: Coordinate] {
        var table: [String: Coordinate] = [:]
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 3, let coordinate = parseISO6709(String(fields[1])) else { continue }
            table[String(fields[2])] = coordinate
        }
        return table
    }

    /// `+415100-0873900` → 41.85, -87.65. Latitude is `±DDMM` or
    /// `±DDMMSS`, longitude `±DDDMM` or `±DDDMMSS`.
    static func parseISO6709(_ text: String) -> Coordinate? {
        let chars = Array(text)
        guard let split = chars.indices.dropFirst().first(where: { chars[$0] == "+" || chars[$0] == "-" })
        else { return nil }
        guard let lat = angle(String(chars[..<split]), degreeDigits: 2),
              let lon = angle(String(chars[split...]), degreeDigits: 3),
              abs(lat) <= 90, abs(lon) <= 180
        else { return nil }
        return Coordinate(latitude: lat, longitude: lon)
    }

    private static func angle(_ text: String, degreeDigits: Int) -> Double? {
        guard let sign = text.first, sign == "+" || sign == "-" else { return nil }
        let digits = text.dropFirst()
        guard digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber),
              digits.count == degreeDigits + 2 || digits.count == degreeDigits + 4
        else { return nil }
        let d = Double(digits.prefix(degreeDigits))!
        let m = Double(digits.dropFirst(degreeDigits).prefix(2))!
        let s = digits.count > degreeDigits + 2 ? Double(digits.suffix(2))! : 0
        guard m < 60, s < 60 else { return nil }
        let value = d + m / 60 + s / 3600
        return sign == "-" ? -value : value
    }

    /// The table, read once. A missing file is an empty table — the tank
    /// just keeps the fixed hours.
    static let zoneTable: [String: Coordinate] = {
        guard let text = try? String(contentsOfFile: zoneTabPath, encoding: .utf8) else { return [:] }
        return parseZoneTab(text)
    }()

    /// Where the Mac's time zone is named after, or nil.
    static func coordinate(for zone: TimeZone, table: [String: Coordinate] = zoneTable) -> Coordinate? {
        table[zone.identifier]
    }

    // MARK: Sunrise & sunset

    /// NOAA's general solar position equations (the fractional-year
    /// series, good to a minute or two — far finer than a tank needs),
    /// with the usual 90.833° zenith for refraction and the sun's disc.
    /// The day is `date`'s calendar day in `zone`; the answers are
    /// absolute instants, so a sunset past UTC midnight lands right.
    static func day(on date: Date, at place: Coordinate, zone: TimeZone) -> Day {
        var local = Calendar(identifier: .gregorian)
        local.timeZone = zone
        let parts = local.dateComponents([.year, .month, .day], from: date)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        guard let midnight = utc.date(from: parts),
              let dayOfYear = utc.ordinality(of: .day, in: .year, for: midnight)
        else { return Day() }
        let gamma = 2 * Double.pi / 365 * (Double(dayOfYear) - 1)
        let eqTime = 229.18 * (0.000075 + 0.001868 * cos(gamma) - 0.032077 * sin(gamma)
            - 0.014615 * cos(2 * gamma) - 0.040849 * sin(2 * gamma))
        let decl = 0.006918 - 0.399912 * cos(gamma) + 0.070257 * sin(gamma)
            - 0.006758 * cos(2 * gamma) + 0.000907 * sin(2 * gamma)
            - 0.002697 * cos(3 * gamma) + 0.00148 * sin(3 * gamma)
        let lat = place.latitude * .pi / 180
        let cosHA = cos(90.833 * .pi / 180) / (cos(lat) * cos(decl)) - tan(lat) * tan(decl)
        if cosHA > 1 { return Day(alwaysDark: true) }
        if cosHA < -1 { return Day() }
        let ha = acos(cosHA) * 180 / .pi
        let rise = 720 - 4 * (place.longitude + ha) - eqTime
        let set = 720 - 4 * (place.longitude - ha) - eqTime
        return Day(sunrise: midnight.addingTimeInterval(rise * 60),
                   sunset: midnight.addingTimeInterval(set * 60))
    }

    /// The tank's night factor under a real sun (0 bright … 1 deepest):
    /// dawn blends down across the hour either side of sunrise and dusk
    /// blends up across the hour either side of sunset — the same
    /// two-hour smoothsteps the fixed hours use, so a 7:00 sunrise and a
    /// 20:00 sunset read exactly like "Follow the clock". A short winter
    /// day whose blends overlap never snaps: the darker of the two wins.
    static func night(at date: Date, day: Day) -> Double {
        if day.alwaysDark { return 1 }
        guard let sunrise = day.sunrise, let sunset = day.sunset else { return 0 }
        func smooth(_ x: Double) -> Double {
            let p = min(1, max(0, x))
            return p * p * (3 - 2 * p)
        }
        let dawn = 1 - smooth((date.timeIntervalSince(sunrise) + 3600) / 7200)
        let dusk = smooth((date.timeIntervalSince(sunset) + 3600) / 7200)
        return max(dawn, dusk)
    }

    // MARK: The tank's reading

    /// The night factor for `date` where this Mac's clock says it is, or
    /// nil when the zone has no city in the table. One day's sun is
    /// worked out once and kept: the fish ask every frame.
    @MainActor
    static func night(at date: Date, zone: TimeZone = .current) -> Double? {
        guard let place = coordinate(for: zone) else { return nil }
        var local = Calendar(identifier: .gregorian)
        local.timeZone = zone
        let key = "\(zone.identifier) \(local.startOfDay(for: date).timeIntervalSince1970)"
        if memo?.key != key {
            memo = (key, day(on: date, at: place, zone: zone))
        }
        return night(at: date, day: memo!.day)
    }

    @MainActor private static var memo: (key: String, day: Day)?
}
