import JRBarCore
import SwiftUI

/// The head-on frame a U-turn passes through (docs/TOYS.md §Aquarium,
/// Swimming): the fish seen nose-on for a few frames in the middle of
/// its turn, so the flip from facing right to facing left happens where
/// it can't be seen. Built from each species' own kit — no new art per
/// species: the body a countershaded egg as thick as the fish really is
/// nose-on, the dorsal and anal fins edge-on as thin spikes, both
/// pectorals paddling out to the sides, only the tail's tips showing
/// behind and sweeping on the beat, both eyes bulging at the silhouette
/// and looking a touch inward — at you — and the mouth in the middle.
extension CartoonFish {
    /// Width over height of the body seen nose-on, drawn a little
    /// rounder than the real fish: an angelfish is a blade, a puffer a
    /// ball.
    static func frontThickness(_ species: FishSpecies) -> Double {
        switch species {
        case .minnow: return 0.62
        case .tetra: return 0.56
        case .clownfish: return 0.64
        case .tang: return 0.44
        case .angelfish: return 0.36
        case .betta: return 0.56
        case .puffer: return 0.92
        case .shark: return 0.80
        case .seahorse: return 0.20
        }
    }

    /// Where the head-on frame puts the face, in the kit's unit space
    /// with the body's axis at x 0: what wear anchors on.
    struct FrontFace {
        /// The body's full width nose-on.
        var width: Double
        /// The crown of the head, where a hat sits.
        var crown: CGPoint
        /// The two eyes, left then right.
        var eyes: (CGPoint, CGPoint)
        var eyeR: Double
        /// The mouth's centre.
        var mouth: CGPoint
        /// Under the chin, where a bow tie knots.
        var chin: CGPoint
    }

    static func frontFace(_ species: FishSpecies) -> FrontFace {
        let art = art(for: species)
        let w = art.bounds.height * frontThickness(species)
        // Eyes bulge at the silhouette's edge, never past a stubby fish's
        // middle.
        let ex = max(art.eyeR * 1.05, w * 0.5 - art.eyeR * 0.45)
        let mouthY = min(art.bounds.maxY - art.bounds.height * 0.18,
                         max(art.mouth.y, art.eye.y + art.eyeR * 1.6))
        return FrontFace(width: w,
                         crown: CGPoint(x: 0, y: art.hatAnchor.y),
                         eyes: (CGPoint(x: -ex, y: art.eye.y), CGPoint(x: ex, y: art.eye.y)),
                         eyeR: art.eyeR * 0.95,
                         mouth: CGPoint(x: 0, y: mouthY),
                         chin: CGPoint(x: 0, y: art.chin.y))
    }

    /// The egg a body makes nose-on, fullest a little above the middle.
    static func frontBody(_ art: Art, width w: Double) -> Path {
        let top = art.bounds.minY, bottom = art.bounds.maxY
        let h = art.bounds.height
        let midY = art.bounds.midY
        return spline([
            k(0, top),
            k(w * 0.40, top + h * 0.16),
            k(w * 0.50, midY - h * 0.04),
            k(w * 0.40, bottom - h * 0.18),
            k(0, bottom),
            k(-w * 0.40, bottom - h * 0.18),
            k(-w * 0.50, midY - h * 0.04),
            k(-w * 0.40, top + h * 0.16),
        ])
    }

    /// Draw the head-on frame at the origin of `f`, already translated
    /// and scaled to unit space (1 = the fish's length) by the caller.
    /// `swim` carries the beat — the tail tips and the pectorals keep
    /// moving through the turn; the rest is the side view's contract.
    static func drawFront(into f: inout GraphicsContext, species: FishSpecies,
                          palette: Palette, swim: Swim, mouth: MouthKind,
                          blink: Double, dead: Bool, pointSize: Double) {
        let art = art(for: species)
        let face = frontFace(species)
        let lw = outlineWidth(pointSize)
        let detailed = pointSize >= 38
        let w = face.width
        let h = art.bounds.height
        let top = art.bounds.minY, bottom = art.bounds.maxY
        let midY = art.bounds.midY
        let beat = sin(swim.phase) * min(1, swim.amplitude / 0.22)

        drawFrontTail(into: &f, art: art, width: w, midY: midY, beat: beat,
                      palette: palette, vivid: !dead)
        drawFrontSpikes(into: &f, art: art, width: w, beat: beat, palette: palette, lw: lw)

        let body = frontBody(art, width: w)
        if art.fins.contains(where: \.solid) {
            drawFrontSpines(into: &f, art: art, width: w, palette: palette, lw: lw)
        }
        f.stroke(body, with: .color(palette.outline), style: StrokeStyle(lineWidth: lw * 2, lineJoin: .round))
        f.fill(body, with: .linearGradient(
            Gradient(stops: [
                .init(color: palette.dark, location: 0),
                .init(color: palette.body, location: 0.36),
                .init(color: palette.body, location: 0.58),
                .init(color: palette.light, location: 0.96),
            ]),
            startPoint: CGPoint(x: 0, y: top), endPoint: CGPoint(x: 0, y: bottom)))
        var lit = f
        lit.clip(to: body)
        // A banded fish shows its first band as a pale collar round the
        // face, where it wraps the head — the clownfish, head-on.
        if !dead, art.marks.contains(where: { if case .bar = $0.style { return true }; return false }) {
            lit.stroke(body, with: .color(palette.outline.opacity(0.6)), lineWidth: w * 0.30 + lw * 2.4)
            lit.stroke(body, with: .color(.white.opacity(0.95)), lineWidth: w * 0.28)
        }
        lit.fill(body, with: .radialGradient(
            Gradient(stops: [
                .init(color: palette.glow.opacity(0.35), location: 0),
                .init(color: palette.glow.opacity(0), location: 0.4),
                .init(color: palette.dark.opacity(0), location: 0.6),
                .init(color: palette.dark.opacity(0.40), location: 1),
            ]),
            center: CGPoint(x: -w * 0.12, y: top + h * 0.28), startRadius: 0, endRadius: h * 0.62))
        // The rim of surface light along the top, as the side view has.
        lit.stroke(body, with: .linearGradient(
            Gradient(stops: [
                .init(color: palette.glow.opacity(0.8), location: 0),
                .init(color: palette.glow.opacity(0), location: 0.4),
            ]),
            startPoint: CGPoint(x: 0, y: top), endPoint: CGPoint(x: 0, y: bottom)),
            lineWidth: lw * 2.4)

        drawFrontPectorals(into: &f, art: art, width: w, phase: swim.phase, moving: swim.amplitude > 0,
                           palette: palette, lw: lw)

        // Both eyes at the silhouette, pupils a touch inward: at you.
        for (side, eye) in [(-1.0, face.eyes.0), (1.0, face.eyes.1)] {
            var e = f
            e.translateBy(x: eye.x, y: eye.y)
            // The kit's eye looks toward +x; point each at the midline.
            e.scaleBy(x: -side, y: 1)
            drawEye(into: &e, at: .zero, r: face.eyeR, palette: palette, mood: mouth,
                    blink: blink, dead: dead, lw: lw, detailed: detailed, sx: 1)
        }
        if !dead {
            drawFrontMouth(into: &f, at: face.mouth, width: w, kind: mouth, palette: palette,
                           lw: lw, s: art.mouthScale)
        }
    }

    /// Only the tail's tips show behind the body, sweeping side to side
    /// on the beat. A veil (the betta's) billows as a translucent fan.
    private static func drawFrontTail(into f: inout GraphicsContext, art: Art, width w: Double,
                                      midY: Double, beat: Double, palette: Palette, vivid: Bool) {
        guard let tail = art.fins.first(where: { if case .tail = $0.motion { return true }; return false })
        else { return }
        let r = tail.path.boundingRect
        let sweep = beat * w * 0.55
        if art.iridescent {
            let veil = w * 0.95
            let fan = Path(ellipseIn: CGRect(x: -veil + sweep * 0.4, y: r.minY,
                                             width: veil * 2, height: r.height))
            f.fill(fan, with: .radialGradient(
                Gradient(colors: [palette.body.opacity(0.70), palette.body.opacity(0.18)]),
                center: CGPoint(x: sweep * 0.2, y: midY), startRadius: 0, endRadius: r.height * 0.5))
            if vivid {
                var sheen = f
                sheen.blendMode = .plusLighter
                sheen.fill(fan, with: .radialGradient(
                    Gradient(stops: [
                        .init(color: .clear, location: 0.2),
                        .init(color: Color(red: 0.30, green: 0.70, blue: 1.0).opacity(0.14), location: 0.55),
                        .init(color: Color(red: 1.0, green: 0.40, blue: 0.80).opacity(0.12), location: 0.9),
                    ]),
                    center: CGPoint(x: 0, y: midY), startRadius: 0, endRadius: r.height * 0.5))
            }
            f.stroke(fan, with: .color(palette.outline.opacity(0.25)), lineWidth: 0.004)
        }
        var p = Path()
        p.move(to: CGPoint(x: -w * 0.06, y: midY))
        p.addQuadCurve(to: CGPoint(x: sweep, y: r.minY),
                       control: CGPoint(x: sweep * 0.3 - w * 0.12, y: (r.minY + midY) / 2))
        p.addQuadCurve(to: CGPoint(x: w * 0.06, y: midY),
                       control: CGPoint(x: sweep * 0.3 + w * 0.12, y: (r.minY + midY) / 2))
        p.addQuadCurve(to: CGPoint(x: sweep, y: r.maxY),
                       control: CGPoint(x: sweep * 0.3 + w * 0.12, y: (r.maxY + midY) / 2))
        p.addQuadCurve(to: CGPoint(x: -w * 0.06, y: midY),
                       control: CGPoint(x: sweep * 0.3 - w * 0.12, y: (r.maxY + midY) / 2))
        let tint = vivid ? (tail.tint ?? palette.dark) : palette.dark
        f.fill(p, with: .color(tint.opacity(0.72)))
    }

    /// The dorsal and anal fins edge-on: thin spikes leaning a little
    /// with the beat.
    private static func drawFrontSpikes(into f: inout GraphicsContext, art: Art, width w: Double,
                                        beat: Double, palette: Palette, lw: Double) {
        let top = art.bounds.minY, bottom = art.bounds.maxY
        let h = art.bounds.height, midY = art.bounds.midY
        let lean = beat * w * 0.10
        var spikes = Path()
        var upper = false, lower = false
        for fin in art.fins {
            guard case .ripple = fin.motion else { continue }
            let r = fin.path.boundingRect
            if !upper, fin.pivot.y < midY, r.minY < top + 0.01 {
                upper = true
                spikes.move(to: CGPoint(x: -w * 0.10, y: top + h * 0.10))
                spikes.addQuadCurve(to: CGPoint(x: lean, y: r.minY),
                                    control: CGPoint(x: -w * 0.05, y: (top + r.minY) / 2))
                spikes.addQuadCurve(to: CGPoint(x: w * 0.10, y: top + h * 0.10),
                                    control: CGPoint(x: w * 0.05, y: (top + r.minY) / 2))
                spikes.closeSubpath()
            } else if !lower, fin.pivot.y > midY, r.maxY > bottom - 0.01 {
                lower = true
                spikes.move(to: CGPoint(x: -w * 0.07, y: bottom - h * 0.10))
                spikes.addQuadCurve(to: CGPoint(x: -lean, y: r.maxY),
                                    control: CGPoint(x: -w * 0.04, y: (bottom + r.maxY) / 2))
                spikes.addQuadCurve(to: CGPoint(x: w * 0.07, y: bottom - h * 0.10),
                                    control: CGPoint(x: w * 0.04, y: (bottom + r.maxY) / 2))
                spikes.closeSubpath()
            }
        }
        f.fill(spikes, with: .color(palette.body.opacity(0.82)))
        f.stroke(spikes, with: .color(palette.outline.opacity(0.55)), lineWidth: lw * 0.7)
    }

    /// A spiny fish (the puffer) keeps its spines head-on: short solid
    /// points all round the rim.
    private static func drawFrontSpines(into f: inout GraphicsContext, art: Art, width w: Double,
                                        palette: Palette, lw: Double) {
        let h = art.bounds.height, midY = art.bounds.midY
        var spines = Path()
        let count = 14
        for i in 0..<count {
            let a = Double(i) / Double(count) * .pi * 2 + 0.2
            let rx = w * 0.5, ry = h * 0.5
            let base = CGPoint(x: cos(a) * rx * 0.92, y: midY + sin(a) * ry * 0.92)
            let tip = CGPoint(x: cos(a) * (rx + h * 0.07), y: midY + sin(a) * (ry + h * 0.07))
            let side = CGPoint(x: -sin(a) * h * 0.035, y: cos(a) * h * 0.035)
            spines.move(to: CGPoint(x: base.x + side.x, y: base.y + side.y))
            spines.addLine(to: tip)
            spines.addLine(to: CGPoint(x: base.x - side.x, y: base.y - side.y))
            spines.closeSubpath()
        }
        f.stroke(spines, with: .color(palette.outline), style: StrokeStyle(lineWidth: lw * 1.6, lineJoin: .round))
        f.fill(spines, with: .color(palette.light))
    }

    /// Both pectorals paddling out to the sides, from where the near
    /// fin roots and as far as it reaches — no further than most of the
    /// body's height, so a shark's long blades stay fins, not wings.
    private static func drawFrontPectorals(into f: inout GraphicsContext, art: Art, width w: Double,
                                           phase: Double, moving: Bool, palette: Palette, lw: Double) {
        guard let pec = art.fins.first(where: {
            if case .paddle = $0.motion { return $0.layer == .near }
            return false
        }) else { return }
        let reach = min(pec.reach * 1.25, art.bounds.height * 0.62)
        for side in [-1.0, 1.0] {
            var g = f
            let flap = moving ? 0.5 * sin(phase * 1.6 + 1.3 + (side > 0 ? 0 : 0.6)) : 0
            g.translateBy(x: side * w * 0.42, y: pec.pivot.y + art.bounds.height * 0.02)
            g.rotate(by: .radians(side * (0.55 + flap)))
            let fin = Path(ellipseIn: CGRect(x: side > 0 ? 0 : -reach, y: -reach * 0.22,
                                             width: reach, height: reach * 0.44))
            g.fill(fin, with: .color((pec.tint ?? palette.body).opacity(0.85)))
            g.stroke(fin, with: .color(palette.outline.opacity(0.7)), lineWidth: lw * 0.9)
        }
    }

    /// The mouth head-on, centred: the same three moods as the side
    /// view's, drawn symmetric.
    private static func drawFrontMouth(into f: inout GraphicsContext, at p: CGPoint, width w: Double,
                                       kind: MouthKind, palette: Palette, lw: Double, s: Double) {
        let half = min(w * 0.18, 0.075) * max(0.7, s)
        switch kind {
        case .plain:
            var m = Path()
            m.move(to: CGPoint(x: p.x - half, y: p.y))
            m.addQuadCurve(to: CGPoint(x: p.x + half, y: p.y), control: CGPoint(x: p.x, y: p.y + half * 0.8))
            f.stroke(m, with: .color(palette.outline), style: StrokeStyle(lineWidth: lw * 1.2, lineCap: .round))
        case .smile:
            var m = Path()
            m.move(to: CGPoint(x: p.x - half * 1.15, y: p.y - half * 0.1))
            m.addQuadCurve(to: CGPoint(x: p.x + half * 1.15, y: p.y - half * 0.1),
                           control: CGPoint(x: p.x, y: p.y + half * 1.5))
            m.closeSubpath()
            f.fill(m, with: .color(Color(red: 0.36, green: 0.06, blue: 0.12)))
            var tongue = f
            tongue.clip(to: m)
            tongue.fill(Path(ellipseIn: CGRect(x: p.x - half * 0.5, y: p.y + half * 0.3,
                                               width: half, height: half * 0.7)),
                        with: .color(Color(red: 1.0, green: 0.46, blue: 0.52)))
            f.stroke(m, with: .color(palette.outline),
                     style: StrokeStyle(lineWidth: lw * 1.3, lineCap: .round, lineJoin: .round))
        case .hungry:
            let r = half * 0.55
            let o = Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r * 1.1, width: r * 2, height: r * 2.2))
            f.fill(o, with: .color(palette.light))
            f.stroke(o, with: .color(palette.outline), lineWidth: lw * 1.2)
            f.fill(Path(ellipseIn: CGRect(x: p.x - r * 0.58, y: p.y - r * 0.7, width: r * 1.16, height: r * 1.4)),
                   with: .color(Color(red: 0.36, green: 0.06, blue: 0.12)))
        }
    }
}
