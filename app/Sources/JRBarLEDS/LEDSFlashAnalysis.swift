import Foundation

/// Port of `flash_analysis.py`: how often a light program reverses the whole
/// field, measured rather than guessed from the text.
///
/// A flash is the accessibility one (WCAG 2.2 SC 2.3.1, ISO 9241-391): a pair
/// of opposing changes in relative luminance of at least `luminanceDelta` out
/// of a state darker than `darkCeiling`, occupying at least `areaFraction` of
/// the field at once, with at least `contrast` Michelson contrast on the
/// strip's mean. Spatial motion fails the area rule, so a comet is never a
/// flash however fast it travels; a whole-bar blink passes all three at
/// whatever rate it blinks. A `roll` is held at its pre-roll state and only
/// costs its own duration, because it repaints nothing.
///
/// The port is line for line, so the numbers match Python's exactly and the
/// presentation compiler decides the same slowdown from them:
///
/// * the renderer walks the loop in 20 ms steps, at most 1200 samples a pass,
///   two passes, and reads the second (a steady state, not a cold start);
/// * colour codes are interpolated in 8-bit space and rounded half to even,
///   the way Python's `round` does;
/// * the mean of a frame is summed the way CPython 3.12's `sum` sums floats
///   (compensated), so the last bit agrees too.
///
/// Pure and cheap (a 256-entry table decodes a channel), because Effect
/// Studio recomputes it on every keystroke.
public enum LEDSFlashAnalysis {
    public static let areaFraction = 0.25
    public static let luminanceDelta = 0.10
    public static let darkCeiling = 0.80
    public static let contrast = 0.20
    /// A little over one firmware frame; a reversal the eye can see lasts many.
    public static let sampleMs = 20
    /// Keeps a very long program from costing real time.
    public static let maxSamples = 1200

    /// How often the field reverses, and over how long.
    public struct Result: Equatable, Sendable {
        public let hertz: Double
        public let flashes: Int
        public let spanMs: Int
        public let peakArea: Double

        public var flashing: Bool { flashes > 0 }
    }

    // MARK: Luminance

    /// IEC 61966-2-1 channel decode for every 8-bit code, computed once with
    /// the same expression Python evaluates per call.
    private static let channelTable: [Double] = (0...255).map { code in
        let fraction = max(0.0, min(1.0, Double(code) / 255.0))
        if fraction <= 0.04045 { return fraction / 12.92 }
        return pow((fraction + 0.055) / 1.055, 2.4)
    }

    /// IEC 61966-2-1 relative luminance of one 8-bit colour.
    public static func relativeLuminance(_ color: RGB8) -> Double {
        let red = 0.2126 * channelTable[Int(color.r)]
        let green = 0.7152 * channelTable[Int(color.g)]
        let blue = 0.0722 * channelTable[Int(color.b)]
        return red + green + blue
    }

    // MARK: Easing

    /// Where a transition has got to, as a fraction of the way to its target.
    /// `pulse` rises to one and falls back to zero. The curves are deliberately
    /// approximate (`ease-in` is a smoothstep here), because the question is how
    /// many times a second most of the strip reverses, not the third decimal.
    static func eased(_ easing: LEDSEasing?, _ fraction: Double) -> Double {
        let position = max(0.0, min(1.0, fraction))
        switch easing {
        case .some(.none):
            // Measured against the firmware: `none` jumps to its target the
            // moment the delay is up and holds for the rest of the line.
            return 1.0
        case .some(.pulse):
            let angle = 2.0 * Double.pi * position
            return (1.0 - cos(angle)) / 2.0
        case .some(.cosine):
            let angle = Double.pi * position
            return (1.0 - cos(angle)) / 2.0
        case .some(.linear):
            return position
        default:
            // ease, ease-in, ease-out, ease-in-out and a bare duration (which
            // the firmware treats as `ease`).
            let doubled = 2.0 * position
            return position * position * (3.0 - doubled)
        }
    }

    // MARK: Rendering

    struct Transition {
        let delayMs: Int
        let durationMs: Int
        let easing: LEDSEasing?
        let start: RGB8
        let target: RGB8
        let returns: Bool

        var resting: RGB8 { returns ? start : target }

        func at(_ offsetMs: Int) -> RGB8 {
            if offsetMs < delayMs { return start }
            if durationMs <= 0 { return target }
            let elapsed = Double(offsetMs - delayMs)
            let fraction = elapsed / Double(durationMs)
            if fraction >= 1.0, !returns { return target }
            let weight = LEDSFlashAnalysis.eased(easing, fraction)
            return RGB8(
                r: Self.channel(from: start.r, to: target.r, weight: weight),
                g: Self.channel(from: start.g, to: target.g, weight: weight),
                b: Self.channel(from: start.b, to: target.b, weight: weight)
            )
        }

        /// `max(0, min(255, round(begin + (end - begin) * weight)))`, with
        /// Python's round-half-to-even.
        private static func channel(from begin: UInt8, to end: UInt8, weight: Double) -> UInt8 {
            let span = Double(Int(end) - Int(begin))
            let value = Double(begin) + span * weight
            let rounded = value.rounded(.toNearestOrEven)
            return UInt8(max(0.0, min(255.0, rounded)))
        }
    }

    /// Which LEDs a segment paints, and to what. A whole-bar colour and a
    /// colour list name the whole field (a list turns the LEDs past its end
    /// off); an indexed paint names only its own LEDs and the rest hold.
    static func segmentTargets(_ segment: LEDSSegment, ledCount: Int) -> [Int: RGB8] {
        var targets: [Int: RGB8] = [:]
        switch segment.kind {
        case .wholeBar(let color):
            for index in 0..<ledCount { targets[index] = color ?? .black }
        case .colorList(let colors):
            for index in 0..<ledCount { targets[index] = index < colors.count ? colors[index] : .black }
        case .indexed(let assignments):
            for assignment in assignments where assignment.index >= 0 && assignment.index < ledCount {
                targets[assignment.index] = assignment.color
            }
        }
        return targets
    }

    /// One line's per-LED transitions, later segments winning: the firmware
    /// keeps the last assignment an LED gets on a line.
    static func paintTransitions(_ segments: [LEDSSegment], state: [RGB8], ledCount: Int) -> [Int: Transition] {
        var transitions: [Int: Transition] = [:]
        for segment in segments {
            let timing = segment.timing
            let duration = timing.effectiveDurationMs
            let delay = timing.delayMs ?? 0
            let easing = timing.easing
            for (index, target) in segmentTargets(segment, ledCount: ledCount) {
                transitions[index] = Transition(
                    delayMs: delay,
                    durationMs: duration,
                    easing: easing,
                    start: state[index],
                    target: target,
                    returns: easing == .some(.pulse)
                )
            }
        }
        return transitions
    }

    /// The steps that play over and over, or every step when none repeat.
    static func loopSteps(_ steps: [LEDSStep]) -> [LEDSStep] {
        for (index, step) in steps.enumerated() {
            if case .repeat = step { return Array(steps[..<index]) }
        }
        return steps
    }

    /// One pass of the loop: appends its frames and leaves the state it ends on.
    static func played(_ steps: [LEDSStep], state: inout [RGB8], interval: Int, frames: inout [[Double]]) {
        var budget = maxSamples
        for step in steps {
            if case .brightness = step {
                // Global and last-one-wins in the firmware: it scales the whole
                // program uniformly and cannot by itself reverse the field.
                continue
            }
            let span = LEDSPresentationCompiler.stepDurationMs(step)
            switch step {
            case .paint(let segments):
                let transitions = paintTransitions(segments, state: state, ledCount: state.count)
                var offset = 0
                while offset < span, budget > 0 {
                    var frame = state
                    for (index, transition) in transitions { frame[index] = transition.at(offset) }
                    frames.append(frame.map(relativeLuminance))
                    budget -= 1
                    offset += interval
                }
                for (index, transition) in transitions { state[index] = transition.resting }
            case .roll:
                // A roll translates the field and never reverses it, so it is
                // held at the pre-roll state. It still costs its duration.
                let held = state.map(relativeLuminance)
                var offset = 0
                while offset < span, budget > 0 {
                    frames.append(held)
                    budget -= 1
                    offset += interval
                }
            default:
                break
            }
            if budget <= 0 { break }
        }
    }

    /// Per-LED relative luminance through the repeating section, and the
    /// interval between frames. The strip starts dark. `passes` plays the loop
    /// more than once and returns only the LAST pass: a steady-state reading.
    static func renderLuminance(_ steps: [LEDSStep], ledCount: Int, passes: Int = 1) -> (frames: [[Double]], interval: Int) {
        let loop = loopSteps(steps)
        var state = [RGB8](repeating: .black, count: max(1, ledCount))
        let interval = max(1, sampleMs)
        var discarded: [[Double]] = []
        for _ in 0..<max(0, max(1, passes) - 1) {
            discarded.removeAll(keepingCapacity: true)
            played(loop, state: &state, interval: interval, frames: &discarded)
        }
        var frames: [[Double]] = []
        played(loop, state: &state, interval: interval, frames: &frames)
        if frames.isEmpty { frames.append(state.map(relativeLuminance)) }
        return (frames, interval)
    }

    // MARK: Measuring

    /// Indexes of the turning points of a signal, ends included.
    static func extrema(_ series: [Double]) -> [Int] {
        if series.count < 2 { return [0] }
        var points = [0]
        var direction = 0
        for index in 1..<series.count {
            let change = series[index] - series[index - 1]
            if abs(change) < 1e-9 { continue }
            let sign = change > 0 ? 1 : -1
            if sign == direction {
                points[points.count - 1] = index
            } else {
                points.append(index)
                direction = sign
            }
        }
        if points[points.count - 1] != series.count - 1 { points.append(series.count - 1) }
        return points
    }

    /// CPython 3.12's `sum()` over floats: the first item joins the integer 0
    /// by plain addition and the rest go through Neumaier compensation, added
    /// once at the end. Matching it keeps a frame's mean identical to Python's
    /// down to the last bit.
    static func pythonSum(_ values: [Double]) -> Double {
        guard var total = values.first else { return 0.0 }
        var compensation = 0.0
        for value in values.dropFirst() {
            let next = total + value
            if abs(total) >= abs(value) {
                compensation += (total - next) + value
            } else {
                compensation += (value - next) + total
            }
            total = next
        }
        if compensation != 0.0, compensation.isFinite { total += compensation }
        return total
    }

    /// How many general flashes a second this program sustains. A flash is
    /// counted only when the field reverses: the strip's mean luminance turns
    /// around with at least `contrast`, and at least `areaFraction` of the LEDs
    /// individually moved by `luminanceDelta` or more out of a state darker than
    /// `darkCeiling`. Two reversals make one flash.
    public static func analyse(_ steps: [LEDSStep], ledCount: Int) -> Result {
        let count = max(1, ledCount)
        let rendered = renderLuminance(steps, ledCount: count, passes: 2)
        var frames = rendered.frames
        let interval = rendered.interval
        let spanMs = max(interval, frames.count * interval)
        if frames.count < 3 { return Result(hertz: 0.0, flashes: 0, spanMs: spanMs, peakArea: 0.0) }
        let repeats = steps.contains { if case .repeat = $0 { return true } else { return false } }
        if repeats, let first = frames.first {
            // The loop seam is a transition like any other: for a two-phase
            // blink it is half the flashes.
            frames.append(first)
        }
        let means = frames.map { pythonSum($0) / Double($0.count) }
        let turns = extrema(means)
        var reversals = 0
        var peakArea = 0.0
        for pair in zip(turns, turns.dropFirst()) {
            let first = pair.0
            let second = pair.1
            let low = min(means[first], means[second])
            let high = max(means[first], means[second])
            let total = low + high
            var swing = 0.0
            if total > 1e-9 { swing = (high - low) / total }
            if swing < contrast { continue }
            // The area rule is about the field moving together: a travelling
            // wave brightens one LED while it dims the one behind it, which is
            // motion, not a reversal.
            let rising = means[second] > means[first]
            var moved = 0
            for index in 0..<count {
                let begin = frames[first][index]
                let end = frames[second][index]
                if (end > begin) != rising { continue }
                if abs(end - begin) < luminanceDelta { continue }
                if min(begin, end) >= darkCeiling { continue }
                moved += 1
            }
            let area = Double(moved) / Double(count)
            peakArea = max(peakArea, area)
            if area >= areaFraction { reversals += 1 }
        }
        let seconds = Double(spanMs) / 1000.0
        let flashes = reversals / 2
        var hertz = 0.0
        if seconds > 0 {
            let flashPairs = Double(reversals) / 2.0
            hertz = flashPairs / seconds
        }
        return Result(hertz: hertz, flashes: flashes, spanMs: spanMs, peakArea: peakArea)
    }
}
