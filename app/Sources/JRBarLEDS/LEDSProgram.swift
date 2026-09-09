import Foundation

// MARK: - Model

/// How long one assignment takes, how it moves, and when it starts.
///
/// `nil` fields mean "not written". The firmware's defaults are applied by
/// the sampler (`LEDSResolvedTiming`), and the Python editor's defaults
/// (`effectiveDurationMs`) are kept here for the presentation compiler port.
public struct LEDSTiming: Hashable, Sendable, Codable {
    public var durationMs: Int?
    public var easing: LEDSEasing?
    public var delayMs: Int?

    public init(durationMs: Int? = nil, easing: LEDSEasing? = nil, delayMs: Int? = nil) {
        self.durationMs = durationMs
        self.easing = easing
        self.delayMs = delayMs
    }

    /// Python `Timing.effective_duration_ms`: written duration, else 330 ms
    /// for a bare easing, else the editor's one-frame estimate (16 ms).
    public var effectiveDurationMs: Int {
        if let durationMs { return durationMs }
        if easing != nil { return LEDSLimits.defaultEasingDurationMs }
        return LEDSLimits.editorFrameMs
    }

    /// Python `Timing.span_ms`.
    public var spanMs: Int { (delayMs ?? 0) + effectiveDurationMs }
}

/// One `index:#color` pair inside an indexed paint segment.
public struct LEDSAssignment: Hashable, Sendable, Codable {
    public var index: Int
    public var color: RGB8

    public init(index: Int, color: RGB8) {
        self.index = index
        self.color = color
    }
}

/// The three shapes a colour assignment can take.
public enum LEDSSegmentKind: Hashable, Sendable {
    /// Every LED to one colour; `nil` is the `off` keyword.
    case wholeBar(RGB8?)
    /// Colours by position; LEDs past the list turn off.
    case colorList([RGB8])
    /// Named LEDs only; unmentioned LEDs hold.
    case indexed([LEDSAssignment])
}

/// One `;`-separated part of a painting line.
public struct LEDSSegment: Hashable, Sendable {
    public var kind: LEDSSegmentKind
    public var timing: LEDSTiming

    public init(kind: LEDSSegmentKind, timing: LEDSTiming = LEDSTiming()) {
        self.kind = kind
        self.timing = timing
    }
}

public enum LEDSRollDirection: String, Sendable, Hashable, Codable {
    case left = "roll-left"
    case right = "roll-right"
}

public struct LEDSRoll: Hashable, Sendable {
    public var durationMs: Int
    public var direction: LEDSRollDirection
    public var easing: LEDSEasing?

    public init(durationMs: Int, direction: LEDSRollDirection = .right, easing: LEDSEasing? = nil) {
        self.durationMs = durationMs
        self.direction = direction
        self.easing = easing
    }
}

/// One physical line of the program that survived parsing (blank lines are dropped).
public enum LEDSStep: Hashable, Sendable {
    case paint([LEDSSegment])
    case brightness(Int)
    case roll(LEDSRoll)
    /// `nil` count loops forever.
    case `repeat`(Int?)
    case comment(String)
}

/// Firmware limits, measured against `sdled.wasm`.
public enum LEDSLimits {
    public static let maxProgramBytes = 512
    public static let maxProgramLines = 20
    public static let maxTimeMs = 65535
    public static let maxBrightness = 255
    public static let minRepeat = 1
    public static let maxRepeat = 65535
    /// An easing with no duration runs this long.
    public static let defaultEasingDurationMs = 330
    /// A line with no duration, easing or delay lasts one frame. The firmware
    /// rounds 1000/60 up: the next line starts 17 ms later, not 16.
    public static let frameMs = 17
    /// The Python editor's estimate of the same frame (`animation.FRAME_MS`),
    /// kept only so the presentation compiler port reproduces its arithmetic.
    public static let editorFrameMs = 16
    public static let supportedLedCounts: Set<Int> = [2, 8]
}

// MARK: - Program

/// A parsed LEDS.LED program.
public struct LEDSProgram: Hashable, Sendable {
    public var steps: [LEDSStep]
    /// The LED count the program was validated against (2 or 8). Index
    /// targets at or past it are parsed and then ignored, exactly like the
    /// firmware build for that device.
    public var ledCount: Int
    /// The text this program was parsed from, or the rendered text for a
    /// program built from steps.
    public var source: String

    public init(steps: [LEDSStep], ledCount: Int = 8) {
        self.steps = steps
        self.ledCount = LEDSProgram.normalizedLedCount(ledCount)
        self.source = LEDSRenderer.render(steps)
    }

    init(steps: [LEDSStep], ledCount: Int, source: String) {
        self.steps = steps
        self.ledCount = ledCount
        self.source = source
    }

    public static func normalizedLedCount(_ value: Int) -> Int {
        LEDSLimits.supportedLedCounts.contains(value) ? value : 8
    }

    /// Parses device text with the firmware's own rules. A rejected program
    /// throws; it is never rendered (the hardware would strobe red).
    public static func parse(_ text: String, ledCount: Int = 8) throws(LEDSParseError) -> LEDSProgram {
        try LEDSParser.parse(text, ledCount: ledCount)
    }

    /// Device text for these steps, in the Python renderer's canonical spelling.
    public func render() -> String { LEDSRenderer.render(steps) }

    /// The brightness the firmware applies: the last `brightness` line anywhere
    /// in the program (it is global, not positional), else 255.
    public var brightness: Int {
        var level = LEDSLimits.maxBrightness
        for step in steps {
            if case .brightness(let value) = step { level = value }
        }
        return level
    }

    public var repeatIndex: Int? {
        steps.firstIndex { if case .repeat = $0 { return true } else { return false } }
    }

    /// `nil` when there is no repeat; `.some(nil)` when it loops forever.
    public var repeatCount: Int?? {
        for step in steps {
            if case .repeat(let count) = step { return .some(count) }
        }
        return nil
    }

    public var loopsForever: Bool {
        if case .some(.none) = repeatCount { return true }
        return false
    }

    /// Length in seconds of the section that repeats, or nil when nothing repeats.
    public var cycleDuration: TimeInterval? { LEDSSampler(program: self, ledCount: ledCount).cycleDuration }

    /// True when the output never changes after the first frame.
    public var isStatic: Bool { LEDSSampler(program: self, ledCount: ledCount).isStatic }

    /// Seconds after which the output stops changing, or nil when it loops forever.
    public var motionEndsAt: TimeInterval? { LEDSSampler(program: self, ledCount: ledCount).motionEndsAt }
}

// MARK: - Errors

/// A parse failure, named the way the firmware names it.
public struct LEDSParseError: Error, Hashable, Sendable, CustomStringConvertible {
    public enum Kind: String, Error, Sendable, Codable, CaseIterable {
        case nullInput = "null-input"
        case tooLong = "too-long"
        case tooManyLines = "too-many-lines"
        case tooManyAnimationLines = "too-many-animation-lines"
        case syntax
        case badColor = "bad-color"
        case badIndex = "bad-index"
        case badTime = "bad-time"
        case badBrightness = "bad-brightness"
        case badRepeat = "bad-repeat"
        case trailingInput = "trailing-input"
    }

    public let kind: Kind
    /// 1-based physical line, 0 for whole-program failures.
    public let line: Int
    /// 1-based column of the offending token, 0 for whole-program failures.
    public let column: Int

    public init(_ kind: Kind, line: Int, column: Int) {
        self.kind = kind
        self.line = line
        self.column = column
    }

    public var description: String {
        "the firmware would reject this program: \(kind.rawValue) at line \(line), column \(column)"
    }
}

// MARK: - Rendering

/// Port of `animation.render_animation`: model to text with no validation.
public enum LEDSRenderer {
    /// The shortest spelling the firmware accepts for this many ms.
    public static func formatTime(_ milliseconds: Int) -> String {
        if milliseconds >= 1000, milliseconds % 1000 == 0 { return "\(milliseconds / 1000)s" }
        return "\(milliseconds)ms"
    }

    static func renderTiming(_ timing: LEDSTiming) -> String {
        var parts: [String] = []
        if let duration = timing.durationMs { parts.append(formatTime(duration)) }
        if let easing = timing.easing { parts.append(easing.rawValue) }
        if let delay = timing.delayMs { parts.append(formatTime(delay)) }
        return parts.isEmpty ? "" : " " + parts.joined(separator: " ")
    }

    static func renderSegment(_ segment: LEDSSegment) -> String {
        let head: String
        switch segment.kind {
        case .wholeBar(let color):
            head = color?.hex ?? "off"
        case .colorList(let colors):
            head = colors.map(\.hex).joined(separator: " ")
        case .indexed(let assignments):
            head = assignments.map { "\($0.index):\($0.color.hex)" }.joined(separator: " ")
        }
        return head + renderTiming(segment.timing)
    }

    public static func render(_ step: LEDSStep) -> String {
        switch step {
        case .paint(let segments):
            return segments.map(renderSegment).joined(separator: "; ")
        case .brightness(let level):
            return "brightness \(level)"
        case .roll(let roll):
            let easing = roll.easing.map { " \($0.rawValue)" } ?? ""
            return "\(roll.direction.rawValue) \(formatTime(roll.durationMs))\(easing)"
        case .repeat(let count):
            return count.map { "repeat \($0)" } ?? "repeat"
        case .comment(let text):
            return "// \(text)".trimmingCharacters(in: .whitespaces)
        }
    }

    public static func render(_ steps: [LEDSStep]) -> String {
        steps.map(render).joined(separator: "\n")
    }
}
