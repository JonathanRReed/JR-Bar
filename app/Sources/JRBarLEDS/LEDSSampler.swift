import Foundation

/// Evaluates a parsed program at any instant, the way `sdled.wasm` does.
///
/// The firmware is a pure function of the milliseconds since the program was
/// parsed (dense and sparse stepping agree), so the sampler compiles the
/// program into a timeline once and answers `codes(atMilliseconds:)` from it:
///
/// * a painting line spans the longest `delay + duration` among the segments
///   that reach a real LED; a line whose span is zero lasts one 17 ms frame
///   and shows its targets immediately; a line that only names ignored LEDs
///   takes no time at all;
/// * a segment with a duration but no easing uses `ease`; an easing with no
///   duration lasts 330 ms; `none` (and a 0 ms duration) jumps to the target
///   once the delay has elapsed;
/// * each LED's transition starts from the colour it was showing when the
///   line began, before brightness; `pulse` returns there at the end;
/// * `roll` rotates the visible state by `easing(p) * ledCount` positions,
///   interpolating between neighbours (`none` behaves as `linear`);
/// * `repeat` loops from line 1 using the state at the end of the previous
///   pass; after a finite count the lines after the marker play once and the
///   program holds its final state;
/// * `brightness N` is global (the last one wins) and scales the 8-bit output
///   with nearest rounding.
public final class LEDSSampler: Sendable {
    public let program: LEDSProgram
    public let ledCount: Int
    public let brightness: Int
    private let timeline: Timeline

    /// - Parameters:
    ///   - initialCodes: the colours the LEDs were showing (before brightness)
    ///     when this program was parsed; the firmware starts the first line's
    ///     transitions from them. Defaults to all off.
    public init(program: LEDSProgram, ledCount requestedLedCount: Int = 8, initialCodes: [RGB8]? = nil) {
        let ledCount = LEDSProgram.normalizedLedCount(requestedLedCount)
        self.program = program
        self.ledCount = ledCount
        self.brightness = program.brightness
        var initial = initialCodes ?? []
        if initial.count < ledCount { initial += Array(repeating: RGB8.black, count: ledCount - initial.count) }
        if initial.count > ledCount { initial = Array(initial.prefix(ledCount)) }
        self.timeline = Timeline(program: program, ledCount: ledCount, initial: initial)
    }

    /// The exact 8-bit output at `milliseconds` after the parse (after brightness).
    public func codes(atMilliseconds milliseconds: Int) -> [RGB8] {
        let raw = rawCodes(atMilliseconds: milliseconds)
        if brightness == LEDSLimits.maxBrightness { return raw }
        let scale = Double(brightness) / 255.0
        return raw.map { code in
            RGB8(
                r: UInt8((Double(code.r) * scale).rounded()),
                g: UInt8((Double(code.g) * scale).rounded()),
                b: UInt8((Double(code.b) * scale).rounded())
            )
        }
    }

    /// The stored LED state before brightness; what the next program starts from.
    public func rawCodes(atMilliseconds milliseconds: Int) -> [RGB8] {
        timeline.codes(at: max(0, milliseconds))
    }

    /// Float colours in 0...1 (codes / 255) at `seconds` after the parse.
    public func colors(at seconds: Double) -> [RGB] {
        codes(atMilliseconds: Int((seconds * 1000.0).rounded(.down))).map(\.rgb)
    }

    /// Length in seconds of the section that repeats, or nil when nothing repeats.
    public var cycleDuration: TimeInterval? {
        timeline.hasRepeat ? Double(timeline.loopSpan) / 1000.0 : nil
    }

    /// Seconds after which the output never changes again, or nil when it loops forever.
    public var motionEndsAt: TimeInterval? {
        timeline.motionEndsAtMs.map { Double($0) / 1000.0 }
    }

    /// True when the output never changes after the first frame.
    public var isStatic: Bool { timeline.motionEndsAtMs == 0 }
}

// MARK: - Timeline

struct ResolvedTarget: Sendable {
    let target: RGB8
    let durationMs: Int
    let delayMs: Int
    let easing: LEDSEasing

    /// The firmware's defaults for a colour segment.
    init(target: RGB8, timing: LEDSTiming) {
        self.target = target
        self.delayMs = timing.delayMs ?? 0
        if let duration = timing.durationMs {
            self.durationMs = duration
            self.easing = timing.easing ?? .ease
        } else if let easing = timing.easing {
            self.durationMs = LEDSLimits.defaultEasingDurationMs
            self.easing = easing
        } else {
            self.durationMs = 0
            self.easing = .none
        }
    }

    var isInstant: Bool { durationMs == 0 || easing == .none }
    var spanMs: Int { delayMs + durationMs }
    /// The last instant this target can still change the LED.
    var motionEndMs: Int { delayMs + (isInstant ? 0 : durationMs) }

    func value(from start: RGB8, at tau: Int) -> RGB8 {
        let elapsed = tau - delayMs
        if elapsed < 0 { return start }
        if isInstant { return target }
        let p = min(1.0, Double(elapsed) / Double(durationMs))
        let f = easing.value(p)
        return RGB8(
            r: Timeline.mix(start.r, target.r, f),
            g: Timeline.mix(start.g, target.g, f),
            b: Timeline.mix(start.b, target.b, f)
        )
    }
}

enum CompiledLine: Sendable {
    case paint(targets: [ResolvedTarget?], spanMs: Int)
    case roll(durationMs: Int, direction: LEDSRollDirection, easing: LEDSEasing)

    var spanMs: Int {
        switch self {
        case .paint(_, let span): return span
        case .roll(let duration, _, _): return duration
        }
    }

    var motionEndMs: Int {
        switch self {
        case .paint(let targets, _):
            return targets.compactMap { $0?.motionEndMs }.max() ?? 0
        case .roll(let duration, _, _):
            return duration
        }
    }

    func value(from start: [RGB8], at tau: Int) -> [RGB8] {
        switch self {
        case .paint(let targets, _):
            var out = start
            for index in out.indices {
                if let target = targets[index] { out[index] = target.value(from: start[index], at: tau) }
            }
            return out
        case .roll(let duration, let direction, let easing):
            let n = start.count
            guard n > 0, duration > 0 else { return start }
            let p = min(1.0, Double(tau) / Double(duration))
            var shift = easing.value(p) * Double(n)
            if shift >= Double(n) { shift = 0 }
            var out = start
            for index in 0..<n {
                let position = direction == .right ? Double(index) - shift : Double(index) + shift
                let floorPosition = position.rounded(.down)
                let fraction = position - floorPosition
                let base = Int(floorPosition)
                let a = start[Timeline.wrap(base, n)]
                let b = start[Timeline.wrap(base + 1, n)]
                out[index] = RGB8(
                    r: Timeline.mix(a.r, b.r, fraction),
                    g: Timeline.mix(a.g, b.g, fraction),
                    b: Timeline.mix(a.b, b.b, fraction)
                )
            }
            return out
        }
    }

    func endState(from start: [RGB8]) -> [RGB8] { value(from: start, at: spanMs) }
}

/// One pass over a list of lines from a known starting state.
struct Pass: Sendable {
    let lines: [CompiledLine]
    let offsets: [Int]
    let starts: [[RGB8]]
    let end: [RGB8]
    let span: Int

    init(lines: [CompiledLine], from initial: [RGB8]) {
        var offsets: [Int] = []
        var starts: [[RGB8]] = []
        var state = initial
        var clock = 0
        for line in lines {
            offsets.append(clock)
            starts.append(state)
            state = line.endState(from: state)
            clock += line.spanMs
        }
        self.lines = lines
        self.offsets = offsets
        self.starts = starts
        self.end = state
        self.span = clock
    }

    /// The last instant this pass can change the output.
    var motionEnd: Int {
        guard let last = lines.indices.last else { return 0 }
        return offsets[last] + lines[last].motionEndMs
    }

    func codes(at local: Int) -> [RGB8] {
        if local >= span { return end }
        // Lines are few (<= 20); a linear scan beats anything cleverer.
        var index = lines.count - 1
        while index > 0, offsets[index] > local { index -= 1 }
        // Skip zero-span lines that start exactly here in favour of the one that runs.
        while index + 1 < lines.count, offsets[index + 1] <= local { index += 1 }
        return lines[index].value(from: starts[index], at: local - offsets[index])
    }
}

struct Timeline: Sendable {
    let ledCount: Int
    let hasRepeat: Bool
    /// nil = forever (only meaningful when `hasRepeat`).
    let repeatCount: Int?
    let first: Pass
    let steady: Pass?
    let tail: Pass
    let loopSpan: Int

    init(program: LEDSProgram, ledCount: Int, initial: [RGB8]) {
        self.ledCount = ledCount
        var loopLines: [CompiledLine] = []
        var tailLines: [CompiledLine] = []
        var repeatCount: Int? = nil
        var sawRepeat = false
        for step in program.steps {
            switch step {
            case .repeat(let count):
                if !sawRepeat {
                    sawRepeat = true
                    repeatCount = count
                }
            case .paint(let segments):
                let line = Timeline.compilePaint(segments, ledCount: ledCount)
                if sawRepeat { tailLines.append(line) } else { loopLines.append(line) }
            case .roll(let roll):
                var easing = roll.easing ?? .linear
                if easing == .none { easing = .linear }
                let line = CompiledLine.roll(durationMs: max(0, roll.durationMs), direction: roll.direction, easing: easing)
                if sawRepeat { tailLines.append(line) } else { loopLines.append(line) }
            case .brightness, .comment:
                break
            }
        }
        self.hasRepeat = sawRepeat
        self.repeatCount = repeatCount
        let first = Pass(lines: loopLines, from: initial)
        self.first = first
        self.loopSpan = first.span
        let steady = sawRepeat ? Pass(lines: loopLines, from: first.end) : nil
        self.steady = steady
        let afterLoops: [RGB8]
        if sawRepeat, let count = repeatCount, count <= 1 {
            afterLoops = first.end
        } else if let steady {
            afterLoops = steady.end
        } else {
            afterLoops = first.end
        }
        self.tail = Pass(lines: tailLines, from: afterLoops)
    }

    static func compilePaint(_ segments: [LEDSSegment], ledCount: Int) -> CompiledLine {
        var targets = [ResolvedTarget?](repeating: nil, count: ledCount)
        for segment in segments {
            switch segment.kind {
            case .wholeBar(let color):
                let resolved = ResolvedTarget(target: color ?? .black, timing: segment.timing)
                for index in 0..<ledCount { targets[index] = resolved }
            case .colorList(let colors):
                for index in 0..<ledCount {
                    let color = index < colors.count ? colors[index] : RGB8.black
                    targets[index] = ResolvedTarget(target: color, timing: segment.timing)
                }
            case .indexed(let assignments):
                for assignment in assignments where assignment.index < ledCount {
                    targets[assignment.index] = ResolvedTarget(target: assignment.color, timing: segment.timing)
                }
            }
        }
        let hasTargets = targets.contains { $0 != nil }
        var span = targets.compactMap { $0?.spanMs }.max() ?? 0
        if hasTargets, span == 0 { span = LEDSLimits.frameMs }
        return .paint(targets: targets, spanMs: span)
    }

    /// Milliseconds after which the output is constant, nil when it never is.
    var motionEndsAtMs: Int? {
        if !hasRepeat { return first.motionEnd }
        if loopSpan == 0 { return tail.lines.isEmpty ? 0 : tail.motionEnd }
        guard let count = repeatCount else { return nil }
        let loopsEnd = loopSpan * count
        return tail.lines.isEmpty ? loopsEnd : loopsEnd + tail.motionEnd
    }

    func codes(at ms: Int) -> [RGB8] {
        if !hasRepeat { return first.codes(at: ms) }
        if loopSpan == 0 { return tail.codes(at: ms) }
        if ms < loopSpan { return first.codes(at: ms) }
        guard let steady else { return first.codes(at: ms) }
        if let count = repeatCount {
            let loopsEnd = loopSpan * count
            if ms >= loopsEnd { return tail.codes(at: ms - loopsEnd) }
        }
        return steady.codes(at: (ms - loopSpan) % loopSpan)
    }

    /// `a + (b - a) * f` the way the firmware rounds it: the delta's magnitude
    /// is rounded to nearest with exact halves going toward zero (measured:
    /// red 255->0 at f = 0.5 gives 128, blue 0->255 gives 127).
    @inline(__always)
    static func mix(_ a: UInt8, _ b: UInt8, _ f: Double) -> UInt8 {
        let delta = Double(b) - Double(a)
        let magnitude = (abs(delta) * f - 0.5).rounded(.up)
        let value = Double(a) + (delta < 0 ? -magnitude : magnitude)
        return UInt8(max(0.0, min(255.0, value)))
    }

    @inline(__always)
    static func wrap(_ index: Int, _ n: Int) -> Int {
        let m = index % n
        return m < 0 ? m + n : m
    }
}
