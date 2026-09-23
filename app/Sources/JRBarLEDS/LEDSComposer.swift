import Foundation

/// A light built from layers instead of typed — Chroma Studio's stacked
/// layers and Keychron's zones, made honest about a firmware that plays one
/// line at a time inside 512 bytes. A base (one colour or a gradient) with
/// its motion (steady, breathing or rolling), an optional accent that
/// travels the strip, LEDs held at a colour of their own, and a brightness.
///
/// The composer writes the shortest LEDS text that plays those layers on
/// the strip, the Dot and the Screen Bar, already inside the presentation
/// compiler's limits so nothing it writes is slowed later. What the
/// firmware cannot play together it leaves out and says why, rather than
/// writing something that looks like the request and is not.
public struct LEDSComposition: Equatable, Sendable {
    public enum Base: Equatable, Sendable {
        /// Every LED one colour.
        case solid(RGB8)
        /// LED 0 to LED 7, blended evenly in channel codes.
        case gradient(RGB8, RGB8)
    }

    public enum Motion: Equatable, Sendable {
        case steady
        /// Rests dim, swells to the base and back over the period.
        case breathe(periodMs: Int)
        /// The whole arrangement travels one full loop per period.
        case roll(periodMs: Int, leftward: Bool)
    }

    /// One LED of its own colour travelling the strip, a step at a time.
    public struct Accent: Equatable, Sendable {
        public var color: RGB8
        public var stepMs: Int
        public var leftward: Bool

        public init(color: RGB8, stepMs: Int, leftward: Bool = false) {
            self.color = color
            self.stepMs = stepMs
            self.leftward = leftward
        }
    }

    public var base: Base
    public var motion: Motion
    public var accent: Accent?
    /// LEDs held at their own colour whatever the base does (0…7).
    public var overrides: [Int: RGB8]
    /// The firmware's global `brightness`, 0…255.
    public var brightness: Int
    /// How far a breath falls, as a share of the base colour.
    public var breatheFloor: Double

    public init(base: Base, motion: Motion = .steady, accent: Accent? = nil,
                overrides: [Int: RGB8] = [:], brightness: Int = 255, breatheFloor: Double = 0.15) {
        self.base = base
        self.motion = motion
        self.accent = accent
        self.overrides = overrides
        self.brightness = brightness
        self.breatheFloor = breatheFloor
    }
}

public struct LEDSComposed: Equatable, Sendable {
    /// The program, ready for the editor.
    public let text: String
    /// Layers left out because the firmware cannot play them together
    /// with the rest, each as one sentence.
    public let dropped: [String]
    /// Timings raised to what the presentation compiler allows, each as
    /// one sentence — the text already carries the raised value.
    public let adjusted: [String]
}

public enum LEDSComposer {
    /// The strip's LEDs; the Dot plays the first two of the same text.
    public static let ledCount = 8

    public static func compose(_ composition: LEDSComposition) -> LEDSComposed {
        var dropped: [String] = []
        var adjusted: [String] = []
        var lines: [String] = []
        let brightness = max(0, min(255, composition.brightness))
        if brightness < 255 { lines.append("brightness \(brightness)") }

        let base = baseColors(composition.base)
        let overrides = composition.overrides.filter { (0..<ledCount).contains($0.key) }
        var held = base
        for (index, color) in overrides { held[index] = color }

        switch composition.motion {
        case .steady:
            guard let accent = composition.accent else {
                // Nothing moves: one line, no loop.
                lines.append(paint(held))
                break
            }
            let order = travelOrder(leftward: accent.leftward)
            let saturated = LEDSPresentationCompiler.isSaturatedRed(accent.color)
                || held.contains(where: LEDSPresentationCompiler.isSaturatedRed)
            // The compiler's measure is the loop: one lap of the accent
            // may not be quicker than a flash at 2 Hz (1 Hz with
            // saturated red), so a step is at least an eighth of that.
            let lap = saturated ? LEDSPresentationCompiler.minSaturatedRedCycleMs : LEDSPresentationCompiler.minPresentationCycleMs
            let step = raised(accent.stepMs, to: (lap + ledCount - 1) / ledCount,
                              what: "The accent's step", saturated: saturated, into: &adjusted)
            let time = "\(LEDSRenderer.formatTime(step)) none"
            // The loop starts by laying the base down with the accent on
            // its first LED — one timed line, so the compiler has nothing
            // to lengthen and the loop never shows the base bare.
            lines.append("\(paint(held)) \(time); \(order[0]):\(accent.color.hex) \(time)")
            for position in 1..<order.count {
                let index = order[position], previous = order[position - 1]
                lines.append("\(index):\(accent.color.hex) \(time); \(previous):\(held[previous].hex) \(time)")
            }
            lines.append("repeat")

        case .breathe(let periodMs):
            if composition.accent != nil {
                dropped.append("The moving accent was left out: a breathing base already uses every step, and the firmware plays one line at a time.")
            }
            let saturated = held.contains(where: LEDSPresentationCompiler.isSaturatedRed)
            let period = raised(periodMs, to: saturated ? LEDSPresentationCompiler.minSaturatedRedCycleMs
                                                        : LEDSPresentationCompiler.minPresentationCycleMs,
                                what: "The breath", saturated: saturated, into: &adjusted)
            let floor = max(0, min(1, composition.breatheFloor))
            var low = base.map { scaled($0, by: floor) }
            for (index, color) in overrides { low[index] = color }
            // The rest at the bottom is a timed step, so the compiler has
            // nothing to lengthen; a held LED is the same colour at both
            // ends of the pulse and does not move.
            let rest = max(LEDSPresentationCompiler.minPresentationPhaseMs, period / 4)
            lines.append("\(paint(low)) \(LEDSRenderer.formatTime(rest)) none")
            lines.append("\(paint(held)) \(LEDSRenderer.formatTime(period)) pulse")
            lines.append("repeat")

        case .roll(let periodMs, let leftward):
            if !overrides.isEmpty {
                dropped.append("The held LEDs were left out: a roll moves every LED, so none can hold still.")
            }
            var palette = base
            if let accent = composition.accent {
                // The accent rides the roll: one LED of the palette, at
                // the roll's pace and in its direction.
                palette[0] = accent.color
                adjusted.append("The accent rides the roll, at the roll's pace and in its direction.")
            }
            if Set(palette).count == 1 {
                dropped.append("The roll was left out: a single colour looks the same wherever it rolls. Add a gradient or an accent.")
                lines.append(paint(palette))
                break
            }
            let saturated = palette.contains(where: LEDSPresentationCompiler.isSaturatedRed)
            let period = raised(periodMs, to: saturated ? LEDSPresentationCompiler.minSaturatedRedCycleMs
                                                        : LEDSPresentationCompiler.minPresentationCycleMs,
                                what: "The roll", saturated: saturated, into: &adjusted)
            // The palette line is inside the loop, so it is timed: the
            // compiler would give an untimed one the same minimum anyway.
            let settle = saturated ? LEDSPresentationCompiler.minSaturatedRedPhaseMs : LEDSPresentationCompiler.minPresentationPhaseMs
            lines.append("\(paint(palette)) \(LEDSRenderer.formatTime(settle)) none")
            lines.append("\(leftward ? "roll-left" : "roll-right") \(LEDSRenderer.formatTime(period)) linear")
            lines.append("repeat")
        }

        return LEDSComposed(text: lines.joined(separator: "\n"), dropped: dropped, adjusted: adjusted)
    }

    /// The base's eight colours.
    public static func baseColors(_ base: LEDSComposition.Base) -> [RGB8] {
        switch base {
        case .solid(let color):
            return Array(repeating: color, count: ledCount)
        case .gradient(let from, let to):
            return (0..<ledCount).map { index in
                let t = Double(index) / Double(ledCount - 1)
                func mix(_ a: UInt8, _ b: UInt8) -> UInt8 {
                    UInt8((Double(a) + (Double(b) - Double(a)) * t).rounded())
                }
                return RGB8(r: mix(from.r, to.r), g: mix(from.g, to.g), b: mix(from.b, to.b))
            }
        }
    }

    /// The shortest spelling of eight colours: `off`, one colour, or the list.
    static func paint(_ colors: [RGB8]) -> String {
        if colors.allSatisfy({ $0 == .black }) { return "off" }
        if Set(colors).count == 1, let only = colors.first { return only.hex }
        return colors.map(\.hex).joined(separator: " ")
    }

    static func travelOrder(leftward: Bool) -> [Int] {
        leftward ? Array((0..<ledCount).reversed()) : Array(0..<ledCount)
    }

    static func scaled(_ color: RGB8, by factor: Double) -> RGB8 {
        func channel(_ value: UInt8) -> UInt8 { UInt8((Double(value) * factor).rounded()) }
        return RGB8(r: channel(color.r), g: channel(color.g), b: channel(color.b))
    }

    /// `value` raised to `minimum` (and kept inside the firmware's 65535 ms),
    /// with a sentence when it had to move.
    static func raised(_ value: Int, to minimum: Int, what: String, saturated: Bool, into notes: inout [String]) -> Int {
        let safe = min(LEDSLimits.maxTimeMs, max(minimum, value))
        if safe > value {
            let why = saturated ? "nothing with saturated red flashes faster than 1 Hz" : "nothing flashes faster than 2 Hz"
            notes.append("\(what) is \(LEDSRenderer.formatTime(safe)), not \(LEDSRenderer.formatTime(max(0, value))): \(why).")
        }
        return safe
    }
}
