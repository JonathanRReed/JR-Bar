import SwiftUI

/// A small dot-orb that says what an agent is doing, sized for a line of
/// text: the native cousin of libraries.dev's Thinking orbs. Each
/// activity has its own calm motion —
///
/// * thinking: dots breathing around a loose ring,
/// * searching: dots sweeping an arc, like a scan,
/// * writing: dots stepping along a row, a cursor and its trail,
/// * running: a quick, tilted orbit round a nucleus —
///
/// in the tint it is given (a provider's accent, or amber for an ask).
/// One `Canvas` in one `TimelineView` at 30 fps, only while `animating`;
/// under Reduce Motion, or once the host stops it, a still arrangement
/// per activity and no clock at all. A frame evaluates positions and
/// fills ellipses, and never builds an array or mixes a colour.
struct ThinkingOrb: View {
    let activity: AgentActivity
    var tint: Color = .secondary
    var size: CGFloat = 14
    /// The host's own gate: an open panel, a visible window, a live
    /// wait. False draws the still arrangement.
    var animating = true
    /// The host's Reduce Motion reading (the panel's store keeps one);
    /// nil reads the environment's.
    var reduced: Bool? = nil

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.waitStill) private var still

    var body: some View {
        let motion = OrbMotion.mode(activity: activity, animating: animating,
                                    reduced: reduced ?? systemReduceMotion, stillTime: frozenTime)
        Group {
            switch motion {
            case .animated:
                TimelineView(.animation(minimumInterval: OrbMotion.frameInterval)) { context in
                    OrbCanvas(activity: activity, tint: tint,
                              time: context.date.timeIntervalSinceReferenceDate)
                }
            case .still(let time):
                OrbCanvas(activity: activity, tint: tint, time: time)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel(activity.spokenLabel)
    }
}

extension ThinkingOrb {
    /// A render proof's frame: its own time, or each activity's still.
    fileprivate var frozenTime: TimeInterval? {
        guard let still else { return nil }
        return still.orbTime ?? OrbLayout.stillTime(activity)
    }
}

/// One frame of an orb.
struct OrbCanvas: View {
    let activity: AgentActivity
    let tint: Color
    let time: TimeInterval
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Canvas { context, size in
            draw(&context, size: size)
        }
    }

    private func draw(_ context: inout GraphicsContext, size: CGSize) {
        let half = min(size.width, size.height) / 2 * OrbLayout.reach
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let floor = OrbLayout.opacityFloor(dark: scheme == .dark)
        let ink = GraphicsContext.Shading.color(tint)
        OrbLayout.forEachDot(activity, at: time) { dot in
            let radius = max(OrbLayout.minimumRadius, dot.radius * half)
            let rect = CGRect(x: center.x + dot.x * half - radius, y: center.y + dot.y * half - radius,
                              width: radius * 2, height: radius * 2)
            context.opacity = floor + (1 - floor) * dot.opacity
            context.fill(Path(ellipseIn: rect), with: ink)
        }
    }
}

/// Whether an orb runs a clock, and if not, which frame it holds.
enum OrbMotion: Equatable, Sendable {
    /// A `TimelineView` drives it.
    case animated
    /// One frame, `time` seconds into its loop; no clock.
    case still(TimeInterval)

    /// 30 fps: the dots are a few points across and move calmly; the
    /// display's full rate would buy nothing but cost.
    static let frameInterval: TimeInterval = 1.0 / 30

    /// Animated only while the host wants it and motion is allowed; a
    /// render proof's frozen frame (`stillTime`) wins over both.
    static func mode(activity: AgentActivity, animating: Bool, reduced: Bool,
                     stillTime: TimeInterval? = nil) -> OrbMotion {
        if let stillTime { return .still(stillTime) }
        guard animating, !reduced else { return .still(OrbLayout.stillTime(activity)) }
        return .animated
    }

    var isAnimated: Bool { self == .animated }
}

/// One dot of an orb, in the orb's own unit space: the centre is (0, 0),
/// the reach is 1 in every direction; `radius` is a fraction of the
/// reach, `opacity` 0…1 before the ink's floor.
struct OrbDot: Equatable, Sendable {
    var x: Double
    var y: Double
    var radius: Double
    var opacity: Double
}

/// Where every dot of every activity is at a moment. Pure, so the render
/// and the tests read the same arithmetic; `forEachDot` hands the dots
/// over one at a time rather than building an array a frame.
enum OrbLayout {
    /// How far the dots reach, as a share of the frame's half-width —
    /// the rest keeps the largest dot from touching the edge.
    static let reach: CGFloat = 0.84
    /// No dot draws smaller than this many points, so a 1× orb never
    /// turns to dust.
    static let minimumRadius: CGFloat = 0.7

    /// The faintest a dot draws: a little brighter on a dark surface,
    /// where thin tinted dots sink into the background.
    static func opacityFloor(dark: Bool) -> Double { dark ? 0.2 : 0.16 }

    /// The frame a still orb holds — each activity at a moment that
    /// still reads as that activity (the arc mid-swing, the cursor
    /// mid-row).
    static func stillTime(_ activity: AgentActivity) -> TimeInterval {
        switch activity {
        case .thinking: return 0.6
        case .searching: return 0.15
        case .writing: return 2.4 * writingStep
        case .running: return 0.12
        }
    }

    /// Every dot of `activity` at `time` seconds (any clock; the motions
    /// loop).
    static func forEachDot(_ activity: AgentActivity, at time: TimeInterval, _ body: (OrbDot) -> Void) {
        switch activity {
        case .thinking: thinking(time, body)
        case .searching: searching(time, body)
        case .writing: writing(time, body)
        case .running: running(time, body)
        }
    }

    /// The same dots, collected — for tests.
    static func dots(_ activity: AgentActivity, at time: TimeInterval) -> [OrbDot] {
        var out: [OrbDot] = []
        forEachDot(activity, at: time) { out.append($0) }
        return out
    }

    // MARK: Thinking — a loose ring, breathing

    static let thinkingDots = 6
    static let thinkingBreath: TimeInterval = 2.4
    static let thinkingTurn: TimeInterval = 10

    private static func thinking(_ t: TimeInterval, _ body: (OrbDot) -> Void) {
        let count = Double(thinkingDots)
        let turn = 2 * Double.pi * t / thinkingTurn
        for index in 0..<thinkingDots {
            let i = Double(index)
            let wave = 0.5 + 0.5 * sin(2 * .pi * (t / thinkingBreath - i / count))
            let loose = 0.7 * (1 + 0.07 * sin(2 * .pi * t / 3.2 + i * 1.7))
            let angle = turn + 2 * .pi * i / count
            body(OrbDot(x: loose * cos(angle), y: loose * sin(angle),
                        radius: 0.16 + 0.08 * wave, opacity: 0.3 + 0.7 * wave))
        }
    }

    // MARK: Searching — an arc sweeping like a scan

    static let searchingDots = 4
    static let searchingSwing: TimeInterval = 2.2
    /// The arc's centre, below the orb's: the arc rides its circle's top,
    /// so a pivot set this low puts the ink's centre on the slot's — over
    /// a swing, and in the still frame — level with the text beside it.
    static let searchingPivot = 0.52

    private static func searching(_ t: TimeInterval, _ body: (OrbDot) -> Void) {
        let phase = 2 * Double.pi * t / searchingSwing
        let head = -Double.pi / 2 + 1.0 * sin(phase)
        // The trail lengthens with the sweep's speed and folds into the
        // head as it turns at either end.
        let velocity = cos(phase)
        let heading: Double = velocity >= 0 ? 1 : -1
        let spacing = 0.5 * velocity + 0.08 * heading
        // The arc swings round a dim pivot (`searchingPivot`).
        body(OrbDot(x: 0, y: searchingPivot, radius: 0.15, opacity: 0.35))
        for index in 0..<searchingDots {
            let k = Double(index)
            let angle = head - k * spacing
            body(OrbDot(x: 0.7 * cos(angle), y: searchingPivot + 0.7 * sin(angle),
                        radius: 0.22 - 0.03 * k, opacity: 1 - 0.24 * k))
        }
    }

    // MARK: Writing — a cursor stepping along a row

    static let writingSlots = 4
    static let writingStep: TimeInterval = 0.34

    private static func writing(_ t: TimeInterval, _ body: (OrbDot) -> Void) {
        // Four slots and one beat of rest before the cursor starts over.
        let cycle = writingSlots + 1
        let steps = t / writingStep
        let whole = Int(floor(steps))
        let into = steps - Double(whole)
        let current = ((whole % cycle) + cycle) % cycle
        for slot in 0..<writingSlots {
            let x = -0.7 + 1.4 * Double(slot) / Double(writingSlots - 1)
            if slot == current {
                // The cursor lands with a small pop and settles.
                body(OrbDot(x: x, y: 0, radius: 0.23 + 0.05 * (1 - into), opacity: 1))
                continue
            }
            var since = current - slot - 1
            if since < 0 { since += cycle }
            let age = Double(since) + into
            let glow = max(0, 1 - age / 2.6)
            body(OrbDot(x: x, y: 0, radius: 0.15 + 0.03 * glow, opacity: 0.14 + 0.6 * glow))
        }
    }

    // MARK: Running — a quick, tilted orbit

    static let runningDots = 3
    static let runningLap: TimeInterval = 0.95
    static let runningTilt = -0.38

    private static func running(_ t: TimeInterval, _ body: (OrbDot) -> Void) {
        body(OrbDot(x: 0, y: 0, radius: 0.17, opacity: 0.55))
        let tiltCos = cos(runningTilt), tiltSin = sin(runningTilt)
        for index in 0..<runningDots {
            let angle = 2 * Double.pi * (t / runningLap + Double(index) / Double(runningDots))
            let ex = 0.8 * cos(angle), ey = 0.36 * sin(angle)
            // Nearer dots (the orbit's lower half) are larger and brighter.
            let depth = 0.5 + 0.5 * sin(angle)
            body(OrbDot(x: ex * tiltCos - ey * tiltSin, y: ex * tiltSin + ey * tiltCos,
                        radius: 0.13 + 0.09 * depth, opacity: 0.4 + 0.6 * depth))
        }
    }
}

/// A render proof's frozen frame: every orb, beam and wait under it
/// draws this moment rather than running a clock. Never set in the app.
struct WaitStill: Equatable, Sendable {
    /// The clock a wait's stage is read at.
    var now: Date
    /// Seconds into an orb's loop; nil holds each orb's own still frame.
    var orbTime: TimeInterval? = nil
    /// How far round its lap a beam's head is, 0…1.
    var beamPhase: Double = 0.2
}

private struct WaitStillKey: EnvironmentKey {
    static let defaultValue: WaitStill? = nil
}

extension EnvironmentValues {
    var waitStill: WaitStill? {
        get { self[WaitStillKey.self] }
        set { self[WaitStillKey.self] = newValue }
    }
}
