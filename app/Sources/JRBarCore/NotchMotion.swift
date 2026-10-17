import Foundation

/// The island's feel in one place. Every spring, fade and delay a surface
/// hung from the notch moves with is named here, so a person comparing
/// the island with another notch app is comparing one set of numbers, and
/// a change to the feel is a change to one file. `docs/TOP-OF-SCREEN.md`
/// carries the same table with the reasons.
///
/// Three ideas run through it:
///
/// - **The shape is the clock.** The island's frame is one spring
///   (`NotchFrameSpring`). Everything else that moves while it grows or
///   folds (the card's content, the edge light) is a pure function of how
///   far that frame has travelled (`NotchReveal`), never a second
///   animation on a clock of its own. A fold begun halfway through a grow
///   then takes the content back the way it came, in step with the shape.
/// - **Opening is lively, closing is calm.** The grow overshoots a hair;
///   the fold lands damped, so a dismissal never bounces.
/// - **Reduce Motion swaps every move for a quiet crossfade**
///   (`faceTransition`); nothing travels.
public enum NotchMotion {
    public typealias Spring = NotchFrameSpring.Motion

    // MARK: Springs

    /// The grow: the island opening into the card. Response 0.42 s and
    /// damping 0.78 overshoot the target by about 2% and settle inside
    /// 0.45 s: slow enough to read as a body growing, loose enough to
    /// feel alive. Boring Notch opens on 0.42 / 0.8; this is a hair
    /// livelier.
    public static let open = Spring(response: 0.42, dampingFraction: 0.78)
    /// A short hop outward: a notice dropping a line below the notch, a
    /// shoulder gaining a mark. Quicker than the full grow because it has
    /// less to travel; the same slight overshoot.
    public static let live = Spring(response: 0.34, dampingFraction: 0.80)
    /// The fold. Well ahead of the grow (90% home in about 135 ms, where
    /// the grow takes 195) and damped to under 0.02% overshoot: a
    /// dismissal is a quick tuck and never bounces.
    public static let close = Spring(response: 0.23, dampingFraction: 0.95)
    /// Content-driven nudges and the settle after a hover: a row
    /// refilling, a dot arriving, the swell relaxing.
    public static let nudge = Spring(response: 0.30, dampingFraction: 0.90)
    /// The hover swell: the island leans toward the pointer. Short and
    /// lively (response 0.20 s, damping 0.72) so the first points of
    /// travel start at once and the pointer feels met.
    public static let hover = Spring(response: 0.20, dampingFraction: 0.72)
    /// The marks inside the island swelling with the hover. Matches the
    /// frame's `hover` feel so shape and marks lean together.
    public static let hoverMarks = Spring(response: 0.18, dampingFraction: 0.75)

    // MARK: Content

    /// The grown card's content resolving: the sheet comes into focus
    /// (opacity, blur, scale, lift) on this spring from the moment the
    /// shape starts to move, not from the moment it is nearly there.
    /// Response 0.20 s at 0.92: a quarter of the way in at about 30 ms,
    /// 90% sharp at about 100 ms, a tick before the shape (which is 90%
    /// at 195 ms) is half done.
    public static let contentIn = Spring(response: 0.20, dampingFraction: 0.92)
    /// Content leaves ahead of the fold, but stays visible through its
    /// first frames instead of exposing a tall empty black rectangle.
    public static let contentOut = Spring(response: 0.14, dampingFraction: 0.95)

    /// A page of the grown card turning: the new page arrives on this
    /// spring while the old one is already gone (`NotchPageTurn`).
    /// Response 0.24 s at 0.92: a short, settled slide, fully readable
    /// (opaque) by about 70 ms, 90% home in about 135 ms, under 0.1% past
    /// its mark, so a swipe is answered at once and two swipes in a row do
    /// not pile up.
    public static let pageTurn = Spring(response: 0.24, dampingFraction: 0.92)

    /// Travel (the larger of the width and height change, in points)
    /// under which a growth is a hop rather than the full grow.
    public static let liveTravel: CGFloat = 110
    /// Travel under which a change is the hover swell's own size (a few
    /// points) and rides the `hover` spring out and the `nudge` back.
    public static let swellTravel: CGFloat = 10

    /// Which spring a frame change runs on: a few points of growth is
    /// the hover swell, a hop is `live`, anything bigger is the grow;
    /// shrinking folds (`nudge` back from a swell); anything else nudges.
    /// When width and height move in opposite directions, the larger
    /// change decides. A widening shoulder must not turn a fold into a grow.
    public static func frameMotion(from current: CGRect, to target: CGRect) -> Spring {
        let grewW = target.width - current.width
        let grewH = target.height - current.height
        let travel = max(abs(grewW), abs(grewH))
        let direction = abs(grewH) >= abs(grewW) ? grewH : grewW
        if direction > 0.5 {
            if travel < swellTravel { return hover }
            if travel < liveTravel { return live }
            return grewW >= liveTravel * 0.5 ? open.widthScaled(widthLead) : open
        }
        if direction < -0.5 {
            if travel < swellTravel { return nudge }
            return -grewW >= liveTravel * 0.5 ? close.widthScaled(widthLag) : close
        }
        return nudge
    }

    /// The card is a fixed 320 points wide and the shape reveals it, so
    /// the width has to be there before the content is: on the grow it
    /// runs a quarter quicker than the depth, and on the fold it
    /// trails, so the sides never cut through rows that are still lit.
    public static let widthLead: CGFloat = 0.72
    public static let widthLag: CGFloat = 1.3

    // MARK: Fades

    /// The notice capsule's entrance: the face slides down a few points
    /// while it fades in and comes into focus.
    public static let noticeSlide: CGFloat = 6
    public static let noticeBlur: CGFloat = 3
    public static let noticeFadeIn: TimeInterval = 0.18
    /// Dismissal reverses the move, a touch quicker than the entrance.
    public static let noticeFadeOut: TimeInterval = 0.14
    /// One face giving way to another (resting island, notice, ask):
    /// the incoming face a little slower than the outgoing, so the old
    /// one is gone before the new one is quite there.
    public static let swapFadeIn: TimeInterval = 0.18
    public static let swapFadeOut: TimeInterval = 0.12
    /// A new track's title, byline and cover giving way to the last
    /// one's: one crossfade, the cover and the words together.
    public static let trackSwap: TimeInterval = 0.22
    /// The words of a track, in sequence rather than on top of each other:
    /// the old title and byline go out quickly (`trackSwapOut`), and the
    /// new ones come in as the old are nearly gone (`trackSwapInDelay`,
    /// then `trackSwapIn`), so two sets of 9 pt glyphs are never both
    /// legible at the same place. The whole is still `trackSwap` long.
    public static let trackSwapOut: TimeInterval = 0.09
    public static let trackSwapInDelay: TimeInterval = 0.07
    public static let trackSwapIn: TimeInterval = 0.15

    /// How much of the outgoing and the incoming words show `since` the
    /// swap began: an ease-in out, an ease-out in. At most a sliver of
    /// each overlaps (the outgoing is under 0.4 by the time the incoming
    /// starts, and under 0.05 when the incoming is a quarter there).
    public static func trackSwapLevels(since: TimeInterval) -> (outgoing: CGFloat, incoming: CGFloat) {
        let out = min(1, max(0, since / trackSwapOut))
        let into = min(1, max(0, (since - trackSwapInDelay) / trackSwapIn))
        return (1 - out * out, 1 - (1 - into) * (1 - into))
    }

    /// A level bar following its fill.
    public static let levelFollow: TimeInterval = 0.16
    /// Reduce Motion's whole vocabulary: a quiet crossfade, no travel.
    public static let reduceMotionFade: TimeInterval = 0.15

    /// The detached glass panels (the HUD pill, the glass card) fading
    /// on `panelCurve`: arriving, re-aiming while already up, leaving.
    public static let panelIn: TimeInterval = 0.22
    public static let panelRetarget: TimeInterval = 0.12
    public static let panelOut: TimeInterval = 0.20
    public static let glassIn: TimeInterval = 0.18
    public static let glassOut: TimeInterval = 0.12
    /// A pulled glass card springing back onto its anchor.
    public static let glassSpringBack: TimeInterval = 0.24
    /// How far an arriving panel drops onto its rest frame.
    public static let panelSettle: CGFloat = 6
    public static let glassSettle: CGFloat = 4
    /// Reduce Motion's fades for those panels: in, out.
    public static let panelReducedIn: TimeInterval = 0.10
    public static let panelReducedOut: TimeInterval = 0.08
    public static let glassReducedIn: TimeInterval = 0.10
    public static let glassReducedOut: TimeInterval = 0.06

    /// The curve every panel hung from the notch fades on: a quick start
    /// and a long, soft landing. A cubic Bézier's control points;
    /// `NotchSurfaceMotion` hands it to Core Animation.
    public static let panelCurve: (x1: Float, y1: Float, x2: Float, y2: Float) = (0.2, 0.9, 0.3, 1.0)

    // MARK: Hover

    /// The hover's breath on a pointer that came straight onto the
    /// island: the swell starts this long after it arrives (at once: the
    /// first frame of a hover already answers, and it is a few points of
    /// lean that a pointer passing through takes back), ahead of the
    /// card, so the island leans first and opens second.
    public static let peekDelay: TimeInterval = 0
    /// The breath for a pointer that came down from the menu bar's row,
    /// which may only be reaching a menu: it waits longer to tell.
    public static let hoverDelay: TimeInterval = 0.12
    /// An arrival down from the menu bar's row never grows the card
    /// sooner than this (Boring Notch's floor).
    public static let barArrivalFloor: TimeInterval = 0.30
    /// How long after the pointer leaves a hover-grown card it folds, so
    /// a brief leave-and-return does not ping-pong it.
    public static let collapseDelay: TimeInterval = 0.10
    /// How long a swell holds after the pointer slips off the island, so
    /// a pointer riding the edge of the notch (or a jittery trackpad)
    /// does not make it shiver: leaving for less than this is not a leave.
    public static let swellGrace: TimeInterval = 0.08
    /// How far outside a grown card the pointer may stray before the
    /// card starts to fold: a hand overshooting a button at the card's
    /// edge, or cutting a corner on its way to one, is still on the card.
    public static let leaveSlop: CGFloat = 8

    /// The hover's two clocks for the Notch card's "Open after"
    /// (`NotchSettings.hoverOpenDelay`): the card grows once the pointer
    /// has rested that long (never sooner than `barArrivalFloor` for an
    /// arrival down from the menu bar) and the swell leads it: at
    /// `peekDelay` for a direct arrival, `hoverDelay` from the bar,
    /// and never later than the card.
    public static func hoverDelays(openAfter: Double, fromBar: Bool) -> (peek: TimeInterval, expand: TimeInterval) {
        let setting = openAfter.isFinite ? min(1, max(0, openAfter)) : hoverDelay
        let expand = fromBar ? max(setting, barArrivalFloor) : setting
        return (min(setting, fromBar ? hoverDelay : peekDelay), expand)
    }

    /// The swell's frame half: the island widens and deepens by a few
    /// points, symmetric on a drawn face, straight down on the bare
    /// housing.
    public static let hoverGrowWidth: CGFloat = 6
    public static let hoverGrowHeight: CGFloat = 4
    /// The swell's marks half: a whisper, not a pop.
    public static let hoverContentScale: CGFloat = 1.02

    // MARK: Reduce Motion

    /// How a face change moves: the spring morph normally, the quiet
    /// crossfade under Reduce Motion.
    public enum FaceTransition: Equatable, Sendable {
        case morph, crossfade
    }

    /// The single Reduce Motion branch: the island's every motion
    /// decision funnels through here so the accessibility path is one
    /// testable fact, not a scatter of reads.
    public static func faceTransition(reduceMotion: Bool) -> FaceTransition {
        reduceMotion ? .crossfade : .morph
    }
}

// MARK: - Spring analysis

extension NotchFrameSpring.Motion {
    private var omega: Double { 2 * Double.pi / Double(max(response, 0.01)) }
    private var zeta: Double { Double(max(0, dampingFraction)) }

    /// How far past its target a unit step peaks, as a fraction of the
    /// travel: 0 for a critically damped or heavier spring.
    public var overshoot: CGFloat {
        guard zeta < 1 else { return 0 }
        return CGFloat(exp(-Double.pi * zeta / (1 - zeta * zeta).squareRoot()))
    }

    /// Seconds for a unit step to stay within `tolerance` of its target
    /// (the decay envelope's bound, so a little generous).
    public func settlingTime(tolerance: Double = 0.02) -> TimeInterval {
        let decay = max(min(zeta, 1), 0.05) * omega
        let damped = zeta < 1 ? (1 - zeta * zeta).squareRoot() : 1
        return log(1 / (tolerance * damped)) / decay
    }

    /// The closed-form position of a unit step `t` seconds in: 0 at the
    /// start, 1 at rest. The integrator in `NotchFrameSpring` is held to
    /// this by test, and the render proofs read frames off it.
    public func step(at t: TimeInterval) -> CGFloat {
        guard t > 0 else { return 0 }
        let w = omega
        let z = zeta
        if z < 1 {
            let wd = w * (1 - z * z).squareRoot()
            let envelope = exp(-z * w * t)
            return CGFloat(1 - envelope * (cos(wd * t) + (z * w / wd) * sin(wd * t)))
        }
        return CGFloat(1 - exp(-w * t) * (1 + w * t))
    }
}

// MARK: - The frame spring

/// The island's interruptible frame motion: four scalar springs, one
/// per rect edge, integrated on a display link, so a retarget
/// mid-flight keeps the position and velocity the frame actually has
/// and bends toward the new target instead of restarting (or snapping,
/// the way a second `animator().setFrame` does). Pure: the window
/// drives it on ticks, the tests drive it by hand.
public struct NotchFrameSpring: Equatable, Sendable {
    /// One axis of the frame: position and velocity in screen points.
    public struct Axis: Equatable, Sendable {
        public var value: CGFloat
        public var velocity: CGFloat

        public init(value: CGFloat, velocity: CGFloat = 0) {
            self.value = value
            self.velocity = velocity
        }
    }

    /// How a retarget feels, roughly SwiftUI's `response` /
    /// `dampingFraction` pair: the period of the undamped spring and the
    /// fraction of critical damping. The named values are
    /// `NotchMotion`'s.
    public struct Motion: Equatable, Sendable {
        public var response: CGFloat
        public var dampingFraction: CGFloat
        /// How much of `response` the width (and the centring that moves
        /// with it) takes: below 1 the island widens ahead of its depth,
        /// above 1 it narrows behind it. 1 is one spring for the whole
        /// frame.
        public var widthResponseScale: CGFloat

        public init(response: CGFloat, dampingFraction: CGFloat, widthResponseScale: CGFloat = 1) {
            self.response = response
            self.dampingFraction = dampingFraction
            self.widthResponseScale = widthResponseScale
        }

        /// This feel with the width on its own clock.
        public func widthScaled(_ scale: CGFloat) -> Motion {
            var copy = self
            copy.widthResponseScale = scale
            return copy
        }
    }

    /// Which way a frame change reads: growing swells, shrinking folds.
    public static func motion(from current: CGRect, to target: CGRect) -> Motion {
        NotchMotion.frameMotion(from: current, to: target)
    }

    public private(set) var target: CGRect
    public var motion: Motion
    private var xAxis = Axis(value: 0)
    private var yAxis = Axis(value: 0)
    private var wAxis = Axis(value: 0)
    private var hAxis = Axis(value: 0)

    /// A spring sitting at `frame`, aimed at `target` (itself, when
    /// nil). `motion` is the feel the next retarget runs at.
    public init(at frame: CGRect, motion: Motion = NotchMotion.nudge, target: CGRect? = nil) {
        self.motion = motion
        self.target = target ?? frame
        xAxis = Axis(value: frame.minX)
        yAxis = Axis(value: frame.minY)
        wAxis = Axis(value: frame.width)
        hAxis = Axis(value: frame.height)
    }

    /// The frame the spring currently draws.
    public var frame: CGRect {
        CGRect(x: xAxis.value, y: yAxis.value, width: wAxis.value, height: hAxis.value)
    }

    /// The speed each edge is moving at, in points per second: the
    /// width's and the height's rate of change.
    public var velocity: CGSize {
        CGSize(width: wAxis.velocity, height: hAxis.velocity)
    }

    /// Aim at a new target: position and velocity carry over. That is
    /// the whole point, an interrupted morph continues from where it
    /// visibly was.
    public mutating func retarget(_ target: CGRect, motion: Motion) {
        self.target = target
        self.motion = motion
    }

    /// One display tick. The spring is advanced by its exact solution
    /// (a damped oscillator has one), so the frame is on the curve the
    /// tokens describe at any tick length: a late tick lands where the
    /// curve says, never explodes a stiff spring, and 60 Hz and 120 Hz
    /// draw the same motion. (The semi-implicit Euler this replaces ran
    /// about half a sub-step ahead of the curve.) `dt` is capped at half
    /// a second so a slept display link can't wind the frame up.
    /// Returns true while the frame is still moving.
    @discardableResult
    public mutating func integrate(dt: TimeInterval) -> Bool {
        let t = Double(min(max(dt, 0), 0.5))
        let omega = 2 * Double.pi / Double(max(motion.response, 0.01))
        let widthOmega = 2 * Double.pi
            / Double(max(motion.response * max(motion.widthResponseScale, 0.1), 0.01))
        let zeta = Double(min(max(motion.dampingFraction, 0), 0.999))
        Self.advance(&xAxis, toward: target.minX, omega: widthOmega, zeta: zeta, t)
        Self.advance(&yAxis, toward: target.minY, omega: omega, zeta: zeta, t)
        Self.advance(&wAxis, toward: target.width, omega: widthOmega, zeta: zeta, t)
        Self.advance(&hAxis, toward: target.height, omega: omega, zeta: zeta, t)
        return !settled
    }

    /// `axis` after `t` seconds of the underdamped spring toward
    /// `destination`, in closed form from its present value and speed.
    fileprivate static func advance(_ axis: inout Axis, toward destination: CGFloat,
                                omega: Double, zeta: Double, _ t: Double) {
        guard t > 0 else { return }
        let y0 = Double(axis.value - destination)
        let v0 = Double(axis.velocity)
        let damped = omega * (1 - zeta * zeta).squareRoot()
        let envelope = exp(-zeta * omega * t)
        let cosine = cos(damped * t)
        let sine = sin(damped * t)
        let y = envelope * (y0 * cosine + ((v0 + zeta * omega * y0) / damped) * sine)
        let v = envelope * (v0 * cosine - ((zeta * omega * v0 + omega * omega * y0) / damped) * sine)
        axis.value = destination + CGFloat(y)
        axis.velocity = CGFloat(v)
    }

    /// Still moving = any axis off its edge or still carrying speed.
    public var settled: Bool {
        func done(_ axis: Axis, _ destination: CGFloat) -> Bool {
            abs(axis.velocity) < 0.8 && abs(axis.value - destination) < 0.5
        }
        return done(xAxis, target.minX) && done(yAxis, target.minY)
            && done(wAxis, target.width) && done(hAxis, target.height)
    }

    /// Land exactly on the target: the last tick's write, so the
    /// frame can never rest a fraction of a point off.
    public mutating func snap() {
        xAxis = Axis(value: target.minX)
        yAxis = Axis(value: target.minY)
        wAxis = Axis(value: target.width)
        hAxis = Axis(value: target.height)
    }
}

// MARK: - One clock for the content

/// How far through a face change the island's body is: 0 at the
/// resting height, 1 at the grown card's. The frame spring is the only
/// clock; this is how the content reads it.
public struct NotchMorph: Equatable, Sendable {
    /// The height the island rests at (the resting face's frame).
    public var rest: CGFloat
    /// The height of the grown card.
    public var open: CGFloat
    /// The widths at the same two ends, when the caller knows them. The
    /// card is laid out at one fixed width and the shape uncovers it, so
    /// content is never more open than the shape is wide.
    public var restWidth: CGFloat?
    public var openWidth: CGFloat?

    public init(rest: CGFloat, open: CGFloat, restWidth: CGFloat? = nil, openWidth: CGFloat? = nil) {
        self.rest = rest
        self.open = open
        self.restWidth = restWidth
        self.openWidth = openWidth
    }

    /// The openness at `height`, clamped to 0...1 (the spring's
    /// overshoot is still fully open). A degenerate morph with no
    /// travel reads as fully open, so content can never be stranded
    /// invisible.
    public func openness(height: CGFloat) -> CGFloat {
        let span = open - rest
        guard span > 1 else { return 1 }
        return min(1, max(0, (height - rest) / span))
    }

    /// The openness of the whole shape: the lesser of its depth's and
    /// its width's, so a card is never lit up while the sides are still
    /// cutting through it, on the way out or the way back.
    public func openness(size: CGSize) -> CGFloat {
        let depth = openness(height: size.height)
        guard let restWidth, let openWidth, openWidth - restWidth > 1 else { return depth }
        let breadth = min(1, max(0, (size.width - restWidth) / (openWidth - restWidth)))
        return min(depth, breadth)
    }
}

/// The card's content clock: how resolved the content is, 0 (dark, soft,
/// small) to 1 (sharp and settled). A spring of its own, because content
/// that is a pure function of the shape's travel can only ever arrive
/// after the shape has, and leave after it: the grown shape was an empty
/// black blob for its first 90 ms and the fold ended with empty black
/// falling away. This one starts moving on the tick the shape does,
/// resolves on `NotchMotion.contentIn` and, aimed the other way, leaves
/// on the quicker `NotchMotion.contentOut`, so on a fold the content is
/// gone before the shape is half home.
///
/// It is interruptible both ways without a pop: the spring carries its
/// position and its velocity across a change of aim, so the curve bends
/// toward the new target and never jumps. Pure and advanced by an exact
/// solution (like `NotchFrameSpring`), so the window drives it on its
/// display link and a test drives it by hand with no clock at all.
public struct NotchContentClock: Equatable, Sendable {
    private var axis: NotchFrameSpring.Axis
    public private(set) var target: CGFloat

    /// A clock resting at `level`, aimed at it.
    public init(level: CGFloat = 0) {
        let clamped = min(1, max(0, level))
        axis = NotchFrameSpring.Axis(value: clamped)
        target = clamped
    }

    /// How resolved the content is, clamped to 0...1 (the spring's slight
    /// overshoot is still fully resolved).
    public var level: CGFloat { min(1, max(0, axis.value)) }
    public var velocity: CGFloat { axis.velocity }
    /// The motion a tick runs on: coming in or going out.
    public var motion: NotchFrameSpring.Motion {
        target >= 0.5 ? NotchMotion.contentIn : NotchMotion.contentOut
    }

    /// Aim at resolved (`open`) or gone. Position and velocity carry over.
    public mutating func aim(open: Bool) {
        target = open ? 1 : 0
    }

    /// One tick, `dt` seconds (capped at half a second, as the frame's).
    public mutating func advance(dt: TimeInterval) {
        let t = Double(min(max(dt, 0), 0.5))
        guard t > 0 else { return }
        let m = motion
        let omega = 2 * Double.pi / Double(max(m.response, 0.01))
        let zeta = Double(min(max(m.dampingFraction, 0), 0.999))
        NotchFrameSpring.advance(&axis, toward: target, omega: omega, zeta: zeta, t)
        if abs(axis.velocity) < 0.002, abs(axis.value - target) < 0.001 { snap() }
    }

    /// Land on the aim: the face is simply there, or simply gone.
    public mutating func snap() {
        axis = NotchFrameSpring.Axis(value: target)
    }

    /// Land on `open` straight away.
    public mutating func snap(open: Bool) {
        aim(open: open)
        snap()
    }

    /// Whether anything is still moving.
    public var settled: Bool { abs(axis.velocity) < 0.002 && abs(axis.value - target) < 0.001 }
}

/// What the grown card's content does at a given openness: the layers of
/// the reveal, as pure functions of `NotchMorph.openness` and nothing
/// else (no time, no direction). A fold is the same curves read
/// backwards, and a grow reversed halfway is continuous by
/// construction: the content is wherever the shape is.
///
/// The header arrives first and the rows cascade under it, each a
/// little later than the one above, the way the shape's lower edge
/// uncovers them. The whole sheet comes into focus (a blur that
/// clears) and settles down from the notch (a short lift and a scale
/// from the top), the Dynamic Island's own gesture of content condensing out of the
/// pill.
public enum NotchReveal {
    /// What the card's sheet wears at one openness.
    public struct Sheet: Equatable, Sendable {
        public var opacity: CGFloat
        /// Gaussian blur radius, in points.
        public var blur: CGFloat
        /// Scale about the sheet's top-centre.
        public var scale: CGFloat
        /// Vertical lift, in points (negative = up, toward the notch).
        public var lift: CGFloat

        public static let settled = Sheet(opacity: 1, blur: 0, scale: 1, lift: 0)
    }

    /// The sheet is dark until the shape has grown two fifths of its
    /// way and fully there at four fifths. Late enough that the lower
    /// edge is not cutting through crisp text, early enough that the
    /// content is in a quarter second into the grow. Read backwards it
    /// is the fold's rule: the content is gone while the shape still
    /// has two fifths of its way to fall.
    public static let sheetStart: CGFloat = 0.45
    public static let sheetEnd: CGFloat = 0.90
    /// The blur it arrives through, the scale it grows from, and the
    /// lift it settles down.
    public static let sheetBlur: CGFloat = 8
    public static let sheetScale: CGFloat = 0.96
    public static let sheetLift: CGFloat = 6

    /// Row cascade: the first row begins here, each later one
    /// `rowStagger` further, no more than `rowSteps` steps (a long card's
    /// last rows share the last step), and each row's own fade spans
    /// `rowSpan` of openness.
    public static let rowStart: CGFloat = 0.52
    public static let rowStagger: CGFloat = 0.02
    public static let rowSteps = 6
    public static let rowSpan: CGFloat = 0.30

    /// A notice's own reveal: the line is laid out once at its own width
    /// in the lip under the notch and the shape uncovers it, so it waits
    /// until the lip is most of the way down (the lower edge never cuts
    /// through a line that is already lit) and is whole by the time the
    /// shape has landed. Read backwards it is gone while the shape still
    /// has more than half its way to fall.
    public static let noticeStart: CGFloat = 0.40
    public static let noticeEnd: CGFloat = 0.85

    /// What a notice's face wears at one openness of its own shape: the
    /// same focus-and-settle gesture as the card's sheet, a few points
    /// of lift (`noticeSlide`) and a short blur (`noticeBlur`).
    public static func notice(openness: CGFloat) -> Sheet {
        let t = smooth(openness, from: noticeStart, to: noticeEnd)
        return Sheet(opacity: t, blur: (1 - t) * NotchMotion.noticeBlur, scale: 1,
                     lift: -(1 - t) * NotchMotion.noticeSlide)
    }

    /// The most of a notice a shape of this openness may show: a notice
    /// hangs in a lip that is a few points deep when it starts, and the
    /// lower edge would slice a line that arrived before the lip did.
    /// Nothing until the lip is a fifth down, all of it from 60%; the
    /// face wears the lesser of this and its own clock's level, so it
    /// still starts with the shape and not at the old 40%.
    public static let noticeGateStart: CGFloat = 0.20
    public static let noticeGateEnd: CGFloat = 0.60

    public static func noticeGate(openness: CGFloat) -> CGFloat {
        smooth(openness, from: noticeGateStart, to: noticeGateEnd)
    }

    /// A notice's face by the content clock (`NotchContentClock`): the
    /// same focus-and-settle gesture, opacity following the level, the
    /// blur clearing and the line settling its few points as it rises. The
    /// clock starts with the shape and leaves ahead of it, so a notice
    /// is not waiting for the lip to be 40% down, and a fold is clean.
    public static func notice(level: CGFloat) -> Sheet {
        let t = min(1, max(0, level))
        return Sheet(opacity: t, blur: (1 - t) * NotchMotion.noticeBlur, scale: 1,
                     lift: -(1 - t) * NotchMotion.noticeSlide)
    }

    /// The soft foot: while the shape's lower edge is still short of the
    /// bottom of the content it uncovers, that edge would slice through
    /// crisp text and buttons. Instead the last `footBand` points above
    /// it fade into the black, so the edge reads as the content
    /// dissolving into the island and not as a blade. The band is a
    /// function of how far short the shape is (`footReach` points to
    /// full strength) and is gone once the shape has the content's whole
    /// height, so a landed card is untouched.
    public static let footBand: CGFloat = 18
    public static let footReach: CGFloat = 24

    /// The height of the fade at the shape's foot: `shapeHeight` against
    /// the height of the content laid out inside it.
    public static func footFade(shapeHeight: CGFloat, contentHeight: CGFloat) -> CGFloat {
        let short = contentHeight - shapeHeight
        guard short > 0.5 else { return 0 }
        let t = min(1, short / footReach)
        return footBand * t * t * (3 - 2 * t)
    }

    /// The edge light's own window: the hairline along the island's
    /// lower edge arrives with the last third of the grow.
    public static let edgeStart: CGFloat = 0.55
    public static let edgeEnd: CGFloat = 0.95

    private static func smooth(_ value: CGFloat, from start: CGFloat, to end: CGFloat) -> CGFloat {
        guard end > start else { return value >= end ? 1 : 0 }
        let t = min(1, max(0, (value - start) / (end - start)))
        return t * t * (3 - 2 * t)
    }

    public static func sheet(openness: CGFloat) -> Sheet {
        let t = smooth(openness, from: sheetStart, to: sheetEnd)
        return Sheet(opacity: t, blur: (1 - t) * sheetBlur,
                     scale: sheetScale + (1 - sheetScale) * t, lift: -(1 - t) * sheetLift)
    }

    /// One row's own opacity, on top of the sheet's.
    public static func row(step: Int, openness: CGFloat) -> CGFloat {
        let capped = CGFloat(min(max(0, step), rowSteps))
        let start = rowStart + capped * rowStagger
        return smooth(openness, from: start, to: start + rowSpan)
    }

    // MARK: By the content's own clock

    /// The same sheet read off the content clock (`NotchContentClock`)
    /// instead of the shape's travel: opacity follows the level, the blur
    /// clears as it rises, the scale and the lift settle with it. The
    /// level already leads the shape on the way in and leaves ahead of it
    /// on the way out, so no window or smoothing is applied here.
    public static func sheet(level: CGFloat) -> Sheet {
        let t = min(1, max(0, level))
        return Sheet(opacity: t, blur: (1 - t) * sheetBlur,
                     scale: sheetScale + (1 - sheetScale) * t, lift: -(1 - t) * sheetLift)
    }

    /// The sheet is laid out once at the card's own width and the shape
    /// uncovers it. With the content arriving as the shape starts to
    /// move, the shape's sides would cut through lit rows for the first
    /// 150 ms; instead the sheet stands as wide as the shape is, `inset`
    /// points in from each side, and grows to its full size with it, the
    /// way the Dynamic Island's content condenses out of the pill. 1 once
    /// the shape is as wide as the card, never smaller than `fitFloor`.
    public static let fitInset: CGFloat = 8
    public static let fitFloor: CGFloat = 0.5

    public static func fit(shapeWidth: CGFloat, cardWidth: CGFloat) -> CGFloat {
        let room = cardWidth - 2 * fitInset
        guard room > 1 else { return 1 }
        return min(1, max(fitFloor, (shapeWidth - 2 * fitInset) / room))
    }

    /// Row cascade by level: the first row starts once the sheet is a
    /// tenth there, each later one `levelRowStagger` further (no more than
    /// `rowSteps` steps) and each over `levelRowSpan` of the level, so the
    /// last row is whole before the level is, and a fold takes the rows
    /// out in the reverse order, the last first.
    public static let levelRowStart: CGFloat = 0.10
    public static let levelRowStagger: CGFloat = 0.04
    public static let levelRowSpan: CGFloat = 0.50

    public static func row(step: Int, level: CGFloat) -> CGFloat {
        let capped = CGFloat(min(max(0, step), rowSteps))
        let start = levelRowStart + capped * levelRowStagger
        return smooth(level, from: start, to: start + levelRowSpan)
    }

    /// The edge light's strength, 0...1.
    public static func edgeLight(openness: CGFloat) -> CGFloat {
        smooth(openness, from: edgeStart, to: edgeEnd)
    }

    /// Whether the card should still be on stage: the grown face, or a
    /// fold that has not yet carried the content out of sight.
    public static func staged(expanded: Bool, openness: CGFloat) -> Bool {
        expanded || openness > 0.02
    }
}

// MARK: - The stage

/// The window that carries a morph. A window the size of the island
/// would be resized on every display tick, and a resize is the most
/// expensive thing a window can be asked to do; so during a morph the
/// window is a stage, big enough for the whole move (and its
/// overshoot), set once, and the shape moves inside it as the frame
/// spring says. When the spring lands the window is the shape again,
/// exactly, so at rest nothing transparent ever hangs over the menu
/// bar. This file is the geometry; `NotchIslandWindow` is the act.
public enum NotchStage {
    /// Points of air a stage keeps around a morph so the spring's
    /// overshoot never meets the window's edge.
    public static func margin(travel: CGFloat, motion: NotchFrameSpring.Motion) -> CGFloat {
        (max(travel, 40) * motion.overshoot).rounded(.up) + 3
    }

    /// The stage for a morph from `presented` to `target`: both frames
    /// and the overshoot around them, held to the top edge (the island
    /// grows down from it), never past `screen`, on whole device
    /// pixels.
    public static func frame(presented: CGRect, target: CGRect, motion: NotchFrameSpring.Motion,
                             within screen: CGRect, scale: CGFloat) -> CGRect {
        let travel = max(abs(target.width - presented.width), abs(target.height - presented.height))
        let air = margin(travel: travel, motion: motion)
        let both = presented.union(target)
        // AppKit's y runs up: the top edge is maxY, which does not move.
        var stage = CGRect(x: both.minX - air, y: both.minY - air,
                           width: both.width + 2 * air, height: both.height + air)
        stage = stage.intersection(screen)
        return NotchPixelGrid.snapOut(stage, scale: scale)
    }

    /// Whether `window` still holds `shape` (within a half point).
    public static func holds(_ window: CGRect, _ shape: CGRect) -> Bool {
        window.insetBy(dx: -0.5, dy: -0.5).contains(shape)
    }

    /// `shape` (screen coordinates, y up) as the SwiftUI view of
    /// `window` sees it: origin at the window's top-left, y down.
    public static func local(_ shape: CGRect, in window: CGRect) -> CGRect {
        CGRect(x: shape.minX - window.minX, y: window.maxY - shape.maxY,
               width: shape.width, height: shape.height)
    }
}

// MARK: - The shadow it hangs by

/// The soft shadow a grown island casts: the cue that the black body hangs
/// from the bezel instead of lying on the desktop. It belongs to a surface
/// of its own, a click-through panel laid just under the island, so no
/// transparent pixel of the island's own window ever takes a click. Only a
/// body that has grown past the notch casts one (the resting island IS the
/// bezel, and nothing may show around it), and it arrives once the shape
/// has landed, never riding the move.
public enum NotchShadow {
    /// Two layers, as a real object's: a tight contact shadow and a wide soft one.
    public struct Layer: Equatable, Sendable {
        public var radius: CGFloat
        public var offset: CGFloat
        public var opacity: Double
    }
    public static let contact = Layer(radius: 3, offset: 1, opacity: 0.30)
    public static let ambient = Layer(radius: 16, offset: 9, opacity: 0.45)

    /// Air the panel keeps past the shape on the sides and below, enough
    /// for the widest layer's blur and drop.
    public static var margin: CGFloat { ceil(ambient.radius * 2 + ambient.offset) }

    /// Fade in once landed, out as a fold begins.
    public static let fadeIn: TimeInterval = 0.22
    public static let fadeOut: TimeInterval = 0.12

    /// Whether a body of this height casts one: it has to hang a clear
    /// stride below the notch (a notice's lip counts, the swell does not).
    public static func casts(height: CGFloat, notchDepth: CGFloat) -> Bool {
        height >= max(notchDepth, 24) + 12
    }

    /// The panel's frame for `shape` (screen coordinates, y up): the shape
    /// with `margin` more on each side and below, its top the shape's own
    /// (nothing is cast up under the menu bar).
    public static func frame(for shape: CGRect) -> CGRect {
        CGRect(x: shape.minX - margin, y: shape.minY - margin,
               width: shape.width + 2 * margin, height: shape.height + margin)
    }

    /// `shape` as the panel's view sees it: origin top-left, y down.
    public static func local(_ shape: CGRect) -> CGRect {
        CGRect(x: margin, y: 0, width: shape.width, height: shape.height)
    }
}

// MARK: - The edge of a hover

/// Where a pointer counts as still on the island. Arriving is exact (the
/// resting island is the notch, and a pointer grazing the menu bar beside
/// it is not on it); staying is generous, so a hand that overshoots a
/// button at the card's edge or cuts across its corner has not left.
/// Pure, so the rule is testable without a pointer.
public enum NotchHoverBand {
    /// Whether `pointer` (screen coordinates) is on `card` or within
    /// `slop` points of it. The card hangs from the screen's top edge, so
    /// the band reaches out at its sides and under its foot.
    public static func holds(pointer: CGPoint, card: CGRect,
                             slop: CGFloat = NotchMotion.leaveSlop) -> Bool {
        card.insetBy(dx: -slop, dy: -slop).contains(pointer)
    }
}
