import AppKit
import JRBarCore
import SwiftUI

/// The tank's events and its stations.
extension AquariumView {
    // MARK: Events

    /// A four-point sparkle, unit-sized: the glint of gold, a pearl
    /// catching the light, a star winking off brass.
    static let sparklePath: Path = {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: -0.5))
        p.addQuadCurve(to: CGPoint(x: 0.5, y: 0), control: CGPoint(x: 0.07, y: -0.07))
        p.addQuadCurve(to: CGPoint(x: 0, y: 0.5), control: CGPoint(x: 0.07, y: 0.07))
        p.addQuadCurve(to: CGPoint(x: -0.5, y: 0), control: CGPoint(x: -0.07, y: 0.07))
        p.addQuadCurve(to: CGPoint(x: 0, y: -0.5), control: CGPoint(x: -0.07, y: -0.07))
        p.closeSubpath()
        return p
    }()

    /// One sparkle with its soft halo, in additive light.
    func drawSparkle(canvas: inout GraphicsContext, at p: CGPoint, size: Double, alpha: Double,
                     color: Color = Color(red: 1.0, green: 0.92, blue: 0.62)) {
        guard alpha > 0.01 else { return }
        var s = canvas
        s.blendMode = .plusLighter
        s.opacity = alpha
        s.fill(Path(ellipseIn: CGRect(x: p.x - size, y: p.y - size, width: size * 2, height: size * 2)),
               with: .radialGradient(Gradient(colors: [color.opacity(0.45), .clear]),
                                     center: p, startRadius: 0, endRadius: size))
        s.translateBy(x: p.x, y: p.y)
        s.scaleBy(x: size * 1.6, y: size * 1.6)
        s.fill(Self.sparklePath, with: .color(color))
        s.scaleBy(x: 0.45, y: 0.45)
        s.fill(Self.sparklePath, with: .color(.white))
    }

    /// The buried treasure (docs/TOYS.md shop): a chest sunk to its lid
    /// in the sand at its seeded spot, gold showing at the crack, a
    /// sparkle climbing off it every few seconds. Its hitbox feeds
    /// `motion.treasureBox`; the tap digs, three digs open it.
    func drawTreasure(canvas: inout GraphicsContext, size: CGSize, t: Double, now: Date) {
        guard let treasure = game?.treasure else {
            motion.treasureBox = nil
            return
        }
        let x = treasure.x * size.width
        let baseY = sandTop(atX: x, in: size) + 2
        let sand = sandPalette
        // Each dig clears a little more sand off it.
        let dug = min(2, max(0, Double(treasure.taps)))
        let sunk = 6 - dug * 2
        contactShadow(canvas: &canvas, x: x, y: baseY - 1, halfW: 16, alpha: 0.30)
        var c = canvas
        c.translateBy(x: x, y: baseY + sunk)
        c.scaleBy(x: 0.62, y: 0.62)
        Self.paintChest(&c, width: 40, height: 26, open: 0.10, t: 0, reduceMotion: true)
        // The sand drifted over its foot: a low heap sloping away into
        // the bed, lit along its crest and melting into the sand at its
        // edges, so it reads as buried, not set on a plate.
        let heapTop = baseY - 2 + dug * 0.6
        let heapFoot = baseY + 8
        var crestLine = Path()
        crestLine.move(to: CGPoint(x: x - 27, y: heapFoot))
        crestLine.addCurve(to: CGPoint(x: x, y: heapTop),
                           control1: CGPoint(x: x - 16, y: heapFoot - 2), control2: CGPoint(x: x - 15, y: heapTop))
        crestLine.addCurve(to: CGPoint(x: x + 27, y: heapFoot),
                           control1: CGPoint(x: x + 15, y: heapTop), control2: CGPoint(x: x + 16, y: heapFoot - 2))
        var heap = crestLine
        heap.closeSubpath()
        let packed = TankPaint.mix(sand.lit, sand.body, 0.25)
        canvas.fill(heap, with: .linearGradient(
            Gradient(stops: [
                .init(color: TankPaint.color(sand.lit), location: 0),
                .init(color: TankPaint.color(packed), location: 0.65),
                .init(color: TankPaint.color(packed, 0), location: 1),
            ]),
            startPoint: CGPoint(x: 0, y: heapTop), endPoint: CGPoint(x: 0, y: heapFoot)))
        var lip = canvas
        lip.clip(to: heap)
        lip.stroke(crestLine.offsetBy(dx: 0, dy: 0.8), with: .linearGradient(
            Gradient(colors: [TankPaint.color(sand.crest, 0), TankPaint.color(sand.crest, 0.6),
                              TankPaint.color(sand.crest, 0)]),
            startPoint: CGPoint(x: x - 27, y: 0), endPoint: CGPoint(x: x + 27, y: 0)), lineWidth: 1.2)
        // The gold at the crack breathes, and a sparkle climbs off it
        // every ~3.5 s — seeded off the treasure's own id so two
        // treasures never sync.
        let lidY = baseY + sunk - 26 * 0.62 * 0.6
        let breathe = reduceMotion ? 0.6 : 0.5 + 0.5 * sin(t * 2.4)
        TankPaint.glow(&canvas, at: CGPoint(x: x, y: lidY), radius: 20,
                       color: Color(red: 1.0, green: 0.84, blue: 0.40).opacity(0.18 + 0.14 * breathe))
        let sparklePhase = frac(t / 3.5 + Double(AquariumModel.stableHash(treasure.id) & 0xFF) / 0xFF)
        if sparklePhase < 0.4 && !reduceMotion {
            let k = sparklePhase / 0.4
            drawSparkle(canvas: &canvas, at: CGPoint(x: x + sin(k * 5) * 4, y: lidY - 4 - k * 24),
                        size: 3 + k * 3, alpha: sin(k * .pi))
        }
        motion.treasureBox = (treasure.id,
                              CGRect(x: x - 20, y: baseY - 22, width: 40, height: 28))
    }

    /// The third dig's payoff: a pop of gold where the lid opened —
    /// coins turning over as they arc out and fall, sparkles among
    /// them, a flash at the heart.
    func drawGoldBursts(canvas: inout GraphicsContext, size: CGSize, now: Date) {
        for burst in motion.goldBursts {
            let p = clamp01(now.timeIntervalSince(burst.bornAt) / 1.1)
            guard p < 1 else { continue }
            let centre = burst.x
            TankPaint.glow(&canvas, at: centre, radius: 26 + p * 30,
                           color: Color(red: 1.0, green: 0.86, blue: 0.44).opacity(0.45 * (1 - p)))
            for i in 0..<12 {
                var h = AquariumModel.stableHash("gold-\(i)")
                h ^= h >> 33; h &*= 0xff51afd7ed558ccd; h ^= h >> 33
                let a = Double(h & 0xFF) / 0xFF * .pi - .pi * 0.95
                let dist = (18 + Double((h >> 8) & 0xFF) / 0xFF * 44) * p
                let gx = centre.x + cos(a) * dist
                let gy = centre.y + sin(a) * dist + p * p * 34
                if i % 3 == 0 {
                    drawSparkle(canvas: &canvas, at: CGPoint(x: gx, y: gy), size: 3.5 * (1 - p * 0.5),
                                alpha: (1 - p) * 0.95)
                    continue
                }
                // A coin: an ellipse that narrows and widens as it turns.
                let r = 2.6 + Double((h >> 16) & 0x3) * 0.5
                let turn = abs(cos(p * 9 + Double(i)))
                let coin = Path(ellipseIn: CGRect(x: gx - r * max(0.2, turn), y: gy - r,
                                                  width: r * 2 * max(0.2, turn), height: r * 2))
                var c = canvas
                c.opacity = 1 - p * p
                c.fill(coin, with: .linearGradient(
                    Gradient(colors: [Color(red: 1.0, green: 0.94, blue: 0.62), Color(red: 0.86, green: 0.62, blue: 0.18)]),
                    startPoint: CGPoint(x: gx - r, y: gy - r), endPoint: CGPoint(x: gx + r, y: gy + r)))
                c.stroke(coin, with: .color(Color(red: 0.60, green: 0.40, blue: 0.08).opacity(0.7)), lineWidth: 0.6)
            }
        }
    }

    /// The bubble-ring trick: a tapped fish blows a ring that swells
    /// and climbs — a glassy torus, bright along its top, wobbling a
    /// little as it rises.
    func drawTrickRings(canvas: inout GraphicsContext, size: CGSize,
                        layouts: [String: Layout], now: Date) {
        for (id, trick) in motion.tricks where trick.kind == .ring {
            guard now < trick.until, let l = layouts[id] else { continue }
            let p = clamp01(1 - trick.until.timeIntervalSince(now)
                            / AquariumBehavior.trickDuration)
            let r = 4 + p * 20
            let wobble = reduceMotion ? 0 : sin(p * 18) * 0.08
            let cy = l.y - 14 - p * 30
            let ring = CGRect(x: l.x - r * (1 + wobble), y: cy - r * 0.42 * (1 - wobble),
                              width: r * 2 * (1 + wobble), height: r * 0.84 * (1 - wobble))
            var c = canvas
            c.opacity = (1 - p) * 0.9
            c.stroke(Path(ellipseIn: ring), with: .color(.white.opacity(0.18)), lineWidth: 3.2)
            c.stroke(Path(ellipseIn: ring), with: .linearGradient(
                Gradient(colors: [.white.opacity(0.9), .white.opacity(0.25)]),
                startPoint: CGPoint(x: ring.midX, y: ring.minY), endPoint: CGPoint(x: ring.midX, y: ring.maxY)),
                     lineWidth: 1.4)
        }
    }

    /// The visitor parade (docs/TOYS.md shop): a queued passer-by
    /// crosses the back layer once — a humpback's great dim shape, a
    /// diver with a torch, a little submarine with its portholes lit.
    /// Each is painted a long way off, veiled by the water between, and
    /// only its lights — the lamp, the portholes, the torch — shine
    /// through the veil at full strength. `visitorShown` answers as the
    /// parade starts — through the post-pass drain — so a relaunch
    /// can't replay it; Reduce Motion holds the portrait still
    /// mid-tank for the same span instead of crossing, so the visit is
    /// a thing on screen, not only a toast.
    func drawVisitor(canvas: inout GraphicsContext, size: CGSize, t: Double, now: Date) {
        // Claim the queue's head when the lane is free. The claim lands
        // on `activeVisitor` now; the game's `visitorShown` waits for
        // the post-pass drain like every draw-time event. A hushed room
        // (quiet, a Focus, a call) leaves the visitor in its queue until
        // it clears — asked last, so the room is only read when someone
        // is actually waiting to swim by.
        if !ambient, motion.activeVisitor == nil, now >= motion.visitorCooldownUntil,
           let next = game?.pendingVisitors.first, toy?.hushed != true {
            motion.activeVisitor = (next, now)
            motion.pendingEvents.append(.visitorShown(next))
            queueEventDrain()
        }
        guard let visitor = motion.activeVisitor else { return }
        let duration = Self.paradeSeconds(visitor.kind)
        let elapsed = now.timeIntervalSince(visitor.startedAt)
        guard elapsed < duration else {
            motion.activeVisitor = nil
            motion.visitorCooldownUntil = now.addingTimeInterval(6)
            motion.pendingEvents.append(.visitorDeparted(visitor.kind))
            queueEventDrain()
            return
        }
        let p = fixture?.visitorProgress ?? (reduceMotion ? 0.5 : elapsed / duration)
        let x = size.width * (1.15 - 1.3 * p)
        let presence = sin(p * .pi)
        switch visitor.kind {
        case .whale: drawWhale(canvas: &canvas, size: size, t: t, x: x, p: p, presence: presence)
        case .diver: drawDiver(canvas: &canvas, size: size, t: t, x: x, p: p, presence: presence)
        case .submarine: drawSubmarine(canvas: &canvas, size: size, t: t, x: x, presence: presence)
        case .alien: drawAlien(canvas: &canvas, size: size, t: t, x: x, presence: presence)
        }
    }

    /// Paints a visitor in its own layer and veils it with the water
    /// between it and the glass — `amount` of the column's colour at
    /// its height.
    private func veiled(_ canvas: inout GraphicsContext, bounds: CGRect, unitY: Double, amount: Double,
                        draw: (inout GraphicsContext) -> Void) {
        let haze = waterRGB(at: unitY)
        canvas.drawLayer { layer in
            draw(&layer)
            layer.blendMode = .sourceAtop
            layer.fill(Path(bounds), with: .color(TankPaint.color(haze, amount)))
        }
    }

    /// A humpback far off in the blue: slate back lit along its ridge,
    /// a pale grooved throat, the long pectoral and the fluke — mostly
    /// water between us and it. It spouts if it nears the surface.
    private func drawWhale(canvas: inout GraphicsContext, size: CGSize, t: Double,
                           x: Double, p: Double, presence: Double) {
        let y = size.height * 0.24 + sin(p * .pi * 3) * 8
        var c = canvas
        c.opacity = 0.75 * presence
        c.translateBy(x: x, y: y)
        let slate = Color(red: 0.14, green: 0.24, blue: 0.36)
        let slateDark = Color(red: 0.05, green: 0.10, blue: 0.18)
        let belly = Color(red: 0.52, green: 0.66, blue: 0.74)
        let beat = reduceMotion ? 0 : sin(t * 0.9) * 5
        veiled(&c, bounds: CGRect(x: -150, y: -50, width: 260, height: 100), unitY: 0.3, amount: 0.42) { c in
            var body = Path()
            body.move(to: CGPoint(x: -110, y: 0))
            body.addQuadCurve(to: CGPoint(x: 40, y: -30), control: CGPoint(x: -50, y: -34))
            body.addQuadCurve(to: CGPoint(x: 96, y: -4), control: CGPoint(x: 78, y: -24))
            body.addQuadCurve(to: CGPoint(x: 40, y: 22), control: CGPoint(x: 80, y: 12))
            body.addQuadCurve(to: CGPoint(x: -110, y: 0), control: CGPoint(x: -40, y: 30))
            body.closeSubpath()
            // The fluke, behind, beating slowly.
            var fluke = Path()
            fluke.move(to: CGPoint(x: -104, y: 0))
            fluke.addQuadCurve(to: CGPoint(x: -140, y: -16 + beat), control: CGPoint(x: -118, y: -10))
            fluke.addQuadCurve(to: CGPoint(x: -128, y: beat * 0.5), control: CGPoint(x: -134, y: -4 + beat))
            fluke.addQuadCurve(to: CGPoint(x: -140, y: 14 + beat), control: CGPoint(x: -134, y: 4 + beat))
            fluke.addQuadCurve(to: CGPoint(x: -104, y: 0), control: CGPoint(x: -118, y: 8))
            fluke.closeSubpath()
            c.fill(fluke, with: .linearGradient(Gradient(colors: [slate, slateDark]),
                                                startPoint: CGPoint(x: -120, y: -14), endPoint: CGPoint(x: -120, y: 14)))
            c.fill(body, with: .linearGradient(
                Gradient(stops: [.init(color: slate, location: 0), .init(color: slateDark, location: 0.55),
                                 .init(color: belly, location: 1)]),
                startPoint: CGPoint(x: 0, y: -30), endPoint: CGPoint(x: 0, y: 26)))
            var inner = c
            inner.clip(to: body)
            // Throat grooves along the pale underside.
            var grooves = Path()
            for k in 0..<6 {
                let gy = 7.0 + Double(k) * 2.6
                grooves.move(to: CGPoint(x: 90 - Double(k) * 6, y: gy - 10))
                grooves.addQuadCurve(to: CGPoint(x: -10, y: gy + 4), control: CGPoint(x: 40, y: gy + 8))
            }
            inner.stroke(grooves, with: .color(slateDark.opacity(0.45)), lineWidth: 0.8)
            // Knobs on the head and the light along the back.
            var knobs = Path()
            for k in 0..<5 {
                knobs.addEllipse(in: CGRect(x: 58 + Double(k) * 6, y: -22 + Double(k) * 3.2, width: 2.6, height: 2.2))
            }
            inner.fill(knobs, with: .color(belly.opacity(0.35)))
            inner.stroke(body.offsetBy(dx: 0, dy: 2.5), with: .color(Color(red: 0.62, green: 0.82, blue: 0.90).opacity(0.35)),
                         lineWidth: 3)
            c.fill(Path(ellipseIn: CGRect(x: 54, y: 2, width: 3.2, height: 2.4)), with: .color(slateDark))
            // The long pectoral, pale-edged, sculling.
            var fin = Path()
            fin.move(to: CGPoint(x: 26, y: 12))
            fin.addQuadCurve(to: CGPoint(x: -24, y: 40 + beat * 0.6), control: CGPoint(x: 10, y: 34))
            fin.addQuadCurve(to: CGPoint(x: 14, y: 20), control: CGPoint(x: -2, y: 28))
            fin.closeSubpath()
            c.fill(fin, with: .linearGradient(Gradient(colors: [slateDark, belly]),
                                              startPoint: CGPoint(x: 20, y: 14), endPoint: CGPoint(x: -24, y: 40)))
        }
        // The spout: a breath of bubbles off the back while it's high.
        if y < size.height * 0.20 && !reduceMotion {
            for k in 0..<4 {
                let sp = frac(t * 1.2 + Double(k) / 4)
                drawBubble(canvas: &canvas, at: CGPoint(x: x + 52 - sp * 4, y: y - 32 - sp * 26),
                           radius: 2 + sp * 3, alpha: (1 - sp) * 0.7 * presence)
            }
        }
    }

    /// A diver in the middle distance: wetsuit and hood, a steel tank,
    /// yellow fins scissoring, a mask catching the light — and a torch
    /// whose beam sweeps ahead, bright through the water.
    private func drawDiver(canvas: inout GraphicsContext, size: CGSize, t: Double,
                           x: Double, p: Double, presence: Double) {
        let y = size.height * 0.34 + sin(p * .pi * 4) * 10
        var c = canvas
        c.translateBy(x: x, y: y)
        c.opacity = presence
        let suit = Color(red: 0.14, green: 0.17, blue: 0.24)
        let suitLit = Color(red: 0.36, green: 0.44, blue: 0.58)
        let fin = Color(red: 0.98, green: 0.76, blue: 0.16)
        let edge = Color(red: 0.05, green: 0.06, blue: 0.10).opacity(0.5)
        let kick = reduceMotion ? 0 : sin(t * 6) * 4
        let sweep = reduceMotion ? 0 : sin(t * 0.9) * 0.35
        // The torch's beam, ahead: light, so it draws unveiled.
        var torch = c
        torch.blendMode = .plusLighter
        torch.translateBy(x: -17, y: -1)
        torch.rotate(by: .radians(-0.22 + sweep))
        torch.scaleBy(x: 1, y: 0.28)
        torch.fill(Path(ellipseIn: CGRect(x: -110, y: -60, width: 120, height: 120)),
                   with: .radialGradient(
                       Gradient(stops: [
                           .init(color: Color(red: 1.0, green: 0.97, blue: 0.84).opacity(0.36), location: 0),
                           .init(color: Color(red: 1.0, green: 0.97, blue: 0.84).opacity(0.10), location: 0.5),
                           .init(color: .clear, location: 1),
                       ]),
                       center: CGPoint(x: 0, y: 0), startRadius: 0, endRadius: 110))
        veiled(&c, bounds: CGRect(x: -22, y: -14, width: 52, height: 26), unitY: 0.34, amount: 0.22) { c in
            // Kick fins trailing, scissoring.
            for k in [-1.0, 1.0] {
                var leg = Path()
                leg.move(to: CGPoint(x: 8, y: k * 2))
                leg.addLine(to: CGPoint(x: 16, y: k * 3 + kick * k * 0.5))
                c.stroke(leg, with: .color(suit), style: StrokeStyle(lineWidth: 3.2, lineCap: .round))
                var blade = Path()
                blade.move(to: CGPoint(x: 15, y: k * 3 + kick * k * 0.5 - 1.5))
                blade.addQuadCurve(to: CGPoint(x: 27, y: k * 5 + kick * k), control: CGPoint(x: 21, y: k * 3 + kick * k * 0.7 - 2))
                blade.addLine(to: CGPoint(x: 26, y: k * 5 + kick * k + 3))
                blade.addLine(to: CGPoint(x: 15, y: k * 3 + kick * k * 0.5 + 1.5))
                blade.closeSubpath()
                c.fill(blade, with: .linearGradient(Gradient(colors: [fin, Color(red: 0.80, green: 0.50, blue: 0.08)]),
                                                    startPoint: CGPoint(x: 15, y: 0), endPoint: CGPoint(x: 27, y: 0)))
            }
            // The tank on the back.
            let tank = Path(roundedRect: CGRect(x: -6, y: -10, width: 14, height: 5), cornerRadius: 2.5)
            TankPaint.cylinder(&c, tank, lit: Color(red: 0.96, green: 0.96, blue: 0.96),
                               base: Color(red: 0.72, green: 0.74, blue: 0.78), shade: Color(red: 0.38, green: 0.40, blue: 0.46),
                               outline: edge, lineWidth: 0.3)
            // The body in its suit, head and hood.
            let torso = Path(ellipseIn: CGRect(x: -12, y: -5, width: 22, height: 10))
            TankPaint.solid(&c, torso, lit: suitLit, base: suit, shade: .black, outline: edge, lineWidth: 0.4)
            let head = Path(ellipseIn: CGRect(x: -18, y: -8, width: 9, height: 9))
            TankPaint.solid(&c, head, lit: suitLit, base: suit, shade: .black, outline: edge, lineWidth: 0.4)
            // The mask with its glint, and the torch in hand.
            let mask = Path(roundedRect: CGRect(x: -18.6, y: -6, width: 4.6, height: 3.6), cornerRadius: 1.2)
            c.fill(mask, with: .linearGradient(Gradient(colors: [Color(red: 0.62, green: 0.90, blue: 0.98), Color(red: 0.10, green: 0.30, blue: 0.40)]),
                                               startPoint: CGPoint(x: -18, y: -6), endPoint: CGPoint(x: -15, y: -2.4)))
            c.stroke(mask, with: .color(fin), lineWidth: 0.6)
            c.fill(Path(ellipseIn: CGRect(x: -17.8, y: -5.6, width: 1.4, height: 0.8)), with: .color(.white.opacity(0.9)))
            c.fill(Path(roundedRect: CGRect(x: -19, y: 0, width: 5, height: 2.2), cornerRadius: 1),
                   with: .color(Color(red: 0.30, green: 0.32, blue: 0.36)))
        }
        TankPaint.glow(&c, at: CGPoint(x: -19, y: 1), radius: 5, color: Color(red: 1, green: 0.98, blue: 0.86).opacity(0.8))
        // Bubbles off the regulator.
        for k in 0..<3 {
            let bp = frac(t * 0.8 + Double(k) / 3)
            drawBubble(canvas: &canvas, at: CGPoint(x: x - 14 - bp * 6, y: y - 12 - bp * 40),
                       radius: 1.2 + bp * 1.6, alpha: (1 - bp) * 0.8 * presence)
        }
    }

    /// A little research submarine gliding across the back of the tank:
    /// a rounded yellow hull with its seams and rivets, a conning tower
    /// and periscope, a turning screw — and, through the veil, the warm
    /// portholes and the bow lamp throwing a soft cone ahead.
    private func drawSubmarine(canvas: inout GraphicsContext, size: CGSize, t: Double,
                               x: Double, presence: Double) {
        let y = size.height * 0.30 + (reduceMotion ? 0 : sin(t * 0.8) * 2)
        var c = canvas
        c.translateBy(x: x, y: y)
        c.opacity = presence
        let yellowLit = Color(red: 1.0, green: 0.90, blue: 0.52)
        let yellow = Color(red: 0.94, green: 0.72, blue: 0.20)
        let yellowDark = Color(red: 0.50, green: 0.33, blue: 0.08)
        let edge = yellowDark.opacity(0.6)
        let lamp = Color(red: 1.0, green: 0.95, blue: 0.78)
        // The bow lamp's beam, ahead and a little down.
        var beam = c
        beam.blendMode = .plusLighter
        beam.translateBy(x: -46, y: 3)
        beam.rotate(by: .radians(-0.10))
        beam.scaleBy(x: 1, y: 0.30)
        beam.fill(Path(ellipseIn: CGRect(x: -170, y: -90, width: 180, height: 180)),
                  with: .radialGradient(
                      Gradient(stops: [
                          .init(color: lamp.opacity(0.32), location: 0),
                          .init(color: lamp.opacity(0.10), location: 0.45),
                          .init(color: .clear, location: 1),
                      ]),
                      center: .zero, startRadius: 0, endRadius: 170))
        let portholes = (0..<4).map { CGPoint(x: -26 + Double($0) * 15, y: -1) }
        veiled(&c, bounds: CGRect(x: -50, y: -36, width: 114, height: 52), unitY: 0.30, amount: 0.16) { c in
            // Tail cross and the screw behind the hull.
            for k in [-1.0, 1.0] {
                var fin = Path()
                fin.move(to: CGPoint(x: 38, y: k * 3))
                fin.addLine(to: CGPoint(x: 54, y: k * 14))
                fin.addQuadCurve(to: CGPoint(x: 58, y: k * 13), control: CGPoint(x: 57, y: k * 15))
                fin.addLine(to: CGPoint(x: 52, y: k * 2))
                fin.closeSubpath()
                TankPaint.solid(&c, fin, lit: yellowLit, base: yellow, shade: yellowDark, outline: edge, lineWidth: 0.5)
            }
            let spin = reduceMotion ? 0 : t * 14
            for k in 0..<3 {
                let a = spin + Double(k) * 2.1
                let blade = Path(ellipseIn: CGRect(x: 56, y: -2 + sin(a) * 4 - 2, width: 4, height: 4 + abs(cos(a)) * 5))
                c.fill(blade, with: .color(Color(red: 0.62, green: 0.56, blue: 0.44)))
            }
            // The hull: a cigar, bow to the left, lit from above.
            let hull = Path(ellipseIn: CGRect(x: -46, y: -13, width: 96, height: 26))
            TankPaint.solid(&c, hull, lit: yellowLit, base: yellow, shade: yellowDark, outline: edge, lineWidth: 0.7, rim: 0.5)
            var plating = c
            plating.clip(to: hull)
            var seams = Path()
            for sx in [-24.0, 0.0, 24.0] {
                seams.move(to: CGPoint(x: sx, y: -14)); seams.addQuadCurve(to: CGPoint(x: sx, y: 14), control: CGPoint(x: sx - 3, y: 0))
            }
            seams.move(to: CGPoint(x: -46, y: 5)); seams.addLine(to: CGPoint(x: 50, y: 5))
            plating.stroke(seams, with: .color(yellowDark.opacity(0.40)), lineWidth: 0.6)
            plating.stroke(seams.offsetBy(dx: 0.6, dy: 0.6), with: .color(yellowLit.opacity(0.35)), lineWidth: 0.4)
            var rivets = Path()
            for k in 0..<14 {
                rivets.addEllipse(in: CGRect(x: -40 + Double(k) * 6.4, y: 6.6, width: 1.1, height: 1.1))
            }
            plating.fill(rivets, with: .color(yellowDark.opacity(0.6)))
            // The conning tower and periscope.
            let tower = Path(roundedRect: CGRect(x: -8, y: -24, width: 20, height: 13), cornerRadius: 4)
            TankPaint.solid(&c, tower, lit: yellowLit, base: yellow, shade: yellowDark, outline: edge, lineWidth: 0.5)
            var scope = Path()
            scope.move(to: CGPoint(x: 4, y: -24)); scope.addLine(to: CGPoint(x: 4, y: -33)); scope.addLine(to: CGPoint(x: -3, y: -33))
            c.stroke(scope, with: .color(Color(red: 0.30, green: 0.28, blue: 0.24)),
                     style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
            c.stroke(scope.offsetBy(dx: -0.4, dy: -0.4), with: .color(Color(red: 0.72, green: 0.68, blue: 0.60)),
                     style: StrokeStyle(lineWidth: 0.9, lineCap: .round, lineJoin: .round))
            // Porthole rims, brass.
            for port in portholes {
                let rim = CGRect(x: port.x - 4.2, y: port.y - 4.2, width: 8.4, height: 8.4)
                c.fill(Path(ellipseIn: rim), with: .linearGradient(
                    Gradient(colors: [Color(red: 1.0, green: 0.88, blue: 0.56), Color(red: 0.54, green: 0.36, blue: 0.12)]),
                    startPoint: CGPoint(x: rim.minX, y: rim.minY), endPoint: CGPoint(x: rim.maxX, y: rim.maxY)))
            }
        }
        // The lights, unveiled: warm glass in every porthole, the lamp.
        for port in portholes {
            let glass = CGRect(x: port.x - 2.8, y: port.y - 2.8, width: 5.6, height: 5.6)
            c.fill(Path(ellipseIn: glass), with: .radialGradient(
                Gradient(colors: [Color(red: 1.0, green: 0.95, blue: 0.70), Color(red: 0.98, green: 0.66, blue: 0.24)]),
                center: CGPoint(x: glass.midX - 0.8, y: glass.midY - 0.8), startRadius: 0, endRadius: 3.6))
            TankPaint.glow(&c, at: port, radius: 9, color: Color(red: 1.0, green: 0.84, blue: 0.46).opacity(0.28))
        }
        c.fill(Path(ellipseIn: CGRect(x: -48, y: 0, width: 5, height: 5)), with: .color(lamp))
        TankPaint.glow(&c, at: CGPoint(x: -45.5, y: 2.5), radius: 10, color: lamp.opacity(0.6))
        // Prop wash: a faint churn of bubbles behind.
        if !reduceMotion {
            for k in 0..<4 {
                let bp = frac(t * 1.4 + Double(k) / 4)
                drawBubble(canvas: &canvas, at: CGPoint(x: x + 62 + bp * 26, y: y - 2 + sin(bp * 7 + Double(k)) * 4 - bp * 8),
                           radius: 1 + bp * 1.4, alpha: (1 - bp) * 0.6 * presence)
            }
        }
    }

    // MARK: Stations

    /// Where a station stands in this tank, in unit space — resolved from
    /// the decor actually drawn (the density's prefix, the shop's owned
    /// pieces), so a fish never works at a landmark that isn't there.
    /// nil when the tank has nothing to stand in for it: the fish keeps
    /// its patrol rather than working at an invisible spot.
    func stationAnchor(_ station: TankStation, for fish: Fish, in size: CGSize,
                               density: Double, bounds: SwimBounds) -> AquariumStations.Anchor? {
        let w = max(1, size.width), h = max(1, size.height)
        let shown = Int((Double(Self.decor.count) * min(1, density)).rounded(.up))
        let visible = Self.decor.filter { $0.id < shown }
        func first(_ kind: TankDecor.Kind) -> TankDecor? { visible.first { $0.kind == kind } }
        // Fish sharing a station spread over its pieces by seed.
        func pick(_ kind: TankDecor.Kind, deepOnly: Bool = false) -> TankDecor? {
            let list = visible.filter { $0.kind == kind && (!deepOnly || $0.depth <= 0.6) }
            return list.isEmpty ? nil : list[Int(fish.seed % UInt64(list.count))]
        }
        // The lowest line the steering lets a fish swim — just over the
        // sand, where the stones and the starfish are.
        let floor = bounds.maxY - 0.01
        func unitY(_ y: Double) -> Double { min(floor, max(bounds.minY + 0.02, y / h)) }
        switch station {
        case .kelp:
            guard let kelp = pick(.kelp, deepOnly: true) ?? pick(.kelp) else { return nil }
            return .init(x: decorX(kelp), y: unitY(decorBaseY(kelp, in: size) - h * 0.08),
                         spanX: 26 / w, spanY: min(0.30, 0.22 * (0.8 + kelp.scale * 0.25)))
        case .pebbles:
            guard let rock = pick(.rock) ?? pick(.shell) else { return nil }
            return .init(x: rock.x, y: floor, spanX: 30 / w, spanY: 0.04)
        case .chest:
            guard let chest = first(.chest) else { return nil }
            let lid = decorBaseY(chest, in: size) - 26 * chest.scale * Self.decorBoost - 16
            return .init(x: chest.x, y: unitY(lid), spanX: 40 / w, spanY: 0.04)
        case .current:
            // The bubble wall's curtain when the tank owns one, else the
            // column the chest burps up — both are real rising bubbles.
            if owns(.bubbleWall), let slot = AquariumModel.decorSlot(for: .bubbleWall) {
                return .init(x: slot.x, y: unitY(h * 0.45), spanX: 20 / w, spanY: 0.06)
            }
            guard let chest = first(.chest) else { return nil }
            return .init(x: chest.x, y: unitY(h * 0.40), spanX: 20 / w, spanY: 0.06)
        case .wreck:
            if owns(.shipwreck), let slot = AquariumModel.decorSlot(for: .shipwreck) {
                let hull = ownedBaseY(slot, in: size) - slot.h * h * 0.55
                return .init(x: slot.x, y: unitY(hull), spanX: slot.w * h / w * 0.55,
                             spanY: 0.07)
            }
            // No wreck bought: the coral stands in, then the chest.
            guard let piece = pick(.coral) ?? first(.chest) else { return nil }
            return .init(x: piece.x, y: unitY(decorBaseY(piece, in: size) - h * 0.12),
                         spanX: 60 / w, spanY: 0.06)
        case .bench:
            guard let star = first(.starfish) ?? first(.chest) else { return nil }
            return .init(x: star.x, y: floor, spanX: 34 / w, spanY: 0.04)
        case .survey:
            let marks = visible.filter {
                [.coral, .rock, .bottle, .shell, .starfish, .kelp].contains($0.kind)
            }
            guard marks.count >= 2 else { return nil }
            let a = Int(fish.seed % UInt64(marks.count))
            let b = (a + 1 + Int((fish.seed >> 8) % UInt64(marks.count - 1))) % marks.count
            let lane = min(floor, max(bounds.minY + 0.05, laneY(for: fish, in: size) / h))
            return .init(x: decorX(marks[a]), y: lane, spanX: 30 / w, spanY: 0.05,
                         altX: decorX(marks[b]), altY: lane)
        }
    }

    /// The work itself, drawn small at the fish while it is at its
    /// station — never words, never a meter: a forager's crumbs of kelp,
    /// the sand an editor stirs, the current streaming past a shell
    /// worker, an inspector's slow sonar ring, a glint on the chest's
    /// lid, and a finished test's bubble rising green or red. Reduce
    /// Motion keeps a still version of each so the tell survives.
    func drawStationCue(_ cue: FishCue, l: Layout, canvas: inout GraphicsContext,
                                size: CGSize, length: Double, height: Double,
                                t: Double, phase: Double) {
        let mouthX = l.x + l.facing * length * 0.45
        var c = canvas
        c.opacity = l.opacity
        func dot(_ x: Double, _ y: Double, _ r: Double, _ color: Color, _ alpha: Double) {
            c.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                   with: .color(color.opacity(alpha)))
        }
        func ring(_ x: Double, _ y: Double, _ r: Double, _ color: Color, _ alpha: Double,
                  width: Double = 0.8) {
            c.stroke(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                     with: .color(color.opacity(alpha)), lineWidth: width)
        }
        if let tone = cue.tone {
            // A finished test or build: one bubble rising off the fish,
            // tinted by the result — green passed, red failed.
            let tint = tone == .pass ? Color(red: 0.35, green: 0.88, blue: 0.52)
                : Color(red: 1.0, green: 0.38, blue: 0.36)
            let p = reduceMotion ? 0.3 : frac(t / 2.4 + phase / (.pi * 2))
            let r = 3.8 + p * 2.4
            let bx = l.x + l.facing * length * 0.1 + (reduceMotion ? 0 : sin(p * 9 + phase) * 2)
            let by = l.y - height * 0.6 - 6 - p * 34
            let alpha = reduceMotion ? 0.9 : 0.35 + (1 - p) * 0.6
            dot(bx, by, r, tint, alpha * 0.45)
            ring(bx, by, r, tint, alpha, width: 1.1)
            dot(bx - r * 0.35, by - r * 0.4, r * 0.25, .white, alpha * 0.8)
            return
        }
        switch cue.station {
        case .kelp:
            // Reading: two green crumbs drift off the mouth and fade.
            for k in 0..<2 {
                let p = reduceMotion ? 0.35 : frac(t / 1.6 + Double(k) * 0.5 + phase)
                let x = mouthX + l.facing * p * 9
                let y = l.y - 1 + p * 7 + (reduceMotion ? 0 : sin(p * 7 + Double(k)) * 1.5)
                dot(x, y, 1.1 + 0.4 * (1 - p), Color(red: 0.45, green: 0.78, blue: 0.40),
                    (reduceMotion ? 0.7 : (1 - p)) * 0.8)
            }
        case .pebbles:
            // Editing: little puffs of sand kicked up under the nose.
            let sand = sandTop(atX: mouthX, in: size)
            guard sand - (l.y + height * 0.5) < 60 else { return }
            for k in 0..<3 {
                let p = reduceMotion ? 0.3 : frac(t / 1.3 + Double(k) / 3 + phase)
                let x = mouthX + (Double(k) - 1) * 5 + l.facing * p * 4
                let y = sand - 3 - p * 12
                dot(x, y, 1.3 + p * 0.8, Color(red: 0.86, green: 0.78, blue: 0.60),
                    (reduceMotion ? 0.6 : (1 - p)) * 0.55)
            }
        case .current:
            // Running a command: the current streams past, small bubbles
            // rising across the body while the fish holds against it.
            for k in 0..<4 {
                let p = reduceMotion ? Double(k) / 4 : frac(t / 1.1 + Double(k) / 4 + phase)
                let x = l.x + (Double(k) - 1.5) * length * 0.22 + sin(p * 6 + Double(k)) * 1.5
                let y = l.y + height * 0.6 - p * height * 1.8
                ring(x, y, 1.0 + p * 1.1, .white, (reduceMotion ? 0.5 : sin(p * .pi)) * 0.55)
            }
        case .wreck:
            // Testing or building: a slow sonar ring off the fish as it
            // laps the structure.
            let p = reduceMotion ? 0.4 : frac(t / 2.8 + phase)
            let r = length * (0.45 + p * 0.9)
            c.stroke(Path(ellipseIn: CGRect(x: l.x - r, y: l.y - r * 0.55, width: r * 2, height: r * 1.1)),
                     with: .color(Color(red: 0.62, green: 0.86, blue: 1.0).opacity((1 - p) * 0.35)),
                     lineWidth: 0.9)
        case .chest:
            // Calling a tool server: a brass glint winks off the lid
            // below the fish.
            let p = reduceMotion ? 0.5 : frac(t / 1.9 + phase)
            let glow = sin(p * .pi)
            var g = c
            g.blendMode = .plusLighter
            g.opacity = l.opacity * glow * 0.8
            g.translateBy(x: l.x, y: l.y + height * 0.9)
            g.scaleBy(x: 4.5, y: 4.5)
            g.fill(Self.starPath, with: .color(Color(red: 1.0, green: 0.86, blue: 0.5)))
        case .survey:
            // Searching: a faint scan arc ahead of the nose.
            let p = reduceMotion ? 0.5 : frac(t / 1.5 + phase)
            var arc = Path()
            arc.addArc(center: CGPoint(x: mouthX, y: l.y), radius: 6 + p * 8,
                       startAngle: .radians(l.facing > 0 ? -0.6 : .pi - 0.6),
                       endAngle: .radians(l.facing > 0 ? 0.6 : .pi + 0.6), clockwise: false)
            c.stroke(arc, with: .color(.white.opacity((1 - p) * 0.4)), lineWidth: 0.8)
        case .bench:
            // Any other tool: a small bright tick at the mouth, working.
            let p = reduceMotion ? 0.5 : frac(t / 0.9 + phase)
            dot(mouthX + l.facing * 2, l.y, 1.2, .white, sin(p * .pi) * 0.6)
        }
    }

    /// AQ13's parallel markers: a working main session with several
    /// workers carries that many small motes circling close to its
    /// body — company, not a gauge: no track, no fill, just motes.
    func drawParallelMarkers(_ count: Int, l: Layout, canvas: inout GraphicsContext,
                                     length: Double, height: Double, t: Double, phase: Double) {
        guard count > 0 else { return }
        var c = canvas
        c.opacity = l.opacity * 0.7
        let rx = length * 0.72, ry = height * 0.95
        for k in 0..<count {
            let angle = (reduceMotion ? 0 : t * 0.9) + phase + Double(k) / Double(count) * .pi * 2
            let x = l.x + cos(angle) * rx
            let y = l.y + sin(angle) * ry * 0.6
            // Motes behind the body dim, so the ring reads as round.
            let front = sin(angle) > 0
            let r = front ? 1.7 : 1.3
            c.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                   with: .color(.white.opacity(front ? 0.75 : 0.35)))
        }
    }

    /// AQ15's token pass: a verified delegation hands a pellet from the
    /// parent to one of its fry — the first in its school — on a loop
    /// while the plan cites it. Only a real delegation event sets the
    /// action, so proximity never draws one.
    func drawTokenPasses(canvas: inout GraphicsContext, roster: [Fish],
                                 layouts: [String: Layout], t: Double, now: Date) {
        for parent in roster where !parent.isFry && parent.plan?.action == .tokenPass {
            guard let from = layouts[parent.id],
                  let fry = roster.first(where: { $0.isFry && $0.anchorID == parent.id }),
                  let to = layouts[fry.id] else { continue }
            let p = reduceMotion ? 0.5 : frac(t / 1.6 + Double(parent.seed & 0xFF) / 0xFF)
            let e = smooth(p)
            let x = from.x + (to.x - from.x) * e
            let y = from.y + (to.y - from.y) * e - sin(p * .pi) * 10
            var c = canvas
            c.opacity = min(from.opacity, to.opacity) * (reduceMotion ? 0.9 : sin(p * .pi))
            TankPaint.glow(&c, at: CGPoint(x: x, y: y), radius: 7,
                           color: Color(red: 1.0, green: 0.84, blue: 0.48).opacity(0.45))
            c.fill(Path(ellipseIn: CGRect(x: x - 2.4, y: y - 2.4, width: 4.8, height: 4.8)),
                   with: .radialGradient(
                       Gradient(colors: [Color(red: 1.0, green: 0.92, blue: 0.66), Color(red: 0.86, green: 0.58, blue: 0.24)]),
                       center: CGPoint(x: x - 0.8, y: y - 0.8), startRadius: 0, endRadius: 3))
        }
    }
}
