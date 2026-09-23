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
        case (0, _): return unit(rest, "Minute")
        case (_, 0): return unit(hours, "Hour")
        default: return "\(unit(hours, "Hour")) \(unit(rest, "Minute"))"
        }
    }
}
