import Foundation

/// A sampled stretch of a program: keyframe offsets in milliseconds and the
/// exact firmware codes at each, meant to be handed to an animation engine
/// that interpolates linearly between them (Core Animation on the Screen Bar).
///
/// Between two keyframes the true firmware curve is approximated by a straight
/// line; at the keyframes themselves the values are the sampler's, exactly.
public struct LEDSKeyframeTrack: Sendable, Equatable {
    /// Ascending, the first is 0, the last is `durationMs`.
    public let offsetsMs: [Int]
    /// One entry per offset, `ledCount` codes each (after brightness).
    public let frames: [[RGB8]]

    public init(offsetsMs: [Int], frames: [[RGB8]]) {
        precondition(offsetsMs.count == frames.count && !offsetsMs.isEmpty)
        self.offsetsMs = offsetsMs
        self.frames = frames
    }

    public var durationMs: Int { offsetsMs[offsetsMs.count - 1] }
    public var count: Int { offsetsMs.count }

    /// The keyframe offsets as fractions of the duration, for `keyTimes`.
    public var keyTimes: [Double] {
        let span = Double(max(1, durationMs))
        return offsetsMs.map { Double($0) / span }
    }

    /// Linear interpolation between the neighbouring keyframes, clamped to
    /// the track. This is what the animation engine shows.
    public func codes(atMilliseconds t: Int) -> [RGB8] {
        if t <= offsetsMs[0] { return frames[0] }
        if t >= durationMs { return frames[frames.count - 1] }
        // Binary search for the last keyframe at or before t.
        var low = 0
        var high = offsetsMs.count - 1
        while high - low > 1 {
            let mid = (low + high) / 2
            if offsetsMs[mid] <= t { low = mid } else { high = mid }
        }
        let t0 = offsetsMs[low]
        let t1 = offsetsMs[high]
        if t1 == t0 { return frames[high] }
        let f = Double(t - t0) / Double(t1 - t0)
        return Self.mix(frames[low], frames[high], f)
    }

    static func mix(_ a: [RGB8], _ b: [RGB8], _ f: Double) -> [RGB8] {
        zip(a, b).map { x, y in
            RGB8(r: channel(x.r, y.r, f), g: channel(x.g, y.g, f), b: channel(x.b, y.b, f))
        }
    }

    @inline(__always)
    private static func channel(_ a: UInt8, _ b: UInt8, _ f: Double) -> UInt8 {
        UInt8(max(0.0, min(255.0, (Double(a) + (Double(b) - Double(a)) * f).rounded())))
    }
}

/// A whole program rendered as keyframe tracks: the first pass from the
/// colours the strip was showing (`lead`), then one steady cycle that repeats
/// forever (`loop`), or a final state when the program comes to rest.
///
/// Built once per program change so the display can hand the animation to the
/// render server and idle; `codes(atMilliseconds:)` reproduces what that
/// animation shows, for tests and for anything that needs a frame on the CPU.
public struct LEDSKeyframePlan: Sendable, Equatable {
    /// Frames from t = 0 until the loop starts or motion ends; nil when the
    /// program is static from its first frame.
    public let lead: LEDSKeyframeTrack?
    /// One steady cycle, played from `loopStartMs` forever; nil when the
    /// program comes to rest.
    public let loop: LEDSKeyframeTrack?
    public let loopStartMs: Int
    /// What the program shows once motion has ended (also the lead's last frame).
    public let finalCodes: [RGB8]

    /// How far, in codes on any channel, the straight line between two
    /// keyframes may stray from the firmware's curve before another keyframe
    /// goes in between (Douglas-Peucker over every millisecond). Eases end up
    /// with a handful of segments, linear ramps and holds with two points,
    /// and a jump (`none`, a `0ms` line, a loop seam) with a frame on each side.
    public static let defaultTolerance = 3
    /// A plan bigger than this is not worth shipping to the render server;
    /// callers fall back to sampling on a frame clock.
    public static let defaultMaxKeyframes = 900
    /// The longest stretch sampled at all.
    public static let maxScanMs = 120_000

    public init(lead: LEDSKeyframeTrack?, loop: LEDSKeyframeTrack?, loopStartMs: Int, finalCodes: [RGB8]) {
        self.lead = lead
        self.loop = loop
        self.loopStartMs = loopStartMs
        self.finalCodes = finalCodes
    }

    public var isStatic: Bool { lead == nil && loop == nil }
    public var loopSpanMs: Int { loop?.durationMs ?? 0 }
    public var keyframeCount: Int { (lead?.count ?? 0) + (loop?.count ?? 0) }

    /// Renders `sampler` into tracks, or nil when the program is too long to
    /// keyframe (the caller keeps its frame clock).
    public static func render(sampler: LEDSSampler, tolerance: Int = defaultTolerance, maxKeyframes: Int = defaultMaxKeyframes) -> LEDSKeyframePlan? {
        let loopSpan = sampler.cycleDuration.map { Int(($0 * 1000).rounded()) }
        if let end = sampler.motionEndsAt {
            let endMs = Int((end * 1000).rounded())
            let final = sampler.codes(atMilliseconds: max(endMs, 0))
            if endMs <= 0 { return LEDSKeyframePlan(lead: nil, loop: nil, loopStartMs: 0, finalCodes: final) }
            guard endMs <= maxScanMs else { return nil }
            let lead = track(sampler: sampler, from: 0, to: endMs, tolerance: tolerance, maxKeyframes: maxKeyframes)
            guard lead.count <= maxKeyframes else { return nil }
            return LEDSKeyframePlan(lead: lead, loop: nil, loopStartMs: 0, finalCodes: final)
        }
        guard let loopSpan, loopSpan > 0, loopSpan <= maxScanMs / 2 else { return nil }
        let budget = max(2, maxKeyframes / 2)
        let lead = track(sampler: sampler, from: 0, to: loopSpan, tolerance: tolerance, maxKeyframes: budget)
        let loop = track(sampler: sampler, from: loopSpan, to: 2 * loopSpan, tolerance: tolerance, maxKeyframes: budget)
        guard lead.count + loop.count <= maxKeyframes else { return nil }
        return LEDSKeyframePlan(lead: lead, loop: loop, loopStartMs: loopSpan, finalCodes: loop.frames[0])
    }

    /// What the animation shows at `t` milliseconds after the program started.
    public func codes(atMilliseconds t: Int) -> [RGB8] {
        let t = max(0, t)
        if let loop, t >= loopStartMs {
            return loop.codes(atMilliseconds: (t - loopStartMs) % max(1, loop.durationMs))
        }
        if let lead { return lead.codes(atMilliseconds: t) }
        return finalCodes
    }

    // MARK: Sampling

    /// Samples every millisecond of `[start, end]` and keeps the fewest
    /// keyframes whose straight lines stay within `tolerance` of them
    /// (Douglas-Peucker). Past `maxKeyframes` the tolerance doubles and the
    /// pass runs again, so a busy program degrades smoothly rather than
    /// exploding; the caller still checks the final count.
    static func track(sampler: LEDSSampler, from start: Int, to end: Int, tolerance: Int, maxKeyframes: Int) -> LEDSKeyframeTrack {
        precondition(end > start)
        let frames = (start...end).map { sampler.codes(atMilliseconds: $0) }
        var epsilon = max(0, tolerance)
        var kept = simplify(frames: frames, tolerance: epsilon)
        while kept.count > maxKeyframes, epsilon < 64 {
            epsilon = max(1, epsilon * 2)
            kept = simplify(frames: frames, tolerance: epsilon)
        }
        return LEDSKeyframeTrack(offsetsMs: kept, frames: kept.map { frames[$0] })
    }

    /// Indices into `frames` (one per millisecond) to keep.
    static func simplify(frames: [[RGB8]], tolerance: Int) -> [Int] {
        let n = frames.count
        guard n > 2 else { return Array(0..<n) }
        var keep = [Bool](repeating: false, count: n)
        keep[0] = true
        keep[n - 1] = true
        var stack: [(Int, Int)] = [(0, n - 1)]
        while let (a, b) = stack.popLast() {
            guard b - a > 1 else { continue }
            var worst = 0
            var worstIndex = -1
            let span = Double(b - a)
            for k in (a + 1)..<b {
                let f = Double(k - a) / span
                let deviation = maxDeviation(frames[k], from: frames[a], to: frames[b], f: f)
                if deviation > worst { worst = deviation; worstIndex = k }
            }
            if worst > tolerance, worstIndex > 0 {
                keep[worstIndex] = true
                stack.append((a, worstIndex))
                stack.append((worstIndex, b))
            }
        }
        return keep.indices.filter { keep[$0] }
    }

    /// The largest channel gap between `frame` and the point `f` of the way
    /// along the straight line from `a` to `b`, rounded to the nearest code
    /// (what the interpolated 8-bit value would be off by).
    @inline(__always)
    static func maxDeviation(_ frame: [RGB8], from a: [RGB8], to b: [RGB8], f: Double) -> Int {
        var worst = 0.0
        for index in frame.indices {
            let x = a[index], y = b[index], z = frame[index]
            worst = max(worst, abs(Double(x.r) + (Double(y.r) - Double(x.r)) * f - Double(z.r)))
            worst = max(worst, abs(Double(x.g) + (Double(y.g) - Double(x.g)) * f - Double(z.g)))
            worst = max(worst, abs(Double(x.b) + (Double(y.b) - Double(x.b)) * f - Double(z.b)))
        }
        return Int(worst.rounded(.toNearestOrAwayFromZero))
    }

    static func maxDifference(_ a: [RGB8], _ b: [RGB8]) -> Int {
        var worst = 0
        for (x, y) in zip(a, b) {
            worst = max(worst, abs(Int(x.r) - Int(y.r)), abs(Int(x.g) - Int(y.g)), abs(Int(x.b) - Int(y.b)))
        }
        return worst
    }
}
