import CoreGraphics
import Foundation
import JRBarCore

/// The Portal fold's pure model — every rule the renderer and toy
/// follow, with no Metal, no HID and no timers in the way, so the whole
/// thing is testable from `JRBarAppTests` (docs/TOYS.md, docs/TOY-PARITY.md
/// "Duo-style fold"). The lid's motion itself — the tracker, the spring,
/// the rest guard, the gate ease and the entry fade — is in
/// FoldMotion.swift. The pieces here:
///
/// - `MoveAnchor` — the movement-anchored reference: where the lid was
///   resting when the gesture began. Still for `settleAfter` while flat
///   and the rest spot becomes the anchor; a live fold freezes it until
///   the picture unwinds home, a reopen that stops short settles, or the
///   dwell pause re-seats it.
/// - `FoldArming` — the capture-lifecycle state machine. The
///   ScreenCaptureKit streams exist only inside the arming band
///   (activation + margin) in fixed-angle mode, or from the first move
///   off the anchor in movement mode; they linger through a short
///   cooldown so the Screen Recording indicator only shows while a fold
///   can actually be on screen, and die at once on a full close. It
///   also owns the fold gate's hysteresis at the activation edge.
/// - `PortalDepth` — window z-order → depth buckets and normalized card
///   rects for the shader's layered room.
/// - `FoldPortalModel` — the Room look's settings+delta → shader-params
///   mapping: the Perspective/Blur/Shade/Frost knobs, the activation-
///   edge opacity ramp and the dissolve to black over the last ~20° of
///   travel.
/// - `FoldDuoModel` — the Duo look: one picture held still in space
///   while the glass swings through it, softening and darkening away
///   from the hinge until a seated eye loses the glass.
/// - `FoldBlackout` — the Duo's closed-lid end: black held across the
///   closed-lid pause, so a reopen unfolds from black.

// MARK: - FoldFrameClock

/// The display link's elapsed time, kept between sensor and display
/// callbacks so each moves the motion by only the time since the last.
struct FoldFrameClock: Sendable {
    private var previous: TimeInterval?

    mutating func tick(at now: TimeInterval) -> TimeInterval {
        let elapsed = previous.map { now - $0 } ?? 0
        previous = now
        return elapsed
    }

    mutating func reset() { previous = nil }
}

// MARK: - MoveAnchor

/// The movement-anchored reference (FoldAnchor.movement): where the lid
/// was resting when the gesture began.
///
/// The reference stays fixed while the lid moves. Above it, a stable
/// reading re-seats after `settleAfter`. Below it, `parkAfter` can seat
/// a held lid too; otherwise the caller's parking timer owns that release.
///
/// A reopen that stops short of the old rest is a rest too: once the lid
/// has come back up more than `reopenRise` from the lowest point of the
/// close and holds still for `reopenSettleAfter`, that spot becomes the
/// anchor. Without it a lid that rested at 110°, dipped to 80° and came
/// back to 104° kept a 6° fold on screen, and the capture running, until
/// it was opened past 107°. A lid parked mid-close with no rise keeps
/// its fold.
struct MoveAnchor: Sendable {
    private var selectedMode: FoldAnchor?
    /// The reference angle a fold measures from. nil until the first
    /// real sample seats it.
    private(set) var anchor: Double?
    /// Where the lid last rested in the flat zone.
    private var restAngle: Double?
    /// When the current rest spot was entered.
    private var restAt: TimeInterval = 0

    /// Seconds of stillness in the flat zone before the rest spot
    /// re-seats the anchor — long enough that the sensor's own 100 ms
    /// cadence can't do it mid-gesture.
    var settleAfter: TimeInterval = 0.4
    /// The stillness deadband in degrees — the sensor's jitter window.
    var tolerance = 1.5
    /// How far off the anchor counts as a real move — what arms the
    /// capture. nil uses `tolerance`, either way off the anchor. The toy
    /// sets half a degree in both looks and counts only a move down: a
    /// parked lid's whole-degree flicker is absorbed into the anchor and
    /// so never reaches it, the second whole degree of a close does, and
    /// tilting the screen back, which has nothing to fold, never does.
    var armThreshold: Double?
    /// How far below the anchor counts as folded: past this the
    /// reference freezes until the lid returns.
    var flightMargin = 3.0
    /// Seconds a reopen must hold still, short of the old rest, before
    /// it becomes the new anchor — longer than the flat zone's settle,
    /// so a person pausing on the way back up still sees the fold follow.
    var reopenSettleAfter: TimeInterval = 1.0
    /// The low point of the close in flight, and the highest the lid has
    /// come back up since; nil while flat.
    private var flightLow: Double?
    private var flightHigh: Double?
    var parkAfter: TimeInterval?
    private var parkRange: ClosedRange<Double>?
    private var parkAt: TimeInterval = 0
    private var parkEarlyTotal = 0.0
    private var parkEarlyCount = 0
    private var parkLateTotal = 0.0
    private var parkLateCount = 0

    /// How far back up from the close's lowest point counts as a reopen
    /// rather than sensor wobble on a parked lid: the flight margin, or
    /// the whole jitter window when that is wider.
    var reopenRise: Double { max(flightMargin, 2 * tolerance) }

    init() {}

    mutating func reset() { self = MoveAnchor() }

    /// A mode change starts from the current reading, before the next
    /// closing sample can be mistaken for the lid's resting angle.
    @discardableResult
    mutating func select(_ mode: FoldAnchor, angle: Double?, at: TimeInterval) -> Bool {
        guard selectedMode != mode else { return false }
        selectedMode = mode
        anchor = nil
        restAngle = nil
        flightLow = nil
        flightHigh = nil
        parkRange = nil
        if mode == .movement, let angle { reseat(angle, at: at) }
        return true
    }

    /// Returns true when a held lid becomes the next resting angle.
    @discardableResult
    mutating func feed(_ angle: Double, at: TimeInterval) -> Bool {
        guard angle.isFinite, at.isFinite else { return false }
        guard let a = anchor else {
            anchor = angle
            restAngle = angle
            restAt = at
            return false
        }
        if a - angle > flightMargin {
            if let parkAfter, notePark(angle, at: at, after: parkAfter) {
                reseat(angle, at: at)
                return true
            }
            feedInFlight(angle, at: at)
            return false
        }
        parkRange = nil
        flightLow = nil
        flightHigh = nil
        if let r = restAngle, abs(angle - r) <= tolerance {
            if at - restAt >= settleAfter { anchor = angle }
        } else {
            restAngle = angle
            restAt = at
        }
        return false
    }

    /// A real deviation from the anchor — what arms the capture in
    /// movement mode. A held fold counts as moving (the streams must
    /// stay); parked at rest does not. With `armThreshold` set only a
    /// move down counts; a reopen back through the anchor keeps its
    /// streams through the arming cooldown.
    func moving(_ angle: Double) -> Bool {
        guard angle.isFinite, let a = anchor else { return false }
        if let threshold = armThreshold { return a - angle > threshold }
        return abs(angle - a) > tolerance
    }

    /// Seat the anchor directly — the dwell pause hands the desktop
    /// back and the parked angle becomes the new reference.
    mutating func reseat(_ angle: Double, at: TimeInterval) {
        guard angle.isFinite, at.isFinite else { return }
        anchor = angle
        restAngle = angle
        restAt = at
        flightLow = nil
        flightHigh = nil
        parkRange = nil
    }

    private mutating func notePark(_ angle: Double, at: TimeInterval, after delay: TimeInterval) -> Bool {
        guard let range = parkRange else {
            beginPark(angle, at: at)
            return false
        }
        let low = min(range.lowerBound, angle)
        let high = max(range.upperBound, angle)
        if high - low > max(2, 2 * tolerance) {
            beginPark(angle, at: at)
            return false
        }
        parkRange = low...high
        let elapsed = at - parkAt
        if elapsed < delay / 2 {
            parkEarlyTotal += angle
            parkEarlyCount += 1
        } else {
            parkLateTotal += angle
            parkLateCount += 1
        }
        guard elapsed >= delay else { return false }
        let early = parkEarlyTotal / Double(parkEarlyCount)
        let late = parkLateTotal / Double(parkLateCount)
        guard high - low > 1, abs(late - early) > max(0.75, tolerance / 2) else { return true }
        beginPark(angle, at: at)
        return false
    }

    private mutating func beginPark(_ angle: Double, at: TimeInterval) {
        parkRange = angle...angle
        parkAt = at
        parkEarlyTotal = angle
        parkEarlyCount = 1
        parkLateTotal = 0
        parkLateCount = 0
    }

    /// A sample below the anchor. Parked with no rise the rest clock
    /// restarts every time, so the fold holds and a return to flat still
    /// owes its own settle; back up past `reopenRise` from the low point,
    /// stillness counts, and after `reopenSettleAfter` the lid's new spot
    /// is the anchor. Closing again by more than `reopenRise` starts a
    /// new low, so a lid that comes part way up and goes back down to
    /// park keeps its fold.
    private mutating func feedInFlight(_ angle: Double, at: TimeInterval) {
        var low = min(flightLow ?? angle, angle)
        var high = max(flightHigh ?? angle, angle)
        if angle == low || high - angle > reopenRise {
            low = angle
            high = angle
        }
        flightLow = low
        flightHigh = high
        let reopened = angle - low > reopenRise
        if reopened, let r = restAngle, abs(angle - r) <= tolerance {
            if at - restAt >= reopenSettleAfter { reseat(angle, at: at) }
            return
        }
        restAngle = angle
        restAt = at
    }
}

// MARK: - FoldArming

/// The capture-lifecycle state machine: when the ScreenCaptureKit
/// streams may exist, and whether the fold gate is open.
///
/// Streams start only once the lid enters the arming band — the
/// activation angle plus `margin` — so the purple Screen Recording
/// indicator shows only while a fold can actually be on screen. Leaving
/// the band starts a `cooldown` countdown instead of cutting the stream
/// at once (a lid hovering near the band edge must not flap the
/// indicator); a real close below `closedAngle` or the daemon's
/// clamshell truth stops it immediately. The fold gate itself gets
/// `hysteresis`: it opens at `activation` and won't close again until
/// the lid is a degree past it, so a sensor wobble on the line can
/// never flick the overlay.
struct FoldArming: Sendable {
    enum Phase: Equatable, Sendable {
        /// No streams, nothing captured.
        case idle
        /// Inside the band — both streams live.
        case armed
        /// Left the band upward; streams linger until the timestamp so a
        /// re-entry never pays a capture restart.
        case cooling(until: TimeInterval)
    }

    private(set) var phase: Phase = .idle
    /// The activation-edge gate with hysteresis applied.
    private(set) var foldGateOpen = false

    /// Band half-height above the activation angle — matches the
    /// sensor's own polling-band margin.
    var margin = 12.0
    /// Seconds the streams linger after the lid leaves the band.
    var cooldown = 2.0
    /// Degrees past activation the lid must reach before the gate shuts.
    var hysteresis = 1.0
    /// At or under this the lid counts as closed — streams die at once.
    var closedAngle = FoldPause.closedAngle

    struct Outcome: Equatable, Sendable {
        /// Both capture streams should exist.
        var capture = false
        /// The fold gate (activation edge, with hysteresis) is open.
        var foldGate = false
        /// When a cooling phase expires, so the owner can schedule the
        /// shutdown check rather than polling it.
        var cooldownEndsAt: TimeInterval? = nil
    }

    init() {}

    mutating func reset() { self = FoldArming() }

    /// Evaluate the machine. `angle` is the freshest raw reading (or the
    /// simulation while held); `closed` is the daemon's clamshell truth;
    /// `now` is host seconds.
    @discardableResult
    mutating func update(angle: Double?, activation: Double, closed: Bool,
                         now: TimeInterval) -> Outcome {
        let lidShut = closed || (angle.map { $0 <= closedAngle } ?? false)
        guard let a = angle, a.isFinite, !lidShut else {
            // A full close — or a sensor with nothing to say — stops the
            // streams immediately; the indicator never outlives the lid.
            phase = .idle
            foldGateOpen = false
            return Outcome()
        }
        if a <= activation + margin {
            phase = .armed
        } else {
            switch phase {
            case .armed:
                phase = .cooling(until: now + cooldown)
            case .cooling(let until) where now >= until:
                phase = .idle
            default:
                break
            }
        }
        if a <= activation {
            foldGateOpen = true
        } else if a > activation + hysteresis {
            foldGateOpen = false
        }
        var cooldownEndsAt: TimeInterval?
        if case .cooling(let until) = phase { cooldownEndsAt = until }
        return Outcome(capture: phase != .idle, foldGate: foldGateOpen,
                       cooldownEndsAt: cooldownEndsAt)
    }

    /// The movement-anchored evaluation: there is no fixed activation
    /// angle, so the streams arm on the first real move off the
    /// `MoveAnchor` instead of on crossing the band. `moving` is the
    /// toy's deviation-from-anchor read — a held fold stays "moving"
    /// (the capture must live while the fold does), a parked lid goes
    /// still and cools down, and the same `cooldown`/`closedAngle`
    /// rules apply. The gate is open whenever capture is: the delta's
    /// own positive-only math holds it at zero above the anchor.
    @discardableResult
    mutating func updateMovement(moving: Bool, closed: Bool,
                                 now: TimeInterval) -> Outcome {
        guard !closed else {
            phase = .idle
            foldGateOpen = false
            return Outcome()
        }
        if moving {
            phase = .armed
            foldGateOpen = true
        } else {
            switch phase {
            case .armed:
                phase = .cooling(until: now + cooldown)
            case .cooling(let until) where now >= until:
                phase = .idle
                foldGateOpen = false
            case .idle:
                foldGateOpen = false
            default:
                break
            }
        }
        var cooldownEndsAt: TimeInterval?
        if case .cooling(let until) = phase { cooldownEndsAt = until }
        return Outcome(capture: phase != .idle, foldGate: foldGateOpen,
                       cooldownEndsAt: cooldownEndsAt)
    }
}

// MARK: - PortalDepth

/// Window z-order → depth buckets and card rects.
///
/// The Portal room is a stack of planes parallel to the screen hanging
/// off the hinge: the wallpaper is the far wall and each captured
/// window is a card floating in front of it at its own depth. Cards are
/// punched into one alpha texture per depth bucket, so the whole room
/// composites in a single fullscreen pass and the per-frame cost is a
/// handful of blit copies — capped at `maxWindows` cards so the render
/// stays under its frame budget no matter how busy the desktop is.
enum PortalDepth {
    /// Alpha-punched textures, nearest first — each is a texture, a
    /// blit pass and a shader sample, so the count stays small.
    static let bucketCount = 3
    /// Bucket depths as a fraction of the room depth, nearest first.
    static let bucketFractions: [Double] = [0.18, 0.5, 0.85]
    /// How many on-screen windows become cards. Windows past this sit on
    /// the far wall — the room stays readable and the render stays cheap.
    static let maxWindows = 12
    /// Windows smaller than this aren't worth a card of their own.
    static let minWindowSize = 24.0

    /// A window card: the window's rect in display-normalized uv (origin
    /// top-left, y down — the captured texture's own space) and its
    /// depth bucket index.
    struct Card: Equatable, Sendable {
        var rect: CGRect
        var bucket: Int
    }

    /// The raw window-list facts, abstracted so the filter is testable
    /// without a window server. `rect` is Quartz points, global
    /// top-left origin — `CGWindowListCopyWindowInfo`'s own space.
    struct WindowInfo: Equatable, Sendable {
        var rect: CGRect
        var layer: Int
        var ownerPID: Int32
        var alpha: Double
    }

    /// The on-screen window list (front-to-back, the order
    /// `CGWindowListCopyWindowInfo(.optionOnScreenOnly)` returns) →
    /// display-local normalized rects. Normal windows only — layer 0 —
    /// so the menu bar, status items, Dock tiles and desktop elements
    /// stay on the far wall: chrome recedes, content floats. Our own
    /// windows are excluded so the fold can never see itself.
    static func cardRects(from windows: [WindowInfo], displayFrame: CGRect,
                          ownPID: Int32) -> [CGRect] {
        var rects: [CGRect] = []
        for w in windows where rects.count < maxWindows {
            guard w.layer == 0, w.ownerPID != ownPID, w.alpha > 0.01 else { continue }
            let clipped = w.rect.intersection(displayFrame)
            guard !clipped.isNull, !clipped.isEmpty,
                  clipped.width >= minWindowSize, clipped.height >= minWindowSize
            else { continue }
            rects.append(CGRect(
                x: (clipped.minX - displayFrame.minX) / displayFrame.width,
                y: (clipped.minY - displayFrame.minY) / displayFrame.height,
                width: clipped.width / displayFrame.width,
                height: clipped.height / displayFrame.height))
        }
        return rects
    }

    /// z-order → bucket. The frontmost windows sit nearest the glass;
    /// the back of the list merges toward the far wall.
    static func cards(for rects: [CGRect]) -> [Card] {
        let n = min(rects.count, maxWindows)
        guard n > 0 else { return [] }
        return (0..<n).map { i in
            Card(rect: rects[i], bucket: min(bucketCount - 1, i * bucketCount / n))
        }
    }

    /// Bucket depths in screen heights for the shader's depth table.
    /// The unused lanes read 0 — the shader never samples past
    /// `bucketCount`.
    static func depths(roomDepth: Double) -> SIMD4<Float> {
        var d = SIMD4<Float>(0, 0, 0, 0)
        for i in 0..<bucketCount { d[i] = Float(bucketFractions[i] * roomDepth) }
        return d
    }
}

// MARK: - FoldPortalModel

/// The delta + settings → shader-params mapping, kept pure so the
/// Portal model's numbers are testable without a GPU.
enum FoldPortalModel {
    /// The stable arc, matching `FoldMath.deltaRadians`'s clamp — the
    /// dissolve is measured against it.
    static let maxDelta = 1.25
    /// Radians of delta over which the overlay fades in at the
    /// activation edge — the portal never pops.
    static let fadeSpan = 0.05
    /// The fraction of `maxDelta` where the dissolve to black begins —
    /// ~0.7 of 71.6° leaves the last ~20° for the fade-out.
    static let dissolveStart = 0.7
    /// The far wall's depth in screen heights.
    static let roomDepth = 0.45

    /// opacity is the activation-edge ramp; dissolve is the fade to
    /// black near full close. Both are pure functions of delta so the
    /// gesture reverses exactly.
    static func opacity(delta: Double) -> Double {
        min(1, max(0, delta / fadeSpan))
    }

    static func dissolve(delta: Double) -> Double {
        let t = min(1, max(0, (delta / maxDelta - dissolveStart) / (1 - dissolveStart)))
        return t * t * (3 - 2 * t)
    }

    /// The animatable uniform fields, written in place. The toy runs
    /// this every vsync tick; writing only the animatable fields keeps
    /// the renderer-owned ones — `imageSize` and `texAspect` from the
    /// capture upload, `cover` and `aspect` from the encode — alive
    /// across ticks. (A wholesale `params = params(...)` reset them to
    /// the defaults every frame, which quietly broke the edge feather
    /// and the cover fit.)
    static func apply(to p: inout FoldRenderer.Params, delta: Double,
                      perspective: Double, blur: Double, shade: Double,
                      frost: Double, hold: Double = 1,
                      usedBuckets: Int, reduceMotion: Bool) {
        p.delta = Float(delta)
        p.persp = Float(min(1, max(0, perspective)))
        // The Hold slider, as it reads: 1 keeps the desktop where a
        // fixed eye saw it while the glass tilts over it, 0 glues the
        // picture to the lid. (It used to be `perspective` when on and
        // 0 when off, which the shader read backwards.)
        p.hold = Float(min(1, max(0, hold.isFinite ? hold : 1)))
        p.blurStrength = Float(min(1, max(0, blur)))
        p.dimStrength = Float(min(1, max(0, shade)))
        p.frost = Float(min(1, max(0, frost)))
        p.opacity = Float(opacity(delta: delta))
        p.dissolve = Float(dissolve(delta: delta))
        p.roomDepth = Float(roomDepth)
        p.depths = PortalDepth.depths(roomDepth: roomDepth)
        p.bucketCount = Float(min(usedBuckets, PortalDepth.bucketCount))
        p.mode = reduceMotion ? 1 : 0
    }

    /// The full parameter set for one frame. `usedBuckets` is how many
    /// depth buckets actually hold cards this frame — the shader skips
    /// the rest, so an empty desktop costs the far wall only.
    static func params(delta: Double, perspective: Double, blur: Double,
                       shade: Double, frost: Double, hold: Double = 1,
                       usedBuckets: Int, reduceMotion: Bool) -> FoldRenderer.Params {
        var p = FoldRenderer.Params()
        apply(to: &p, delta: delta, perspective: perspective, blur: blur,
              shade: shade, frost: frost, hold: hold,
              usedBuckets: usedBuckets, reduceMotion: reduceMotion)
        return p
    }
}

// MARK: - FoldDuoModel

/// The Duo look: the iPhone Duo's fold on a Mac lid (docs/TOYS.md §Fold).
///
/// The Duo keeps its picture fixed in space while the glass swings
/// through it. Here that picture is the desktop as a seated eye saw it
/// on the resting lid: every pixel of the moving glass shows the point
/// of the resting plane that lies behind it on a ray from the eye. Seen
/// from the seat the desktop neither moves nor shrinks; only the glass
/// silhouette drops. On the glass itself this is a stretch that grows
/// toward the top.
///
/// Away from the hinge the picture softens and darkens, measured in the
/// picture's own rows (e = 0 at the hinge row, 1 at the far edge): blur
/// σ grows as e^1.35, the hinge-side fifth never darkens, and the far
/// edge is black by half-closed. Both ride an eased `motion` with zero
/// slope at the start, so the first degrees look like nothing at all.
/// The whole glass fades to black as a seated eye loses it edge-on, so
/// the fold is black well before the closed-lid pause.
///
/// Units: one screen height H. The frame is the keyboard's side view —
/// forward toward the person, up from the deck — with the hinge at the
/// origin. The lid at angle θ runs along u(θ) = (cos θ, sin θ) and its
/// screen faces n(θ) = (sin θ, −cos θ). Angles in the API are degrees.
enum FoldDuoModel {
    /// The seated eye at the default Perspective: 2.6 H toward the
    /// person and 2.0 H up (about 51 cm and 39 cm on a 14-inch panel).
    static let baseEye = SIMD2<Double>(2.6, 2.0)
    /// σ at the far edge at full motion and Blur 1, in screen heights.
    /// 0.10 H is about the Duo's own softness; the default 0.6 sits a
    /// notch under it.
    static let blurScale = 0.10
    /// The darkening gain at Shade 1. The default 0.67 gives the Duo's
    /// "twice the transition": the far edge is black once motion ≥ 0.5.
    static let darkScale = 3.0
    /// The hinge-side share of the picture that never darkens.
    static let darkStart = 0.2
    /// The Duo's falloff exponent for blur and darkening alike.
    static let gamma = 1.35
    /// The end fade runs from black at edge-on + 2° to clear at + 22°.
    static let endFadeFrom = 2.0
    static let endFadeSpan = 20.0
    /// Degrees of travel over which the overlay fades in at the start.
    static let alphaSpan = 2.0
    /// Gaussian pyramid levels the renderer builds.
    static let pyramidLevels = 8
    /// Pyramid level L, read as a cubic B-spline, carries σ ≈ 0.82·2^L
    /// base pixels: the levels' own 5-tap binomials add (4^L − 1)/3 px²
    /// and the B-spline another 4^L/3.
    static let levelSigma = 0.82

    static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        guard edge1 != edge0 else { return x < edge0 ? 0 : 1 }
        let t = min(1, max(0, (x - edge0) / (edge1 - edge0)))
        return t * t * (3 - 2 * t)
    }

    static func radians(_ degrees: Double) -> Double { degrees * .pi / 180 }

    /// The eye for a Perspective (0…1): the default 0.6 is the seated
    /// eye; lower sits further back (flatter), higher leans in.
    static func eye(perspective: Double) -> SIMD2<Double> {
        let p = perspective.isFinite ? min(1, max(0, perspective)) : 0.6
        return baseEye * (1.6 - p)
    }

    /// The lid angle, in degrees, at which the eye sees the glass
    /// edge-on — below it the eye is behind the screen. 37.6° for the
    /// default eye.
    static func edgeOn(eye: SIMD2<Double>) -> Double {
        atan2(eye.y, eye.x) * 180 / .pi
    }

    /// The angle the glass is drawn as if it stood at: the real lid at a
    /// full hold, the resting lid (the identity) at 0.
    static func heldAngle(theta: Double, reference: Double, hold: Double) -> Double {
        let k = hold.isFinite ? min(1, max(0, hold)) : 1
        return reference - k * (reference - theta)
    }

    /// Where a panel pixel samples the picture. `x` is lateral from the
    /// screen's centre and `h` the height up the glass, both in screen
    /// heights; `u`/`v` are picture uv (v = 0 at the top, like the
    /// capture). Invalid when the eye is behind the glass or the resting
    /// plane — that pixel is black.
    struct Source: Equatable {
        var u: Double
        var v: Double
        var valid: Bool
    }

    static func source(x: Double, h: Double, theta: Double, reference: Double,
                       hold: Double, eye: SIMD2<Double>, aspect: Double) -> Source {
        let thE = radians(heldAngle(theta: theta, reference: reference, hold: hold))
        let th0 = radians(reference)
        let u0 = SIMD2<Double>(cos(th0), sin(th0))
        let n0 = SIMD2<Double>(sin(th0), -cos(th0))
        let nE = SIMD2<Double>(sin(thE), -cos(thE))
        let w = h * SIMD2<Double>(cos(thE), sin(thE))
        let en0 = (eye * n0).sum()
        let den = ((w - eye) * n0).sum()
        let valid = en0 > 0 && (eye * nE).sum() > 0 && den < -1e-4
        let t = valid ? -en0 / den : 1
        let hit = eye + t * (w - eye)
        return Source(u: t * x / aspect + 0.5, v: 1 - (hit * u0).sum(), valid: valid)
    }

    /// The eased transition, 0…1: smoothstep over `fadeLength` of the
    /// travel from the reference down to the closed line — zero slope at
    /// the start, done by half-closed at the default 0.55.
    static func motion(delta: Double, reference: Double, fadeLength: Double) -> Double {
        guard delta.isFinite, delta > 0 else { return 0 }
        let span = FoldSettings.clampFadeLength(fadeLength) * max(1, reference - FoldPause.closedAngle)
        return smoothstep(0, 1, delta / span)
    }

    /// Blur σ, in screen heights, at picture row `e`.
    static func sigma(e: Double, motion: Double, blur: Double) -> Double {
        let b = blur.isFinite ? min(1, max(0, blur)) : 0
        return blurScale * b * motion * pow(min(1, max(0, e)), gamma)
    }

    /// The darkening, 0…1, at picture row `e`.
    static func darkening(e: Double, motion: Double, shade: Double) -> Double {
        let g = min(1, max(0, (e - darkStart) / (1 - darkStart)))
        let gain = darkScale * (shade.isFinite ? min(1, max(0, shade)) : 0)
        return min(1, gain * motion * pow(g, gamma))
    }

    /// The fade to black as the seated eye loses the glass: 1 (black)
    /// at or under edge-on + 2°, 0 from edge-on + 22° up.
    static func endFade(theta: Double, eye: SIMD2<Double>) -> Double {
        let black = blackAngle(eye: eye)
        return 1 - smoothstep(black, black + endFadeSpan, theta)
    }

    /// The highest lid angle the end fade still draws all black:
    /// edge-on + 2°, 39.6° for the default eye.
    static func blackAngle(eye: SIMD2<Double>) -> Double {
        edgeOn(eye: eye) + endFadeFrom
    }

    /// Whether a lid resting at `reference` has a picture to fold: above
    /// the angle the end fade draws all black. At or below it the seated
    /// eye is behind the resting plane, every pixel is invalid, and the
    /// whole screen would go black the moment the overlay ordered in.
    static func foldsFrom(reference: Double, perspective: Double) -> Bool {
        guard reference.isFinite else { return false }
        return reference > blackAngle(eye: eye(perspective: perspective))
    }

    /// The reference a Duo frame draws from: taken when the overlay
    /// orders in and kept until it orders out, so one gesture draws from
    /// one lid even when the anchor moves under it — the dwell pause
    /// re-seats it at the parked angle while the fold is still unwinding.
    static func drawnReference(held: Double?, current: Double?, overlayVisible: Bool) -> Double? {
        if !overlayVisible || held == nil, let current { return current }
        return held
    }

    /// The overlay's own alpha over the first degrees of travel.
    static func alpha(delta: Double) -> Double {
        guard delta.isFinite else { return 0 }
        return min(1, max(0, delta / alphaSpan))
    }

    /// The pyramid level that carries `sigmaPixels` of blur.
    static func lod(sigmaPixels: Double, levels: Int = pyramidLevels) -> Double {
        let raw = log2(max(sigmaPixels, 1e-4) / levelSigma)
        return min(Double(max(1, levels) - 1), max(0, raw))
    }

    /// The Duo's uniforms, written in place every vsync tick; like the
    /// Room's `apply`, only the animatable fields — the upload's size and
    /// level count and the encode's aspect survive. Reduce Motion keeps
    /// the picture on the glass with no blur: it darkens only.
    static func apply(to p: inout FoldRenderer.Params, reference: Double, theta: Double,
                      hold: Double, perspective: Double, blur: Double, shade: Double,
                      fadeLength: Double, reduceMotion: Bool) {
        let delta = max(0, reference - theta)
        let e = eye(perspective: perspective)
        let m = motion(delta: delta, reference: reference, fadeLength: fadeLength)
        p.delta = Float(radians(delta))
        p.thetaRef = Float(radians(reference))
        p.theta = Float(radians(theta))
        p.eyeF = Float(e.x)
        p.eyeU = Float(e.y)
        p.hold = reduceMotion ? 0 : Float(hold.isFinite ? min(1, max(0, hold)) : 1)
        p.motion = Float(m)
        p.blurMax = reduceMotion ? 0 : Float(blurScale * (blur.isFinite ? min(1, max(0, blur)) : 0))
        p.darkGain = Float(darkScale * (shade.isFinite ? min(1, max(0, shade)) : 0))
        p.endFade = Float(endFade(theta: theta, eye: e))
        p.opacity = Float(alpha(delta: delta))
        p.blackout = 0
        p.mode = 0
    }

    /// The closed-lid hold: flat black, nothing sampled, fully opaque.
    static func applyBlackout(to p: inout FoldRenderer.Params) {
        p.blackout = 1
        p.opacity = 1
    }
}

// MARK: - FoldBlackout

/// The Duo's closed-lid hold. By the time the lid reaches the closed
/// line the Duo picture is already black; ordering the overlay out there
/// would flash the sharp desktop, and a reopen would pop straight to it.
/// So the overlay stays up as a flat black pass with capture stopped and
/// the last picture held in the renderer, and lets go on the first of:
/// `watchdog` seconds (restarted once when the lid reopens, so the
/// reopen gets its own time), the lid back past `releaseAngle` with a
/// picture in hand (the fold then follows the lid up out of black, from
/// the held picture, with no wait for a new capture), or anything that
/// means nobody is looking at this desktop — the owner checks sleep,
/// lock and session itself. It never draws above the lock screen and
/// never uses private spaces.
struct FoldBlackout: Sendable {
    static let watchdog: TimeInterval = 3
    /// 10° above the closed line.
    static let releaseAngle = FoldPause.closedAngle + 10

    private(set) var active = false
    /// When the hold lets go on its own.
    private(set) var deadline: TimeInterval = 0
    private var reopened = false

    init() {}

    /// Start holding black at `now`; a no-op while already holding.
    mutating func hold(at now: TimeInterval) {
        guard !active else { return }
        active = true
        reopened = false
        deadline = now + Self.watchdog
    }

    /// A lid reading while holding: the first one above the closed line
    /// restarts the watchdog, once.
    mutating func note(angle: Double?, at now: TimeInterval) {
        guard active, !reopened, let a = angle, a.isFinite,
              a > FoldPause.closedAngle else { return }
        reopened = true
        deadline = now + Self.watchdog
    }

    func expired(at now: TimeInterval) -> Bool { active && now >= deadline }

    /// The lid is open enough and there is a picture to fold — the one
    /// held from the close is enough: the fold can take over from black.
    func releases(angle: Double?, pictureReady: Bool) -> Bool {
        guard active, pictureReady, let a = angle, a.isFinite else { return false }
        return a >= Self.releaseAngle
    }

    mutating func end() { self = FoldBlackout() }

    /// What the watchdog does when it fires: true hands the overlay to
    /// the live fold the way a release does, false orders it out. A lid
    /// open again, drawing, with a picture in hand hands over: under the
    /// release angle the fold draws black too, so the sharp desktop
    /// never shows through a fresh order-in. With no picture there is
    /// nothing to draw.
    static func watchdogHandsOver(angle: Double?, drawing: Bool, pictureReady: Bool) -> Bool {
        guard drawing, pictureReady, let a = angle, a.isFinite else { return false }
        return a > FoldPause.closedAngle
    }
}
