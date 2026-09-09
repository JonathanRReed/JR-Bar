import Foundation

/// The LEDS.LED grammar as the firmware actually parses it.
///
/// Every rule here was probed against the packaged `sdled.wasm` (see
/// `app/scripts/gen_leds_fixtures.py`, which records the firmware's verdicts
/// in `Fixtures/parse_verdicts.json`). Where LEDS_FORMAT.md and the parser
/// disagreed, the parser won:
///
/// * keywords, easing names and time suffixes are case-insensitive;
/// * `#` alone or `#` followed by a space/tab is a comment, `#c` is `bad-color`;
/// * `;` is a comment only as the first non-blank character; elsewhere it
///   separates segments, and empty segments are ignored;
/// * a decimal time keeps its first three fraction digits and drops the rest
///   (`0.3333s` is 333 ms), needs a leading digit, and caps at 65535 ms;
/// * `repeat` needs a lighting line before it (a paint that reaches a real
///   LED, or a roll) and may appear once;
/// * `0:off` is `bad-index`, `#fff` is `bad-color`, and mixing a colour list
///   with `i:#hex` on one segment fails as `bad-time`;
/// * `\r\n`, `\n` and `\r` all break lines; a single trailing break does not
///   start a new line; more than 20 lines is `too-many-lines`;
/// * more than 512 UTF-8 bytes is `too-long` before anything else is checked.
enum LEDSParser {
    static func parse(_ text: String, ledCount requestedLedCount: Int) throws(LEDSParseError) -> LEDSProgram {
        let ledCount = LEDSProgram.normalizedLedCount(requestedLedCount)
        if text.utf8.count > LEDSLimits.maxProgramBytes {
            throw LEDSParseError(.tooLong, line: 0, column: 0)
        }
        let lines = splitLines(text)
        if lines.count > LEDSLimits.maxProgramLines {
            throw LEDSParseError(.tooManyLines, line: LEDSLimits.maxProgramLines + 1, column: 1)
        }

        var steps: [LEDSStep] = []
        var litBeforeRepeat = false
        var sawRepeat = false
        var pendingRepeatError: LEDSParseError?

        for (offset, line) in lines.enumerated() {
            let lineNumber = offset + 1
            if let error = pendingRepeatError {
                // The firmware reports a premature repeat on the line that follows it.
                throw LEDSParseError(error.kind, line: lineNumber, column: 1)
            }
            guard let parsed = try parseLine(line, lineNumber: lineNumber, ledCount: ledCount) else { continue }
            switch parsed.step {
            case .repeat:
                if sawRepeat {
                    throw LEDSParseError(.badRepeat, line: lineNumber, column: 1)
                }
                sawRepeat = true
                if !litBeforeRepeat {
                    pendingRepeatError = LEDSParseError(.badRepeat, line: lineNumber, column: 1)
                }
            case .paint, .roll:
                if !sawRepeat, parsed.lights { litBeforeRepeat = true }
            case .brightness, .comment:
                break
            }
            steps.append(parsed.step)
        }
        if let error = pendingRepeatError {
            throw error
        }
        return LEDSProgram(steps: steps, ledCount: ledCount, source: text)
    }

    // MARK: Lines

    /// Splits on `\r\n`, `\n` and `\r`, dropping one trailing empty line.
    static func splitLines(_ text: String) -> [String] {
        var lines: [String] = []
        var current = ""
        var scalars = text.unicodeScalars.makeIterator()
        var pending: Unicode.Scalar? = scalars.next()
        while let scalar = pending {
            pending = scalars.next()
            switch scalar {
            case "\n":
                lines.append(current)
                current = ""
            case "\r":
                lines.append(current)
                current = ""
                if pending == "\n" { pending = scalars.next() }
            default:
                current.unicodeScalars.append(scalar)
            }
        }
        if !current.isEmpty || lines.isEmpty {
            lines.append(current)
        }
        return lines
    }

    struct Token {
        let text: String
        let column: Int
        var lowercased: String { text.lowercased() }
    }

    static func isBlank(_ scalar: Unicode.Scalar) -> Bool { scalar == " " || scalar == "\t" }

    /// Splits on spaces and tabs only (a no-break space is not blank to the firmware).
    static func tokenize(_ text: String, baseColumn: Int) -> [Token] {
        var tokens: [Token] = []
        var current = ""
        var start = 0
        var column = 0
        for scalar in text.unicodeScalars {
            column += 1
            if isBlank(scalar) {
                if !current.isEmpty {
                    tokens.append(Token(text: current, column: baseColumn + start))
                    current = ""
                }
            } else {
                if current.isEmpty { start = column }
                current.unicodeScalars.append(scalar)
            }
        }
        if !current.isEmpty { tokens.append(Token(text: current, column: baseColumn + start)) }
        return tokens
    }

    struct ParsedLine {
        let step: LEDSStep
        /// True when this line counts as lighting something for `repeat`.
        let lights: Bool
    }

    static func parseLine(_ line: String, lineNumber: Int, ledCount: Int) throws(LEDSParseError) -> ParsedLine? {
        let scalars = Array(line.unicodeScalars)
        var first = 0
        while first < scalars.count, isBlank(scalars[first]) { first += 1 }
        if first == scalars.count { return nil }
        let rest = String(String.UnicodeScalarView(scalars[first...]))

        // Comments: only at the start of a line.
        if rest.hasPrefix("//") {
            let text = String(rest.drop { $0 == "/" }).trimmingCharacters(in: .whitespaces)
            return ParsedLine(step: .comment(text), lights: false)
        }
        if rest.hasPrefix(";") {
            let text = String(rest.drop { $0 == ";" || $0 == "/" }).trimmingCharacters(in: .whitespaces)
            return ParsedLine(step: .comment(text), lights: false)
        }
        if rest == "#" || rest.hasPrefix("# ") || rest.hasPrefix("#\t") {
            let text = String(rest.dropFirst()).trimmingCharacters(in: .whitespaces)
            return ParsedLine(step: .comment(text), lights: false)
        }

        let tokens = tokenize(line, baseColumn: 1)
        guard let head = tokens.first else { return nil }
        switch head.lowercased {
        case "brightness":
            return ParsedLine(step: try parseBrightness(tokens, lineNumber: lineNumber), lights: false)
        case "repeat":
            return ParsedLine(step: try parseRepeat(tokens, lineNumber: lineNumber), lights: false)
        case "roll", "roll-left", "roll-right":
            return ParsedLine(step: try parseRoll(tokens, lineNumber: lineNumber), lights: true)
        default:
            return try parsePaint(line, lineNumber: lineNumber, ledCount: ledCount)
        }
    }

    // MARK: Keywords

    static func digits(_ text: String) -> (value: Int, count: Int) {
        var value = 0
        var count = 0
        for scalar in text.unicodeScalars {
            guard scalar.isASCII, ("0"..."9").contains(scalar) else { break }
            value = min(value * 10 + Int(scalar.value - 48), 1 << 40)
            count += 1
        }
        return (value, count)
    }

    static func parseBrightness(_ tokens: [Token], lineNumber: Int) throws(LEDSParseError) -> LEDSStep {
        let head = tokens[0]
        guard tokens.count > 1 else {
            throw LEDSParseError(.badBrightness, line: lineNumber, column: head.column + head.text.count)
        }
        let token = tokens[1]
        let (value, count) = digits(token.text)
        if count == 0 || value > LEDSLimits.maxBrightness {
            throw LEDSParseError(.badBrightness, line: lineNumber, column: token.column + count)
        }
        if count < token.text.unicodeScalars.count {
            throw LEDSParseError(.trailingInput, line: lineNumber, column: token.column + count)
        }
        if tokens.count > 2 {
            throw LEDSParseError(.trailingInput, line: lineNumber, column: tokens[2].column)
        }
        return .brightness(value)
    }

    static func parseRepeat(_ tokens: [Token], lineNumber: Int) throws(LEDSParseError) -> LEDSStep {
        guard tokens.count > 1 else { return .repeat(nil) }
        let token = tokens[1]
        let (value, count) = digits(token.text)
        if count == 0 {
            throw LEDSParseError(.badRepeat, line: lineNumber, column: token.column)
        }
        if count < token.text.unicodeScalars.count {
            throw LEDSParseError(.trailingInput, line: lineNumber, column: token.column + count)
        }
        if value < LEDSLimits.minRepeat || value > LEDSLimits.maxRepeat {
            throw LEDSParseError(.badRepeat, line: lineNumber, column: token.column + count)
        }
        if tokens.count > 2 {
            throw LEDSParseError(.trailingInput, line: lineNumber, column: tokens[2].column)
        }
        return .repeat(value)
    }

    static func parseRoll(_ tokens: [Token], lineNumber: Int) throws(LEDSParseError) -> LEDSStep {
        let head = tokens[0]
        let direction: LEDSRollDirection = head.lowercased == "roll-left" ? .left : .right
        guard tokens.count > 1 else {
            throw LEDSParseError(.badTime, line: lineNumber, column: head.column + head.text.count + 1)
        }
        // Roll owns its line: a `;` anywhere is a syntax failure to the firmware.
        for token in tokens where token.text.contains(";") {
            throw LEDSParseError(.badTime, line: lineNumber, column: token.column + (token.text.firstIndex(of: ";").map { token.text.distance(from: token.text.startIndex, to: $0) } ?? 0))
        }
        guard let duration = parseTime(tokens[1].text) else {
            throw LEDSParseError(.badTime, line: lineNumber, column: tokens[1].column)
        }
        var easing: LEDSEasing?
        if tokens.count > 2 {
            guard let named = LEDSEasing(token: tokens[2].text) else {
                throw LEDSParseError(.badTime, line: lineNumber, column: tokens[2].column)
            }
            easing = named
        }
        if tokens.count > 3 {
            throw LEDSParseError(.trailingInput, line: lineNumber, column: tokens[3].column)
        }
        return .roll(LEDSRoll(durationMs: duration, direction: direction, easing: easing))
    }

    // MARK: Times

    /// `330ms`, `2s`, `0.33s` (three fraction digits kept, the rest dropped),
    /// suffixes case-insensitive, at most 65535 ms. Nil for anything else.
    static func parseTime(_ raw: String) -> Int? {
        let text = raw.lowercased()
        func allDigits(_ s: Substring) -> Bool { !s.isEmpty && s.unicodeScalars.allSatisfy { $0.isASCII && ("0"..."9").contains($0) } }
        if text.hasSuffix("ms") {
            let body = text.dropLast(2)
            guard allDigits(body), let value = Int(body) ?? (body.count > 12 ? Int.max : nil) else { return nil }
            return value <= LEDSLimits.maxTimeMs ? value : nil
        }
        if text.hasSuffix("s") {
            let body = text.dropLast()
            let parts = body.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count <= 2, allDigits(parts[0]) else { return nil }
            var milliseconds = (Int(parts[0]) ?? Int.max / 2000) * 1000
            if parts.count == 2 {
                guard allDigits(parts[1]) else { return nil }
                let fraction = String(parts[1].prefix(3))
                milliseconds += Int(fraction.padding(toLength: 3, withPad: "0", startingAt: 0)) ?? 0
            }
            return milliseconds <= LEDSLimits.maxTimeMs ? milliseconds : nil
        }
        return nil
    }

    /// The `duration`, `easing`, `duration easing`, `duration delay`,
    /// `easing delay` and `duration easing delay` shapes.
    static func parseTiming(_ tokens: ArraySlice<Token>, lineNumber: Int) throws(LEDSParseError) -> LEDSTiming {
        var timing = LEDSTiming()
        var index = tokens.startIndex
        enum Expect { case durationOrEasing, easingOrDelay, delayOnly, done }
        var expect = Expect.durationOrEasing
        while index < tokens.endIndex {
            let token = tokens[index]
            let time = parseTime(token.text)
            let easing = LEDSEasing(token: token.text)
            switch expect {
            case .durationOrEasing:
                if let time { timing.durationMs = time; expect = .easingOrDelay }
                else if let easing { timing.easing = easing; expect = .delayOnly }
                else { throw LEDSParseError(.badTime, line: lineNumber, column: token.column) }
            case .easingOrDelay:
                if let time { timing.delayMs = time; expect = .done }
                else if let easing { timing.easing = easing; expect = .delayOnly }
                else { throw LEDSParseError(.badTime, line: lineNumber, column: token.column) }
            case .delayOnly:
                if let time { timing.delayMs = time; expect = .done }
                else { throw LEDSParseError(.badTime, line: lineNumber, column: token.column) }
            case .done:
                throw LEDSParseError(.trailingInput, line: lineNumber, column: token.column)
            }
            index += 1
        }
        return timing
    }

    // MARK: Paint

    static func parsePaint(_ line: String, lineNumber: Int, ledCount: Int) throws(LEDSParseError) -> ParsedLine? {
        var segments: [LEDSSegment] = []
        var lights = false
        var pieceStart = 0
        var column = 0
        let scalars = Array(line.unicodeScalars)
        var pieces: [(String, Int)] = []
        for (offset, scalar) in scalars.enumerated() {
            column = offset + 1
            if scalar == ";" {
                pieces.append((String(String.UnicodeScalarView(scalars[pieceStart..<offset])), pieceStart + 1))
                pieceStart = offset + 1
            }
        }
        pieces.append((String(String.UnicodeScalarView(scalars[pieceStart...])), pieceStart + 1))
        _ = column

        for (piece, baseColumn) in pieces {
            let tokens = tokenize(piece, baseColumn: baseColumn)
            guard !tokens.isEmpty else { continue }
            let segment = try parseSegment(tokens, lineNumber: lineNumber)
            segments.append(segment)
            switch segment.kind {
            case .wholeBar, .colorList:
                lights = true
            case .indexed(let assignments):
                if assignments.contains(where: { $0.index < ledCount }) { lights = true }
            }
        }
        guard !segments.isEmpty else { return nil }
        return ParsedLine(step: .paint(segments), lights: lights)
    }

    static func parseSegment(_ tokens: [Token], lineNumber: Int) throws(LEDSParseError) -> LEDSSegment {
        var index = 0
        let head = tokens[0]
        let kind: LEDSSegmentKind

        if head.lowercased == "off" {
            kind = .wholeBar(nil)
            index = 1
        } else if let colon = head.text.firstIndex(of: ":"), head.text.first.map({ $0.isASCII && $0.isNumber }) == true {
            _ = colon
            var assignments: [LEDSAssignment] = []
            while index < tokens.count, let assignment = indexedAssignment(tokens[index].text) {
                switch assignment {
                case .success(let value):
                    assignments.append(value)
                case .failure(let kind):
                    throw LEDSParseError(kind, line: lineNumber, column: tokens[index].column)
                }
                index += 1
            }
            kind = .indexed(assignments)
        } else if head.text.hasPrefix("#") {
            var colors: [RGB8] = []
            while index < tokens.count, tokens[index].text.hasPrefix("#") {
                guard let color = RGB8(hex: tokens[index].text) else {
                    throw LEDSParseError(.badColor, line: lineNumber, column: tokens[index].column)
                }
                colors.append(color)
                index += 1
            }
            kind = colors.count == 1 ? .wholeBar(colors[0]) : .colorList(colors)
        } else {
            throw LEDSParseError(.syntax, line: lineNumber, column: head.column)
        }

        let timing = try parseTiming(tokens[index...], lineNumber: lineNumber)
        return LEDSSegment(kind: kind, timing: timing)
    }

    /// `digits:#RRGGBB`. Nil when the token is not of that shape at all (so the
    /// caller can hand it to the timing parser); a failure when the shape is
    /// right and the colour is wrong (`0:off`, `0:`, `0:#fff` are `bad-index`).
    static func indexedAssignment(_ token: String) -> Result<LEDSAssignment, LEDSParseError.Kind>? {
        guard let first = token.unicodeScalars.first, first.isASCII, ("0"..."9").contains(first) else { return nil }
        guard let colon = token.firstIndex(of: ":") else { return nil }
        let digits = token[token.startIndex..<colon]
        guard digits.unicodeScalars.allSatisfy({ $0.isASCII && ("0"..."9").contains($0) }) else { return nil }
        let colorText = String(token[token.index(after: colon)...])
        guard let color = RGB8(hex: colorText) else { return .failure(.badIndex) }
        let index = Int(digits) ?? Int.max
        return .success(LEDSAssignment(index: index, color: color))
    }
}
