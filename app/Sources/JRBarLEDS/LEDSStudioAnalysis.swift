import Foundation

/// What the LEDS Studio editor knows about the text in it: whether the
/// firmware on each device would parse it (with the firmware's own error
/// at its line and column), how much of the 512-byte / 20-line budget it
/// spends, and what the presentation compiler changes before anything
/// plays it. Pure — the editor recomputes it on every keystroke.
///
/// The verdicts come from `LEDSParser`, the port probed against
/// `sdled.wasm`, so a program the editor calls clean is one the device
/// will play instead of blinking red six times.
public struct LEDSStudioAnalysis: Equatable, Sendable {
    /// One device shape's verdict.
    public struct Verdict: Equatable, Sendable {
        public let ledCount: Int
        /// nil when the firmware parses the text.
        public let error: LEDSParseError?
        /// Lines that only name LEDs this device does not have — parsed,
        /// then skipped without taking any time (1-based line numbers).
        public let ignoredLines: [Int]

        public var accepted: Bool { error == nil }
    }

    /// The whole program as the compiler will play it on the strip.
    public struct Compiled: Equatable, Sendable {
        /// The text the strip, the Dot and the Screen Bar would be sent.
        public let program: String
        /// False when the compiler refused and would play `off` instead.
        public let accepted: Bool
        /// True when the safe text differs from what was written.
        public let transformed: Bool
        /// The compiler's reasons (`phase_cadence_clamped`, …).
        public let reasons: [String]
    }

    public let text: String
    /// UTF-8 bytes — the firmware's measure, not characters.
    public let bytes: Int
    /// Physical lines as the firmware counts them: `\r\n`, `\n` and `\r`
    /// all break, and one trailing break does not start a new line.
    public let lines: Int
    public let strip: Verdict
    public let dot: Verdict
    public let compiled: Compiled

    public init(_ text: String) {
        self.text = text
        bytes = text.utf8.count
        lines = text.isEmpty ? 0 : LEDSParser.splitLines(text).count
        strip = Self.verdict(text, ledCount: 8)
        dot = Self.verdict(text, ledCount: 2)
        let result = LEDSPresentationCompiler.compile(text, ledCount: 8)
        compiled = Compiled(program: result.program, accepted: result.accepted,
                            transformed: result.transformed, reasons: result.reasons)
    }

    /// Share of the byte budget spent, 0…1+ (over 1 is over the limit).
    public var byteFraction: Double { Double(bytes) / Double(LEDSLimits.maxProgramBytes) }
    /// Share of the line budget spent, 0…1+.
    public var lineFraction: Double { Double(lines) / Double(LEDSLimits.maxProgramLines) }
    /// Whether the text is empty or only blank space — nothing to play.
    public var isBlank: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Ready to play or burn: the strip's firmware parses it and the
    /// compiler has a safe version of it.
    public var playable: Bool { !isBlank && strip.accepted && compiled.accepted }

    /// The first failure worth showing: the strip's, else the Dot's.
    public var firstError: LEDSParseError? { strip.error ?? dot.error }

    /// The compiler's changes as one plain sentence, or nil when it plays
    /// the text as written.
    public var compilerNote: String? {
        guard compiled.accepted else {
            return "The presentation compiler refuses this program (it could not be slowed to 2 Hz inside the firmware's limits), so nothing would play."
        }
        guard compiled.transformed, !compiled.reasons.isEmpty else { return nil }
        var parts: [String] = []
        if compiled.reasons.contains("phase_cadence_clamped") {
            parts.append("steps inside the loop get at least 250 ms (500 ms for saturated red)")
        }
        if compiled.reasons.contains("roll_cadence_clamped") {
            parts.append("rolls take at least 250 ms")
        }
        if compiled.reasons.contains("loop_cadence_clamped") {
            parts.append("the loop is stretched to at least 500 ms (1 s with saturated red)")
        }
        guard !parts.isEmpty else { return "The presentation compiler adjusts the timing before it plays." }
        return "Slowed to stay under 2 Hz: " + parts.joined(separator: "; ") + "."
    }

    static func verdict(_ text: String, ledCount: Int) -> Verdict {
        do {
            let program = try LEDSProgram.parse(text, ledCount: ledCount)
            return Verdict(ledCount: ledCount, error: nil, ignoredLines: ignoredLines(program, text: text))
        } catch {
            return Verdict(ledCount: ledCount, error: error, ignoredLines: [])
        }
    }

    /// Painting lines whose every assignment names an LED past the
    /// device's count — the firmware parses and skips them.
    static func ignoredLines(_ program: LEDSProgram, text: String) -> [Int] {
        var ignored: [Int] = []
        for (offset, line) in LEDSParser.splitLines(text).enumerated() {
            guard let parsed = try? LEDSParser.parseLine(line, lineNumber: offset + 1, ledCount: program.ledCount),
                  case .paint(let segments) = parsed.step else { continue }
            let onlyIgnored = segments.allSatisfy { segment in
                if case .indexed(let assignments) = segment.kind {
                    return assignments.allSatisfy { $0.index >= program.ledCount }
                }
                return false
            }
            if onlyIgnored { ignored.append(offset + 1) }
        }
        return ignored
    }
}

extension LEDSParseError.Kind {
    /// What went wrong, in the editor's words — the firmware's name for
    /// it is shown beside this, so the two can be matched to the spec.
    public var explanation: String {
        switch self {
        case .nullInput:
            return "The firmware received nothing to parse."
        case .tooLong:
            return "Over 512 bytes. The firmware refuses the whole program before reading a line."
        case .tooManyLines:
            return "More than 20 lines. Blank lines and comments count too."
        case .tooManyAnimationLines:
            return "Too many animation lines for the firmware's step table."
        case .syntax:
            return "A line starts with a colour (#RRGGBB), off, an index (3:#RRGGBB), brightness, roll or repeat."
        case .badColor:
            return "Colours are # and six hex digits, like #FF00FF. A # alone or before a space starts a comment."
        case .badIndex:
            return "An index takes a six-digit colour — 3:#FF00FF. Use 3:#000000 to turn one LED off."
        case .badTime:
            return "Timing is a duration (330ms, 2s, 0.33s — at most 65535 ms), then an easing, then a delay. A colour list and index:colour pairs cannot share a segment, and a roll owns its line."
        case .badBrightness:
            return "brightness takes a whole number from 0 to 255."
        case .badRepeat:
            return "repeat needs a lighting line before it, may appear once, and counts from 1 to 65535."
        case .trailingInput:
            return "Something extra follows a complete instruction on this line."
        }
    }
}
