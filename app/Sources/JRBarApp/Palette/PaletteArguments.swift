import Foundation

/// Inline arguments: what a query can carry past a command's name,
/// Raycast-style — "quiet 45m", "dim for 1h30", "brightness 40". Pure
/// text in, a value or nil out, so a query that only looks like one
/// ("quiet" alone, "quiet 0", "brightness 400") never becomes a row
/// that would do something nobody typed.
enum PaletteArguments {
    /// The shortest and longest quiet a typed duration may ask for. The
    /// daemon floors a quiet at a minute; a day is past every preset
    /// and past what anyone means by a length of time to be left alone.
    static let durationRange: ClosedRange<Int> = 60...(24 * 3600)

    /// A length of time in seconds, whole minutes: "45", "45m",
    /// "45 min", "2h", "2 hours", "1.5h", "1h30", "1h 30m", "1:30",
    /// "90 minutes". A bare number is minutes; a bare number after
    /// hours is their minutes. nil for anything else, or outside
    /// `durationRange`.
    static func duration(_ text: String) -> Int? {
        let compact = text.lowercased().filter { !$0.isWhitespace }
        guard !compact.isEmpty else { return nil }
        var minutes: Double
        if compact.contains(":") {
            let parts = compact.split(separator: ":", omittingEmptySubsequences: false)
            // Bounded before the multiply: a held digit key makes an
            // hour count no Int can carry sixty of.
            guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]),
                  parts[1].count == 2, (0..<60).contains(m),
                  (0...durationRange.upperBound / 3600).contains(h) else { return nil }
            minutes = Double(h * 60 + m)
        } else {
            guard let pairs = pairs(compact) else { return nil }
            minutes = 0
            var sawHours = false
            for (index, pair) in pairs.enumerated() {
                switch pair.unit {
                case "h", "hr", "hrs", "hour", "hours":
                    guard !sawHours, index == 0 else { return nil }
                    sawHours = true
                    minutes += pair.value * 60
                case "m", "min", "mins", "minute", "minutes":
                    minutes += pair.value
                case "":
                    // Bare: the whole query ("45"), or minutes after
                    // hours ("1h30") — never a stray number elsewhere.
                    guard pairs.count == 1 || (sawHours && index == pairs.count - 1) else { return nil }
                    minutes += pair.value
                default:
                    return nil
                }
            }
            guard pairs.count <= 2 else { return nil }
        }
        // Bounded before `Int(_:)`, which traps past Int.max: this runs
        // on every keystroke, and twenty nines is a keystroke away.
        guard minutes.isFinite, minutes > 0,
              minutes.rounded() * 60 <= Double(durationRange.upperBound) else { return nil }
        let seconds = Int(minutes.rounded()) * 60
        return durationRange.contains(seconds) ? seconds : nil
    }

    /// "1h30" → [(1, "h"), (30, "")]: numbers and the letters after
    /// each. nil when the text is not strictly that shape.
    private static func pairs(_ text: String) -> [(value: Double, unit: String)]? {
        var out: [(value: Double, unit: String)] = []
        var index = text.startIndex
        while index < text.endIndex {
            var number = ""
            while index < text.endIndex, text[index].isASCII, text[index].isNumber || text[index] == "." {
                number.append(text[index])
                index = text.index(after: index)
            }
            var unit = ""
            while index < text.endIndex, text[index].isASCII, text[index].isLetter {
                unit.append(text[index])
                index = text.index(after: index)
            }
            guard let value = Double(number), value > 0 else { return nil }
            out.append((value, unit))
        }
        return out.isEmpty ? nil : out
    }

    /// The words that start a quiet, and the mode each names — nil for
    /// "whatever mode you last chose", the footer's own default.
    static let quietWords: [String: String?] = [
        "quiet": nil, "dnd": nil, "silence": nil, "hush": nil,
        "pause": "pause", "dim": "dim", "mute": "mute", "dark": "dark",
        "asks": "asks_only", "asks only": "asks_only",
    ]

    /// "quiet 45m", "dim for 2h", "asks only 1:30" → the mode (nil for
    /// the remembered one) and the seconds.
    static func quiet(_ query: String) -> (mode: String?, seconds: Int)? {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count >= 2 else { return nil }
        // The longest command phrase first: "asks only" before "asks".
        for length in [2, 1] where words.count > length {
            let phrase = words.prefix(length).joined(separator: " ")
            guard let mode = quietWords[phrase] else { continue }
            var rest = Array(words.dropFirst(length))
            if rest.first == "for" { rest.removeFirst() }
            guard !rest.isEmpty, let seconds = duration(rest.joined(separator: " ")) else { return nil }
            return (mode, seconds)
        }
        return nil
    }

    /// The phrases that start a Keep Awake session.
    static let awakeWords: Set<String> = ["awake", "keep awake", "stay awake", "caffeinate", "no sleep", "coffee"]

    /// How long a typed Keep Awake asks for, and how it was asked.
    struct Awake: Equatable {
        var seconds: Int
        /// The clock time named ("until 6pm"), nil for a length ("45m").
        var until: Date?
    }

    /// "awake 45m", "keep awake for 2h", "caffeinate 1:30" → a length;
    /// "awake until 6pm", "awake till 18:30", "awake until noon" → the
    /// time from `now` to the next time the clock reads that. nil for
    /// "awake" alone, for a length outside `durationRange`, and for a time
    /// less than a minute or more than a day away.
    static func awake(_ query: String, now: Date, calendar: Calendar = .current) -> Awake? {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        for length in [2, 1] where words.count > length {
            guard awakeWords.contains(words.prefix(length).joined(separator: " ")) else { continue }
            var rest = Array(words.dropFirst(length))
            if rest.first == "until" || rest.first == "till" || rest.first == "til" {
                rest.removeFirst()
                guard !rest.isEmpty, let at = clock(rest.joined(), now: now, calendar: calendar) else { return nil }
                let seconds = Int(at.timeIntervalSince(now).rounded(.down))
                return durationRange.contains(seconds) ? Awake(seconds: seconds, until: at) : nil
            }
            if rest.first == "for" { rest.removeFirst() }
            guard !rest.isEmpty, let seconds = duration(rest.joined(separator: " ")) else { return nil }
            return Awake(seconds: seconds, until: nil)
        }
        return nil
    }

    /// The next time the clock reads `text` after `now`: "6pm", "6:30pm",
    /// "18:30", "6:30", "noon", "midnight". A bare hour with no am or pm
    /// ("6", "6:30") is whichever of the two comes next. nil for anything
    /// that is not a time of day.
    static func clock(_ text: String, now: Date, calendar: Calendar = .current) -> Date? {
        var compact = text.lowercased().filter { !$0.isWhitespace && $0 != "." }
        guard !compact.isEmpty else { return nil }
        var hours: [Int]
        var minute = 0
        if compact == "noon" {
            hours = [12]
        } else if compact == "midnight" {
            hours = [0]
        } else {
            var meridiem: String?
            for suffix in ["am", "pm", "a", "p"] where compact.hasSuffix(suffix) {
                meridiem = String(suffix.prefix(1))
                compact.removeLast(suffix.count)
                break
            }
            let parts = compact.split(separator: ":", omittingEmptySubsequences: false)
            guard (1...2).contains(parts.count), let hour = Int(parts[0]),
                  parts[0].count <= 2, parts[0].allSatisfy(\.isNumber) else { return nil }
            if parts.count == 2 {
                guard parts[1].count == 2, let m = Int(parts[1]), (0..<60).contains(m) else { return nil }
                minute = m
            }
            switch meridiem {
            case "a"?:
                guard (1...12).contains(hour) else { return nil }
                hours = [hour % 12]
            case "p"?:
                guard (1...12).contains(hour) else { return nil }
                hours = [hour % 12 + 12]
            default:
                guard (0...23).contains(hour) else { return nil }
                // "18:30" is itself; "6:30" is the morning or the evening, whichever is next.
                hours = hour >= 13 || hour == 0 ? [hour] : (hour == 12 ? [12] : [hour, hour + 12])
            }
        }
        let candidates = hours.compactMap { hour in
            calendar.nextDate(after: now, matching: DateComponents(hour: hour, minute: minute, second: 0),
                              matchingPolicy: .nextTime)
        }
        return candidates.min()
    }

    /// "brightness 40", "led 40%", "leds to 75" → 0.4, 0.4, 0.75. Whole
    /// percents 0–100 only; the panel's slider covers the same range.
    static func brightness(_ query: String) -> Double? {
        var words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard let first = words.first, ["brightness", "led", "leds"].contains(first) else { return nil }
        words.removeFirst()
        if words.first == "brightness" { words.removeFirst() }
        if words.first == "to" { words.removeFirst() }
        guard words.count == 1 else { return nil }
        var number = words[0]
        if number.hasSuffix("%") { number.removeLast() }
        guard let percent = Int(number), (0...100).contains(percent) else { return nil }
        return Double(percent) / 100
    }

    /// "45 Minutes", "1 Hour", "1 Hour 30 Minutes" — a duration in the
    /// quiet presets' own words.
    static func durationLabel(_ seconds: Int) -> String {
        let minutes = seconds / 60
        let hours = minutes / 60
        let rest = minutes % 60
        func unit(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
        switch (hours, rest) {
        case (0, _): return unit(rest, "minute")
        case (_, 0): return unit(hours, "hour")
        default: return "\(unit(hours, "hour")) \(unit(rest, "minute"))"
        }
    }
}
