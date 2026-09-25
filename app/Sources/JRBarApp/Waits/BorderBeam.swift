import SwiftUI

/// Where a beam runs.
enum BeamTrack: Equatable, Sendable {
    /// Round the element's rounded rectangle, concentric with its
    /// corners — a card doing the work.
    case ring(cornerRadius: CGFloat)
    /// Along the element's bottom edge, left to right — libraries.dev's
    /// `line` type, for a command bar's field while it searches.
    case baseline
}

/// Whether a beam draws, and whether anything moves. The view reads
/// this and nothing else, so "nothing animates when inactive, or when
/// nobody can see it" is a fact a test can check rather than a hope
/// about a view tree.
enum BeamMotion: Equatable, Sendable {
    /// Inactive: no layer, no clock.
    case off
    /// Active under Reduce Motion: a soft, still glow on the border.
    case glow
    /// Active: the arc travels, one `TimelineView` driving one `Canvas`.
    case travel
    /// Active in a window that is not on screen (ordered out, wholly
    /// covered): the arc drawn once where it stands, and no clock.
    case held

    static func mode(active: Bool, reduced: Bool, onScreen: Bool = true) -> BeamMotion {
        guard active else { return .off }
        if reduced { return .glow }
        return onScreen ? .travel : .held
    }

    var isAnimating: Bool { self == .travel }
    var draws: Bool { self != .off }
}

/// The beam's measures and the only arithmetic a frame needs. A frame
/// strokes one path — the element's rounded rectangle, or its bottom
/// edge — with a dash that shows one short stretch of it; the dash
/// patterns are fixed, so moving the arc is a new dash phase and
/// nothing else.
enum BeamGeometry {
    /// How fast the head glides along the border, in points a second —
    /// the same on a small card and a wide field, so a longer border
    /// takes a longer lap rather than a faster head.
    static let speed: CGFloat = 140
    /// The shortest lap, so a small element's beam never whirls.
    static let minimumLap: TimeInterval = 2.4
    /// The frame cap: the head moves a couple of points a frame, and a
    /// clock left uncapped runs faster, not slower, off screen.
    static let frameInterval: TimeInterval = 1.0 / 60
    /// The fade in and out as the beam comes and goes.
    static let fade: TimeInterval = 0.25
    /// The head's width.
    static let lineWidth: CGFloat = 1.5
    /// How far the glow may spill past the element on every side.
    static let bleed: CGFloat = 4
    /// The bright head's length along the border.
    static let headLength: CGFloat = 26
    /// The faint trail behind it: this many steps of `trailStep` each,
    /// each fainter than the last.
    static let trailSteps = 10
    static let trailStep: CGFloat = 6
    /// The trail's opacity, step by step from the head: a geometric
    /// fall-off, so the steps read as one fading tail.
    static let trailOpacity: [Double] = (0..<trailSteps).map { 0.5 * pow(0.74, Double($0)) }
    /// The glow's blur, and the width of the stroke it blurs.
    static let glowBlur: CGFloat = 2.5
    static let glowWidth: CGFloat = 5
    /// Longer than any border a beam will run: one dash period, so a
    /// dash shows exactly one stretch whatever the element's size.
    static let period: CGFloat = 16_384
    /// A round-capped stroke's caps reach past its dash by half its
    /// width, so the dash is that much shorter at each end.
    static let headDash: [CGFloat] = [headLength - lineWidth, period - headLength + lineWidth]
    static let glowDash: [CGFloat] = [headLength + trailStep, period - headLength - trailStep]
    static let trailDash: [CGFloat] = [trailStep, period - trailStep]
    /// Everything the arc draws, head and trail.
    static var visibleLength: CGFloat { headLength + CGFloat(trailSteps) * trailStep }

    /// One lap of a track `length` long, at `speed`.
    static func lap(forTrack length: CGFloat) -> TimeInterval {
        max(minimumLap, TimeInterval(length / speed))
    }

    /// How far round its lap the head of a track `length` long is at
    /// `time`, 0…1.
    static func phase(at time: TimeInterval, trackLength length: CGFloat) -> Double {
        let laps = time / lap(forTrack: length)
        return laps - floor(laps)
    }

    /// The rectangle a ring's stroke runs on: the element's bounds
    /// (inside the bleed) inset by half the head's width, so the head
    /// sits on the element's own edge.
    static func ringRect(in size: CGSize) -> CGRect {
        CGRect(origin: .zero, size: size).insetBy(dx: bleed + lineWidth / 2, dy: bleed + lineWidth / 2)
    }

    /// The ring's corner radius, concentric with the element's.
    static func ringRadius(_ cornerRadius: CGFloat, in rect: CGRect) -> CGFloat {
        let inset = lineWidth / 2
        return max(0, min(cornerRadius - inset, min(rect.width, rect.height) / 2))
    }

    /// The length of a rounded rectangle's border with circular corners.
    static func perimeter(of rect: CGRect, cornerRadius: CGFloat) -> CGFloat {
        let radius = max(0, min(cornerRadius, min(rect.width, rect.height) / 2))
        let straight = 2 * (rect.width + rect.height) - 8 * radius
        return max(0, straight + 2 * .pi * radius)
    }

    /// The track's length: the ring's perimeter, or the baseline plus
    /// the arc's own length, so the arc leaves the right edge whole
    /// before it enters on the left again.
    static func trackLength(_ track: BeamTrack, in size: CGSize) -> CGFloat {
        switch track {
        case .ring(let cornerRadius):
            let rect = ringRect(in: size)
            return perimeter(of: rect, cornerRadius: ringRadius(cornerRadius, in: rect))
        case .baseline:
            return max(0, size.width - 2 * bleed) + visibleLength
        }
    }

    /// The dash phase that shows a dash of the pattern from `start`
    /// along the path (negative, or past the end, both fine).
    static func dashPhase(showingFrom start: CGFloat) -> CGFloat {
        let wrapped = (-start).truncatingRemainder(dividingBy: period)
        return wrapped < 0 ? wrapped + period : wrapped
    }

    /// The part of a baseline stretch inside the element: from `start`
    /// along the bottom edge for `length`, clipped to the edge's ends.
    /// Zero wide when the stretch is off either end.
    static func baselineSpan(of start: CGFloat, length: CGFloat, in size: CGSize) -> (minX: CGFloat, width: CGFloat) {
        let edge = max(0, size.width - 2 * bleed)
        let from = min(max(start, 0), edge)
        let to = min(max(start + length, 0), edge)
        return (bleed + from, max(0, to - from))
    }

    /// Where the head's front edge is, `phase` of the way round a track
    /// `length` long.
    static func headFront(phase: Double, length: CGFloat) -> CGFloat {
        CGFloat(phase) * length
    }
}

extension View {
    /// A short, soft arc of light travelling round the element's border
    /// while `active` — gliding at a steady `BeamGeometry.speed`,
    /// concentric with its corners, fading in and out over a quarter
    /// second. Under Reduce Motion it
    /// is a still glow on the border. Inactive, it draws nothing and no
    /// clock runs.
    func borderBeam(active: Bool, cornerRadius: CGFloat, tint: Color) -> some View {
        modifier(BorderBeamModifier(active: active, track: .ring(cornerRadius: cornerRadius), tint: tint))
    }

    /// The same beam on a chosen track (`BeamTrack.baseline` for a
    /// command bar's field).
    func borderBeam(active: Bool, track: BeamTrack, tint: Color) -> some View {
        modifier(BorderBeamModifier(active: active, track: track, tint: tint))
    }
}

struct BorderBeamModifier: ViewModifier {
    let active: Bool
    let track: BeamTrack
    let tint: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.waitStill) private var still
    /// Drives the fade.
    @ViewState private var shown = false
    /// Keeps the layer through its fade-out; false removes it — and its
    /// clock — entirely.
    @ViewState private var mounted = false
    /// Which fade is the latest, so a fade-out that finishes after the
    /// beam came back does not take it away again.
    @ViewState private var generation = 0
    /// The hosting window is on screen (`WaitWindowReader`); off
    /// it, the arc holds still.
    @ViewState private var onScreen = true

    func body(content: Content) -> some View {
        content
            .overlay {
                if layerPresent {
                    BorderBeamLayer(track: track, tint: tint, motion: layerMotion, frozenPhase: still?.beamPhase)
                        .padding(-BeamGeometry.bleed)
                        .opacity(layerOpacity)
                        .background {
                            if still == nil { WaitWindowReader { onScreen = $0 } }
                        }
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .onChange(of: active, initial: true) { _, isActive in sync(isActive) }
    }

    private var layerMotion: BeamMotion {
        BeamMotion.mode(active: layerPresent, reduced: reduceMotion, onScreen: onScreen)
    }

    /// A still (a render proof) shows the beam exactly while active,
    /// with no fade; live, the layer outlives `active` by its fade.
    private var layerPresent: Bool { still == nil ? mounted : active }
    private var layerOpacity: Double { still == nil ? (shown ? 1 : 0) : 1 }

    private func sync(_ isActive: Bool) {
        generation += 1
        let token = generation
        if isActive {
            mounted = true
            withAnimation(.easeOut(duration: BeamGeometry.fade)) { shown = true }
        } else if mounted {
            withAnimation(.easeIn(duration: BeamGeometry.fade), completionCriteria: .logicallyComplete) {
                shown = false
            } completion: {
                if generation == token { mounted = false }
            }
        }
    }
}

/// The beam itself: one `Canvas`, under one `TimelineView` only while it
/// travels. The view it overlays is inside `BeamGeometry.bleed` on
/// every side.
///
/// A ring strokes the element's rounded rectangle — one path, with a
/// fixed dash placed by its phase — so a frame builds no path and no
/// array. A baseline's stretches are straight, so each is a capsule
/// filled in place.
struct BorderBeamLayer: View {
    let track: BeamTrack
    let tint: Color
    let motion: BeamMotion
    /// A render proof's frame, 0…1 round the lap.
    var frozenPhase: Double? = nil
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if motion == .travel, frozenPhase == nil {
            TimelineView(.animation(minimumInterval: BeamGeometry.frameInterval)) { context in
                Canvas { canvas, size in
                    drawArc(&canvas, size: size, time: context.date.timeIntervalSinceReferenceDate)
                }
            }
        } else if motion == .travel || motion == .held {
            Canvas { canvas, size in drawArc(&canvas, size: size, phase: frozenPhase ?? 0) }
        } else if motion == .glow {
            Canvas { canvas, size in drawGlow(&canvas, size: size) }
        }
    }

    private var dark: Bool { scheme == .dark }

    /// One stretch of the arc: where it starts along the track, how
    /// long it is, and how it is drawn.
    private struct Stretch {
        var start: CGFloat
        var length: CGFloat
        var width: CGFloat
        var dash: [CGFloat]
        var round: Bool
    }

    /// The frame at `time` on the live clock: the phase depends on the
    /// track's length, which only the canvas knows.
    private func drawArc(_ canvas: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        let length = BeamGeometry.trackLength(track, in: size)
        drawArc(&canvas, size: size, phase: BeamGeometry.phase(at: time, trackLength: length))
    }

    /// One frame of the travelling arc: a blurred glow round the head,
    /// the trail fading behind it, and the head in exactly the tint —
    /// only the glow adds light, so a dark surface never bleaches the
    /// head yellow or white. On a ring the glow stays inside the
    /// element, so it needs no room round it and nothing clips it.
    private func drawArc(_ canvas: inout GraphicsContext, size: CGSize, phase: Double) {
        let length = BeamGeometry.trackLength(track, in: size)
        guard length > 0 else { return }
        let front = BeamGeometry.headFront(phase: phase, length: length)
        let headStart = front - BeamGeometry.headLength
        let ink = GraphicsContext.Shading.color(tint)
        var glowing = canvas
        if case .ring(let cornerRadius) = track {
            glowing.clip(to: Self.elementShape(size: size, cornerRadius: cornerRadius))
        }
        if dark { glowing.blendMode = .plusLighter }
        glowing.drawLayer { glow in
            glow.addFilter(.blur(radius: BeamGeometry.glowBlur))
            glow.opacity = dark ? 0.55 : 0.4
            let halo = Stretch(start: headStart - BeamGeometry.trailStep,
                               length: BeamGeometry.headLength + BeamGeometry.trailStep,
                               width: BeamGeometry.glowWidth, dash: BeamGeometry.glowDash, round: true)
            draw(halo, on: &glow, ink: ink, size: size, length: length)
        }
        for step in 0..<BeamGeometry.trailSteps {
            canvas.opacity = BeamGeometry.trailOpacity[step]
            let tail = Stretch(start: headStart - CGFloat(step + 1) * BeamGeometry.trailStep,
                               length: BeamGeometry.trailStep, width: BeamGeometry.lineWidth,
                               dash: BeamGeometry.trailDash, round: false)
            draw(tail, on: &canvas, ink: ink, size: size, length: length)
        }
        canvas.opacity = 1
        let head = Stretch(start: headStart, length: BeamGeometry.headLength, width: BeamGeometry.lineWidth,
                           dash: BeamGeometry.headDash, round: true)
        draw(head, on: &canvas, ink: ink, size: size, length: length)
    }

    /// The element's own rounded rectangle, inside the bleed.
    private static func elementShape(size: CGSize, cornerRadius: CGFloat) -> Path {
        let rect = CGRect(origin: .zero, size: size).insetBy(dx: BeamGeometry.bleed, dy: BeamGeometry.bleed)
        let radius = max(0, min(cornerRadius, min(rect.width, rect.height) / 2))
        return Path(roundedRect: rect, cornerRadius: radius, style: .continuous)
    }

    /// A stretch on the track. On a ring, a stretch that crosses the
    /// path's start is stroked twice, once each side of the seam; on a
    /// baseline, the part inside the element is filled as a capsule.
    private func draw(_ stretch: Stretch, on canvas: inout GraphicsContext, ink: GraphicsContext.Shading,
                      size: CGSize, length: CGFloat) {
        switch track {
        case .ring(let cornerRadius):
            let rect = BeamGeometry.ringRect(in: size)
            let ring = Path(roundedRect: rect, cornerRadius: BeamGeometry.ringRadius(cornerRadius, in: rect),
                            style: .circular)
            // Round caps reach half a width past the dash: start that
            // much later so the stretch still covers exactly its length.
            let capInset = stretch.round ? stretch.width / 2 : 0
            let wrapped = (stretch.start + capInset).truncatingRemainder(dividingBy: length)
            let first = wrapped < 0 ? wrapped + length : wrapped
            let cap: CGLineCap = stretch.round ? .round : .butt
            canvas.stroke(ring, with: ink, style: StrokeStyle(
                lineWidth: stretch.width, lineCap: cap, lineJoin: .round, dash: stretch.dash,
                dashPhase: BeamGeometry.dashPhase(showingFrom: first)))
            let dashLength = stretch.dash.first ?? 0
            guard first + dashLength > length else { return }
            canvas.stroke(ring, with: ink, style: StrokeStyle(
                lineWidth: stretch.width, lineCap: cap, lineJoin: .round, dash: stretch.dash,
                dashPhase: BeamGeometry.dashPhase(showingFrom: first - length)))
        case .baseline:
            let span = BeamGeometry.baselineSpan(of: stretch.start, length: stretch.length, in: size)
            guard span.width > 0 else { return }
            let y = size.height - BeamGeometry.bleed - stretch.width / 2
            let rect = CGRect(x: span.minX, y: y, width: span.width, height: stretch.width)
            let radius = stretch.round ? stretch.width / 2 : 0
            canvas.fill(Path(roundedRect: rect, cornerRadius: radius, style: .circular), with: ink)
        }
    }

    /// Reduce Motion: the whole border softly lit, nothing moving — on a
    /// ring, the glow inside the element as the arc's is.
    private func drawGlow(_ canvas: inout GraphicsContext, size: CGSize) {
        let ink = GraphicsContext.Shading.color(tint)
        let width = BeamGeometry.lineWidth
        var glowing = canvas
        if case .ring(let cornerRadius) = track {
            glowing.clip(to: Self.elementShape(size: size, cornerRadius: cornerRadius))
        }
        glowing.drawLayer { glow in
            glow.addFilter(.blur(radius: BeamGeometry.glowBlur + 0.5))
            glow.opacity = dark ? 0.4 : 0.3
            strokeWhole(on: &glow, ink: ink, size: size, width: 4)
        }
        canvas.opacity = dark ? 0.5 : 0.42
        strokeWhole(on: &canvas, ink: ink, size: size, width: width)
    }

    private func strokeWhole(on canvas: inout GraphicsContext, ink: GraphicsContext.Shading, size: CGSize,
                             width: CGFloat) {
        switch track {
        case .ring(let cornerRadius):
            let rect = BeamGeometry.ringRect(in: size)
            let ring = Path(roundedRect: rect, cornerRadius: BeamGeometry.ringRadius(cornerRadius, in: rect),
                            style: .circular)
            canvas.stroke(ring, with: ink, style: StrokeStyle(lineWidth: width, lineJoin: .round))
        case .baseline:
            let rect = CGRect(x: BeamGeometry.bleed, y: size.height - BeamGeometry.bleed - width / 2,
                              width: max(0, size.width - 2 * BeamGeometry.bleed), height: width)
            canvas.fill(Path(roundedRect: rect, cornerRadius: width / 2, style: .circular), with: ink)
        }
    }
}
