import Foundation

/// Port of `presentation_compiler.py`: the temporal-safety pass every visible
/// light surface runs before a program is displayed.
///
/// Nothing on the product may flash faster than 2 Hz (1 Hz for saturated
/// red). The compiler only ever lengthens timings, by three rules, and the
/// strictest one wins:
///
/// * A field-wide paint (a whole-bar colour or a colour list) written without
///   a duration inside a loop gets a concrete minimum phase, and a roll gets a
///   minimum phase. A per-LED (`index:#colour`) paint keeps whatever phase it
///   was written with: it is spatial motion, and a floor on it would only cap
///   how fast light may travel.
/// * The compiled loop is rendered (`LEDSFlashAnalysis`) and its MEASURED flash
///   rate must sit at or under the limit. A loop that flashes faster is
///   stretched by the whole-number factor that brings it under, which keeps
///   every overlap and stagger exactly as written.
/// * A loop is never shorter than the minimum cycle.
///
/// Delays are never clamped (they are phase offsets and cannot raise the flash
/// rate). Nothing is refused for being lively; it is slowed. The port is held
/// to the Python compiler by `compiler.json` and `flash.json`, which
/// `app/scripts/gen_leds_fixtures.py` writes from the Python side.
public enum LEDSPresentationCompiler {
    public static let minPresentationCycleMs = 500
    public static let minPresentationPhaseMs = 250
    public static let minSaturatedRedCycleMs = 1000
    public static let minSaturatedRedPhaseMs = 500
    public static let maxPresentationHz = 2.0
    public static let maxSaturatedRedHz = 1.0
    public static let safeFallbackProgram = "off"

    public struct Result: Hashable, Sendable {
        /// The text to display. Either the safe transform of the input or the fallback.
        public let program: String
        public let accepted: Bool
        public let transformed: Bool
        public let reasons: [String]
    }

    public struct SafetyError: Error, Sendable { public let message: String }

    public static func isSaturatedRed(_ color: RGB8) -> Bool {
        color.r >= 192 && color.g <= 64 && color.b <= 64
    }

    static func segmentColors(_ segment: LEDSSegment) -> [RGB8] {
        switch segment.kind {
        case .wholeBar(let color): return color.map { [$0] } ?? []
        case .colorList(let colors): return colors
        case .indexed(let assignments): return assignments.map(\.color)
        }
    }

    static func stepHasSaturatedRed(_ step: LEDSStep) -> Bool {
        guard case .paint(let segments) = step else { return false }
        return segments.contains { segmentColors($0).contains(where: isSaturatedRed) }
    }

    /// Python `animation.step_duration_ms`: the editor's estimate of one step,
    /// counting every segment (including ones that only name ignored LEDs).
    public static func stepDurationMs(_ step: LEDSStep) -> Int {
        switch step {
        case .paint(let segments): return segments.map(\.timing.spanMs).max() ?? 0
        case .roll(let roll): return max(0, roll.durationMs)
        default: return 0
        }
    }

    /// Python `animation.loop_duration_ms`.
    public static func loopDurationMs(_ steps: [LEDSStep]) -> Int? {
        guard let repeatAt = steps.firstIndex(where: { if case .repeat = $0 { return true } else { return false } }) else { return nil }
        return steps[..<repeatAt].map(stepDurationMs).reduce(0, +)
    }

    static func safeTiming(_ timing: LEDSTiming, saturatedRed: Bool, forceTimed: Bool) throws(SafetyError) -> (LEDSTiming, Bool) {
        let minimum = saturatedRed ? minSaturatedRedPhaseMs : minPresentationPhaseMs
        var duration = timing.durationMs
        if duration == nil, forceTimed {
            if timing.easing == .pulse {
                duration = saturatedRed ? minSaturatedRedCycleMs : minPresentationCycleMs
            } else if timing.easing != nil {
                duration = max(minimum, timing.effectiveDurationMs)
            } else {
                duration = minimum
            }
        }
        let delay = timing.delayMs
        if let duration, duration > LEDSLimits.maxTimeMs { throw SafetyError(message: "safe timing exceeds firmware limit") }
        if let delay, delay > LEDSLimits.maxTimeMs { throw SafetyError(message: "safe timing exceeds firmware limit") }
        let updated = LEDSTiming(durationMs: duration, easing: timing.easing, delayMs: delay)
        return (updated, updated != timing)
    }

    /// Python `_slowdown_factor`: by how much this loop has to be stretched,
    /// as a whole number. The cycle floor is a product rule and the flash floor
    /// is the measured accessibility one; the stricter wins. A whole factor
    /// divides the flash rate by exactly that integer and leaves the shape
    /// untouched.
    static func slowdownFactor(_ steps: [LEDSStep], loopMs: Int?, requiredCycleMs: Int, ledCount: Int, saturatedRed: Bool) -> Int {
        guard let loopMs, loopMs > 0 else { return 1 }
        var cycleFactor = 1
        if loopMs < requiredCycleMs {
            cycleFactor = Int((Double(requiredCycleMs) / Double(loopMs)).rounded(.up))
        }
        let limit = saturatedRed ? maxSaturatedRedHz : maxPresentationHz
        let measured = LEDSFlashAnalysis.analyse(steps, ledCount: ledCount).hertz
        var flashFactor = 1
        if measured > limit {
            flashFactor = Int((measured / limit).rounded(.up))
        }
        return max(1, cycleFactor, flashFactor)
    }

    /// Python `_safe_animation`.
    public static func safeSteps(_ steps: [LEDSStep], ledCount: Int = 8) throws(SafetyError) -> (steps: [LEDSStep], reasons: [String]) {
        var reasons: [String] = []
        var transformed: [LEDSStep] = []
        var sawRed = false
        let repeatIndex = steps.firstIndex { if case .repeat = $0 { return true } else { return false } }
        let forceTimed = repeatIndex != nil
        for step in steps {
            switch step {
            case .paint(let segments):
                let red = stepHasSaturatedRed(step)
                sawRed = sawRed || red
                var safeSegments: [LEDSSegment] = []
                var changed = false
                for segment in segments {
                    if case .indexed = segment.kind {
                        // A named-LED paint is spatial motion, not a field
                        // flash: it moves a few LEDs and the rest hold, so a
                        // phase floor on it only caps how fast light may
                        // travel. The measured flash pass below keeps
                        // staggered paints honest instead.
                        safeSegments.append(segment)
                        continue
                    }
                    let (timing, segmentChanged) = try safeTiming(segment.timing, saturatedRed: red, forceTimed: forceTimed)
                    safeSegments.append(LEDSSegment(kind: segment.kind, timing: timing))
                    changed = changed || segmentChanged
                }
                transformed.append(.paint(safeSegments))
                if changed { reasons.append("phase_cadence_clamped") }
            case .roll(let roll):
                let duration = max(minPresentationPhaseMs, roll.durationMs)
                if duration > LEDSLimits.maxTimeMs { throw SafetyError(message: "safe roll exceeds firmware limit") }
                transformed.append(.roll(LEDSRoll(durationMs: duration, direction: roll.direction, easing: roll.easing)))
                if duration != roll.durationMs { reasons.append("roll_cadence_clamped") }
            default:
                transformed.append(step)
            }
        }

        if let repeatIndex {
            let required = sawRed ? minSaturatedRedCycleMs : minPresentationCycleMs
            let factor = slowdownFactor(
                transformed,
                loopMs: loopDurationMs(transformed),
                requiredCycleMs: required,
                ledCount: ledCount,
                saturatedRed: sawRed
            )
            if factor > 1 {
                var scaled: [LEDSStep] = []
                for (index, step) in transformed.enumerated() {
                    if index >= repeatIndex { scaled.append(step); continue }
                    switch step {
                    case .paint(let segments):
                        var safeSegments: [LEDSSegment] = []
                        for segment in segments {
                            let timing = segment.timing
                            let duration = (timing.durationMs ?? timing.effectiveDurationMs) * factor
                            let delay = timing.delayMs.map { $0 * factor }
                            if duration > LEDSLimits.maxTimeMs || (delay ?? 0) > LEDSLimits.maxTimeMs {
                                throw SafetyError(message: "safe loop timing exceeds firmware limit")
                            }
                            safeSegments.append(LEDSSegment(kind: segment.kind, timing: LEDSTiming(durationMs: duration, easing: timing.easing, delayMs: delay)))
                        }
                        scaled.append(.paint(safeSegments))
                    case .roll(let roll):
                        let duration = roll.durationMs * factor
                        if duration > LEDSLimits.maxTimeMs { throw SafetyError(message: "safe loop timing exceeds firmware limit") }
                        scaled.append(.roll(LEDSRoll(durationMs: duration, direction: roll.direction, easing: roll.easing)))
                    default:
                        scaled.append(step)
                    }
                }
                transformed = scaled
                reasons.append("loop_cadence_clamped")
            }
        }
        var unique: [String] = []
        for reason in reasons where !unique.contains(reason) { unique.append(reason) }
        return (transformed, unique)
    }

    /// Rules the Python editor model (`animation.validate_animation`) enforces
    /// on top of the firmware grammar. The firmware accepts these; the Python
    /// compiler refuses them, so the port refuses them too.
    public static func editorProblems(_ program: LEDSProgram) -> [String] {
        var problems: [String] = []
        for (index, step) in program.steps.enumerated() {
            if case .roll(let roll) = step, roll.durationMs <= 0 {
                problems.append("step \(index + 1): roll-needs-duration")
            }
        }
        return problems
    }

    /// Python `compile_presentation_program`.
    public static func compile(_ program: String, ledCount: Int = 8, fallback: String = safeFallbackProgram) -> Result {
        let parsed: LEDSProgram
        do {
            parsed = try LEDSProgram.parse(program, ledCount: ledCount)
        } catch {
            return Result(program: fallback, accepted: false, transformed: program != fallback, reasons: ["invalid_program"])
        }
        if !editorProblems(parsed).isEmpty {
            return Result(program: fallback, accepted: false, transformed: program != fallback, reasons: ["invalid_program"])
        }
        let safe: (steps: [LEDSStep], reasons: [String])
        do {
            safe = try safeSteps(parsed.steps, ledCount: parsed.ledCount)
        } catch {
            return Result(program: fallback, accepted: false, transformed: program != fallback, reasons: ["unsafe_program"])
        }
        let rendered = LEDSRenderer.render(safe.steps)
        do {
            _ = try LEDSProgram.parse(rendered, ledCount: ledCount)
        } catch {
            return Result(program: fallback, accepted: false, transformed: program != fallback, reasons: ["unsafe_program"])
        }
        return Result(program: rendered, accepted: true, transformed: rendered != program, reasons: safe.reasons)
    }

    /// Convenience: the safe program as a parsed value, or nil when refused.
    public static func compileProgram(_ program: String, ledCount: Int = 8) -> (program: LEDSProgram, result: Result)? {
        let result = compile(program, ledCount: ledCount)
        guard result.accepted, let parsed = try? LEDSProgram.parse(result.program, ledCount: ledCount) else { return nil }
        return (parsed, result)
    }
}
