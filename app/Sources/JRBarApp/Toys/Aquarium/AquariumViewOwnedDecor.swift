import AppKit
import JRBarCore
import SwiftUI

/// The decor bought in the shop, back row then front row.
extension AquariumView {
    // MARK: Owned decor — back row

    /// How far into the water the two rows stand (0 the back of the bed
    /// … 1 the glass): the back row on the far dune takes a real veil,
    /// the front row on the near crest barely any.
    static let backRowDepth = 0.28
    static let frontRowDepth = 0.74

    /// Where an owned back-row piece roots: its slot's x on the far
    /// dune, or the near crest for the front row.
    func ownedBaseY(_ slot: AquariumModel.DecorSlot, in size: CGSize) -> Double {
        let x = slot.x * size.width
        return slot.back ? backDuneTop(atX: x, in: size) + 2
            : sandTop(atX: x, in: size) + 2
    }

    /// A bought piece's draw scale: its unit-space width grows into
    /// `slot.w` of the tank's height (the declared footprint), so the
    /// decor sizes follow the window like the kelp does.
    private func ownedScaleW(_ slot: AquariumModel.DecorSlot,
                             unitWidth: Double, in size: CGSize) -> Double {
        slot.w * size.height / unitWidth
    }

    /// Same, landing the piece's unit-space height on `slot.h` — for
    /// the tall-thin pieces (statue, columns, lamp).
    private func ownedScaleH(_ slot: AquariumModel.DecorSlot,
                             unitHeight: Double, in size: CGSize) -> Double {
        slot.h * size.height / unitHeight
    }

    /// A context at a slot's foot, in the piece's own units.
    private func slotContext(_ canvas: GraphicsContext, _ slot: AquariumModel.DecorSlot,
                             scale s: Double, in size: CGSize) -> GraphicsContext {
        var c = canvas
        c.translateBy(x: slot.x * size.width, y: ownedBaseY(slot, in: size))
        c.scaleBy(x: s, y: s)
        return c
    }

    /// The bought decor rooted on the far dune (docs/TOYS.md shop):
    /// shipwreck, amphora, statue, columns, volcano — still pieces
    /// behind the plants, baked in with the distance. Each sits in its
    /// own contact shadow, veiled by the water between it and the glass.
    func drawOwnedBackDecor(canvas: inout GraphicsContext, size: CGSize, t: Double) {
        guard let game else { return }
        func slot(_ item: ShopItem) -> AquariumModel.DecorSlot? {
            game.shows(item) ? AquariumModel.decorSlot(for: item) : nil
        }
        let veil = atmosphere(depth: Self.backRowDepth, t: t)
        if let s = slot(.shipwreck) { drawShipwreck(canvas: &canvas, size: size, slot: s, veil: veil) }
        if let s = slot(.amphora) { drawAmphora(canvas: &canvas, size: size, slot: s, veil: veil) }
        if let s = slot(.sunkenStatue) { drawStatue(canvas: &canvas, size: size, slot: s, veil: veil) }
        if let s = slot(.ruinedColumns) { drawColumns(canvas: &canvas, size: size, slot: s, veil: veil) }
        if let s = slot(.volcano) {
            drawVolcano(canvas: &canvas, size: size, slot: s, veil: veil,
                        lit: nightFactor(t: t) > 0.45 || isDarkTheme)
        }
        if let s = slot(.alienBeacon) { drawBeacon(canvas: &canvas, size: size, slot: s, t: t) }
    }

    /// A sunken hull: a listing, broken-backed ship on the dune — lit
    /// planking over a dark hold, a brass porthole, barnacles and weed
    /// along the waterline, a snapped mast still flying its tattered
    /// sail.
    private func drawShipwreck(canvas: inout GraphicsContext, size: CGSize,
                               slot: AquariumModel.DecorSlot, veil: TankPaint.Atmosphere) {
        let s = ownedScaleW(slot, unitWidth: 90, in: size)
        contactShadow(canvas: &canvas, x: slot.x * size.width, y: ownedBaseY(slot, in: size),
                      halfW: 44 * s)
        var c = slotContext(canvas, slot, scale: s, in: size)
        let woodLit = Color(red: 0.72, green: 0.54, blue: 0.34)
        let wood = Color(red: 0.46, green: 0.32, blue: 0.20)
        let woodDark = Color(red: 0.20, green: 0.13, blue: 0.08)
        let edge = woodDark.opacity(0.55)
        TankPaint.seat(&c, in: CGRect(x: -48, y: -66, width: 96, height: 68), unit: s,
                       atmosphere: veil, seed: 71) { c in
            // The snapped mast behind the hull, then its tattered sail.
            var mast = Path()
            mast.move(to: CGPoint(x: -8, y: -8))
            mast.addLine(to: CGPoint(x: -4.5, y: -8))
            mast.addLine(to: CGPoint(x: 8.5, y: -60))
            mast.addLine(to: CGPoint(x: 6.5, y: -63))
            mast.addLine(to: CGPoint(x: 5, y: -59))
            mast.addLine(to: CGPoint(x: 4, y: -62))
            mast.closeSubpath()
            TankPaint.cylinder(&c, mast, lit: woodLit, base: wood, shade: woodDark, outline: edge, lineWidth: 0.5)
            var yard = Path()
            yard.move(to: CGPoint(x: -10, y: -45))
            yard.addLine(to: CGPoint(x: 24, y: -51))
            c.stroke(yard, with: .color(woodDark), style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
            c.stroke(yard.offsetBy(dx: 0, dy: -0.4), with: .color(wood), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
            var sail = Path()
            sail.move(to: CGPoint(x: -8, y: -45))
            sail.addLine(to: CGPoint(x: 22, y: -50.5))
            sail.addQuadCurve(to: CGPoint(x: 17, y: -30), control: CGPoint(x: 24, y: -40))
            sail.addLine(to: CGPoint(x: 13, y: -34))
            sail.addLine(to: CGPoint(x: 10, y: -27))
            sail.addLine(to: CGPoint(x: 6, y: -33))
            sail.addLine(to: CGPoint(x: 1, y: -29))
            sail.addQuadCurve(to: CGPoint(x: -8, y: -45), control: CGPoint(x: -6, y: -36))
            sail.closeSubpath()
            // Two moth-eaten holes let the water through.
            sail.addEllipse(in: CGRect(x: 4, y: -44, width: 4, height: 3))
            sail.addEllipse(in: CGRect(x: 13, y: -41, width: 3, height: 4))
            c.fill(sail, with: .linearGradient(
                Gradient(colors: [Color(red: 0.92, green: 0.88, blue: 0.76).opacity(0.78),
                                  Color(red: 0.62, green: 0.58, blue: 0.48).opacity(0.60)]),
                startPoint: CGPoint(x: -8, y: -48), endPoint: CGPoint(x: 18, y: -30)),
                   style: FillStyle(eoFill: true))
            var folds = c
            folds.clip(to: sail, style: FillStyle(eoFill: true))
            var creases = Path()
            for k in 0..<3 {
                let fx = -2.0 + Double(k) * 7
                creases.move(to: CGPoint(x: fx, y: -48 + Double(k) * 0.6))
                creases.addQuadCurve(to: CGPoint(x: fx + 2, y: -30), control: CGPoint(x: fx + 3, y: -40))
            }
            folds.stroke(creases, with: .color(Color(red: 0.45, green: 0.40, blue: 0.32).opacity(0.35)), lineWidth: 0.8)
            // A slack stay from the masthead to the stern.
            var stay = Path()
            stay.move(to: CGPoint(x: 7, y: -58))
            stay.addQuadCurve(to: CGPoint(x: 40, y: -20), control: CGPoint(x: 28, y: -34))
            c.stroke(stay, with: .color(woodDark.opacity(0.5)), lineWidth: 0.5)

            // The hull: a wallowing bowl broken amidships.
            var hull = Path()
            hull.move(to: CGPoint(x: -45, y: -27))
            hull.addQuadCurve(to: CGPoint(x: -10, y: 0), control: CGPoint(x: -41, y: -4))
            hull.addLine(to: CGPoint(x: -4, y: -9))
            hull.addLine(to: CGPoint(x: 1, y: -4))
            hull.addLine(to: CGPoint(x: 5, y: -12))
            hull.addLine(to: CGPoint(x: 12, y: -8))
            hull.addQuadCurve(to: CGPoint(x: 45, y: -21), control: CGPoint(x: 30, y: -6))
            hull.addQuadCurve(to: CGPoint(x: 36, y: 0), control: CGPoint(x: 45, y: -8))
            hull.closeSubpath()
            TankPaint.solid(&c, hull, lit: woodLit, base: wood, shade: woodDark, outline: edge, lineWidth: 0.7, rim: 0.22)
            var inner = c
            inner.clip(to: hull)
            // Planking that follows the hull's sweep.
            var planks = Path()
            for k in 0..<6 {
                let y = -3.0 - Double(k) * 4.2
                planks.move(to: CGPoint(x: -46, y: y - 6))
                planks.addQuadCurve(to: CGPoint(x: 46, y: y - 4), control: CGPoint(x: 0, y: y + 5))
            }
            inner.stroke(planks, with: .color(woodDark.opacity(0.45)), lineWidth: 0.55)
            inner.stroke(planks.offsetBy(dx: 0, dy: 0.7), with: .color(woodLit.opacity(0.30)), lineWidth: 0.4)
            TankPaint.grain(&inner, hull, from: CGPoint(x: -44, y: -12), to: CGPoint(x: 44, y: -10),
                            spacing: 1.6, width: 0.22, seed: 71, color: woodDark.opacity(0.20))
            // The break: the dark hold with a rib or two showing.
            var hole = Path()
            hole.move(to: CGPoint(x: -7, y: -4))
            hole.addLine(to: CGPoint(x: -3, y: -10))
            hole.addLine(to: CGPoint(x: 1, y: -6))
            hole.addLine(to: CGPoint(x: 5, y: -13))
            hole.addLine(to: CGPoint(x: 11, y: -9))
            hole.addQuadCurve(to: CGPoint(x: -7, y: -4), control: CGPoint(x: 3, y: -1))
            hole.closeSubpath()
            inner.fill(hole, with: .linearGradient(
                Gradient(colors: [Color(red: 0.04, green: 0.04, blue: 0.05), Color(red: 0.14, green: 0.10, blue: 0.08)]),
                startPoint: CGPoint(x: 0, y: -12), endPoint: CGPoint(x: 0, y: -2)))
            var ribs = Path()
            for rx in [-2.0, 4.0] {
                ribs.move(to: CGPoint(x: rx, y: -12))
                ribs.addQuadCurve(to: CGPoint(x: rx + 1.5, y: -2), control: CGPoint(x: rx - 1.5, y: -6))
            }
            inner.stroke(ribs, with: .color(wood), lineWidth: 1)
            // A brass porthole near the bow.
            let port = CGRect(x: 25, y: -17, width: 6, height: 6)
            c.fill(Path(ellipseIn: port.insetBy(dx: -1.1, dy: -1.1)), with: .linearGradient(
                Gradient(colors: [Color(red: 0.98, green: 0.84, blue: 0.48), Color(red: 0.52, green: 0.36, blue: 0.12)]),
                startPoint: CGPoint(x: port.minX, y: port.minY), endPoint: CGPoint(x: port.maxX, y: port.maxY)))
            c.fill(Path(ellipseIn: port), with: .radialGradient(
                Gradient(colors: [Color(red: 0.36, green: 0.58, blue: 0.62), Color(red: 0.05, green: 0.10, blue: 0.12)]),
                center: CGPoint(x: port.midX - 1, y: port.midY - 1), startRadius: 0, endRadius: 3.5))
            c.fill(Path(ellipseIn: CGRect(x: port.minX + 1.2, y: port.minY + 1, width: 1.6, height: 1)),
                   with: .color(.white.opacity(0.7)))
            // The gunwale's rail along the top edge.
            var rail = Path()
            rail.move(to: CGPoint(x: -45, y: -27))
            rail.addQuadCurve(to: CGPoint(x: -10, y: -14), control: CGPoint(x: -28, y: -16))
            rail.move(to: CGPoint(x: 12, y: -10))
            rail.addQuadCurve(to: CGPoint(x: 45, y: -21), control: CGPoint(x: 30, y: -10))
            c.stroke(rail, with: .color(woodDark.opacity(0.85)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            c.stroke(rail.offsetBy(dx: 0, dy: -0.5), with: .color(woodLit.opacity(0.7)),
                     style: StrokeStyle(lineWidth: 0.5, lineCap: .round))
            // Barnacles and weed along the waterline.
            TankPaint.speckle(&c, hull, seed: 83, count: 26, size: 1.2,
                              dark: Color(red: 0.12, green: 0.12, blue: 0.10).opacity(0.25),
                              light: Color(red: 0.94, green: 0.92, blue: 0.84).opacity(0.55))
            TankPaint.moss(&c, clip: hull, from: -40, to: 40, y: 1, height: 5, seed: 89, fade: 0.9)
        }
    }

    /// The tipped storage jar — the octopus's home when it has one:
    /// glazed terracotta with a black-figure key band, two handles and
    /// a dark mouth.
    private func drawAmphora(canvas: inout GraphicsContext, size: CGSize,
                             slot: AquariumModel.DecorSlot, veil: TankPaint.Atmosphere) {
        let s = ownedScaleW(slot, unitWidth: 34, in: size)
        contactShadow(canvas: &canvas, x: slot.x * size.width, y: ownedBaseY(slot, in: size),
                      halfW: 22 * s)
        var c = slotContext(canvas, slot, scale: s, in: size)
        let clayLit = Color(red: 0.92, green: 0.64, blue: 0.42)
        let clay = Color(red: 0.70, green: 0.42, blue: 0.25)
        let clayDark = Color(red: 0.32, green: 0.17, blue: 0.10)
        let edge = clayDark.opacity(0.55)
        let figure = Color(red: 0.12, green: 0.07, blue: 0.05)
        TankPaint.seat(&c, in: CGRect(x: -42, y: -28, width: 54, height: 42), unit: s,
                       atmosphere: veil, seed: 97) { canvas in
            var c = canvas
            c.rotate(by: .radians(-1.15))
            // Handles first, behind the body.
            var handles = Path()
            handles.move(to: CGPoint(x: -9, y: -31))
            handles.addCurve(to: CGPoint(x: -12, y: -20), control1: CGPoint(x: -19, y: -33), control2: CGPoint(x: -19, y: -22))
            handles.move(to: CGPoint(x: 9, y: -31))
            handles.addCurve(to: CGPoint(x: 12, y: -20), control1: CGPoint(x: 19, y: -33), control2: CGPoint(x: 19, y: -22))
            c.stroke(handles, with: .color(clayDark), style: StrokeStyle(lineWidth: 3.0, lineCap: .round))
            c.stroke(handles.offsetBy(dx: -0.3, dy: -0.3), with: .color(clay), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
            var jar = Path()
            jar.move(to: CGPoint(x: -7, y: -34))
            jar.addCurve(to: CGPoint(x: -14, y: -8), control1: CGPoint(x: -16, y: -28), control2: CGPoint(x: -17, y: -15))
            jar.addQuadCurve(to: CGPoint(x: 0, y: 2), control: CGPoint(x: -10, y: 0))
            jar.addQuadCurve(to: CGPoint(x: 14, y: -8), control: CGPoint(x: 10, y: 0))
            jar.addCurve(to: CGPoint(x: 7, y: -34), control1: CGPoint(x: 17, y: -15), control2: CGPoint(x: 16, y: -28))
            jar.closeSubpath()
            TankPaint.cylinder(&c, jar, lit: clayLit, base: clay, shade: clayDark, outline: edge, lineWidth: 0.6)
            // The black-figure band: a key pattern between two rules.
            var band = c
            band.clip(to: jar)
            band.fill(Path(CGRect(x: -20, y: -21, width: 40, height: 7)), with: .color(figure.opacity(0.82)))
            var key = Path()
            var kx = -18.0
            while kx < 18 {
                key.move(to: CGPoint(x: kx, y: -15.5))
                key.addLine(to: CGPoint(x: kx, y: -19.5))
                key.addLine(to: CGPoint(x: kx + 3, y: -19.5))
                key.addLine(to: CGPoint(x: kx + 3, y: -17))
                key.addLine(to: CGPoint(x: kx + 1.5, y: -17))
                kx += 4.5
            }
            band.stroke(key, with: .color(clayLit.opacity(0.9)), lineWidth: 0.6)
            var rules = Path()
            rules.move(to: CGPoint(x: -20, y: -22.2)); rules.addLine(to: CGPoint(x: 20, y: -22.2))
            rules.move(to: CGPoint(x: -20, y: -12.6)); rules.addLine(to: CGPoint(x: 20, y: -12.6))
            band.stroke(rules, with: .color(figure.opacity(0.7)), lineWidth: 0.6)
            // The glaze's gloss.
            band.fill(Path(ellipseIn: CGRect(x: -10, y: -30, width: 4, height: 18)), with: .color(.white.opacity(0.22)))
            // Rim & the dark mouth the octopus watches from.
            let rim = Path(ellipseIn: CGRect(x: -9.5, y: -38, width: 19, height: 7))
            TankPaint.solid(&c, rim, lit: clayLit, base: clay, shade: clayDark, outline: edge, lineWidth: 0.5, rim: 0)
            c.fill(Path(ellipseIn: CGRect(x: -6.5, y: -36.6, width: 13, height: 4.4)),
                   with: .radialGradient(Gradient(colors: [.black, Color(red: 0.14, green: 0.07, blue: 0.05)]),
                                         center: CGPoint(x: 0, y: -34.4), startRadius: 0, endRadius: 7))
            TankPaint.speckle(&c, jar, seed: 97, count: 18, size: 1.0,
                              dark: clayDark.opacity(0.28), light: Color(red: 0.98, green: 0.94, blue: 0.84).opacity(0.35))
        }
    }

    /// A marble bust on a stepped plinth — someone important, once:
    /// curled hair, a strong brow and a chipped nose, draped shoulders,
    /// weed on the plinth.
    private func drawStatue(canvas: inout GraphicsContext, size: CGSize,
                            slot: AquariumModel.DecorSlot, veil: TankPaint.Atmosphere) {
        let s = ownedScaleH(slot, unitHeight: 45, in: size)
        contactShadow(canvas: &canvas, x: slot.x * size.width, y: ownedBaseY(slot, in: size),
                      halfW: 16 * s)
        var c = slotContext(canvas, slot, scale: s, in: size)
        let lit = Color(red: 0.95, green: 0.94, blue: 0.91)
        let base = Color(red: 0.74, green: 0.75, blue: 0.75)
        let shade = Color(red: 0.40, green: 0.43, blue: 0.47)
        let edge = shade.opacity(0.6)
        TankPaint.seat(&c, in: CGRect(x: -15, y: -46, width: 30, height: 47), unit: s,
                       atmosphere: veil, seed: 101) { c in
            // The stepped plinth.
            let foot = Path(roundedRect: CGRect(x: -14, y: -4, width: 28, height: 4), cornerRadius: 0.6)
            let block = Path(roundedRect: CGRect(x: -11.5, y: -16, width: 23, height: 12), cornerRadius: 0.6)
            TankPaint.solid(&c, foot, lit: lit, base: base, shade: shade, outline: edge, lineWidth: 0.4)
            TankPaint.solid(&c, block, lit: lit, base: base, shade: shade, outline: edge, lineWidth: 0.4)
            TankPaint.speckle(&c, block, seed: 101, count: 16, size: 0.9)
            var crack = Path()
            crack.move(to: CGPoint(x: 6, y: -16)); crack.addLine(to: CGPoint(x: 4, y: -12))
            crack.addLine(to: CGPoint(x: 6.5, y: -9)); crack.addLine(to: CGPoint(x: 5, y: -5))
            c.stroke(crack, with: .color(shade), lineWidth: 0.45)
            // Shoulders under a drape.
            var bust = Path()
            bust.move(to: CGPoint(x: -11, y: -16))
            bust.addQuadCurve(to: CGPoint(x: -6, y: -28), control: CGPoint(x: -12, y: -26))
            bust.addQuadCurve(to: CGPoint(x: 6, y: -28), control: CGPoint(x: 0, y: -31))
            bust.addQuadCurve(to: CGPoint(x: 11, y: -16), control: CGPoint(x: 12, y: -26))
            bust.closeSubpath()
            TankPaint.cylinder(&c, bust, lit: lit, base: base, shade: shade, outline: edge, lineWidth: 0.45)
            var folds = c
            folds.clip(to: bust)
            var drape = Path()
            for k in 0..<3 {
                let o = Double(k) * 3
                drape.move(to: CGPoint(x: -9 + o, y: -26 + o * 0.3))
                drape.addQuadCurve(to: CGPoint(x: 2 + o, y: -16), control: CGPoint(x: -4 + o, y: -18))
            }
            folds.stroke(drape, with: .color(shade.opacity(0.6)), lineWidth: 0.55)
            folds.stroke(drape.offsetBy(dx: -0.6, dy: -0.4), with: .color(.white.opacity(0.35)), lineWidth: 0.35)
            // The neck and head.
            let neck = Path(CGRect(x: -2.6, y: -32, width: 5.2, height: 5))
            TankPaint.cylinder(&c, neck, lit: lit, base: base, shade: shade, outline: edge, lineWidth: 0.35)
            let head = Path(ellipseIn: CGRect(x: -6, y: -45, width: 12, height: 14.5))
            TankPaint.cylinder(&c, head, lit: lit, base: base, shade: shade, outline: edge, lineWidth: 0.45)
            // Curls across the crown.
            var curls = Path()
            for (cx, cy) in [(-4.5, -42.5), (-2.0, -44.2), (1.0, -44.6), (3.8, -43.4), (-5.5, -39.5)] as [(Double, Double)] {
                curls.addEllipse(in: CGRect(x: cx - 1.5, y: cy - 1.3, width: 3, height: 2.6))
            }
            c.fill(curls, with: .color(base))
            c.stroke(curls, with: .color(shade.opacity(0.8)), lineWidth: 0.35)
            // The face: a brow's shadow, closed eyes, a chipped nose, lips.
            var face = c
            face.clip(to: head)
            face.fill(Path(ellipseIn: CGRect(x: -1, y: -40.2, width: 6, height: 2.2)), with: .color(shade.opacity(0.40)))
            var eye = Path()
            eye.move(to: CGPoint(x: 0.4, y: -38.6)); eye.addQuadCurve(to: CGPoint(x: 3.2, y: -38.6), control: CGPoint(x: 1.8, y: -37.8))
            face.stroke(eye, with: .color(shade), lineWidth: 0.45)
            var nose = Path()
            nose.move(to: CGPoint(x: 4, y: -38.5))
            nose.addLine(to: CGPoint(x: 6.3, y: -35.3))
            nose.addLine(to: CGPoint(x: 5.2, y: -34.9))
            c.stroke(nose, with: .color(shade), style: StrokeStyle(lineWidth: 0.5, lineJoin: .round))
            var lips = Path()
            lips.move(to: CGPoint(x: 2.6, y: -33.4)); lips.addQuadCurve(to: CGPoint(x: 4.8, y: -33.2), control: CGPoint(x: 3.7, y: -32.8))
            face.stroke(lips, with: .color(shade), lineWidth: 0.4)
            face.stroke(Path(ellipseIn: CGRect(x: -3.2, y: -39, width: 2.2, height: 3.4)), with: .color(shade.opacity(0.7)),
                        lineWidth: 0.4)
            // Weed on the plinth and a little on the shoulders.
            TankPaint.moss(&c, clip: block, from: -12, to: 12, y: -4, height: 3.2, seed: 107, fade: 0.8)
            TankPaint.moss(&c, clip: bust, from: -11, to: -3, y: -16, height: 2.4, seed: 109, fade: 0.6)
            TankPaint.moss(&c, clip: nil, from: -15, to: 15, y: 0.4, height: 2.6, seed: 113)
        }
    }

    /// The ruin: two fluted columns on their bases — one whole under
    /// its capital, one snapped — and a fallen drum out front, marble
    /// lit from the surface, weed at every foot.
    private func drawColumns(canvas: inout GraphicsContext, size: CGSize,
                             slot: AquariumModel.DecorSlot, veil: TankPaint.Atmosphere) {
        let s = ownedScaleH(slot, unitHeight: 72, in: size)
        contactShadow(canvas: &canvas, x: slot.x * size.width, y: ownedBaseY(slot, in: size),
                      halfW: 46 * s)
        var c = slotContext(canvas, slot, scale: s, in: size)
        let lit = Color(red: 0.96, green: 0.95, blue: 0.92)
        let base = Color(red: 0.76, green: 0.76, blue: 0.76)
        let shade = Color(red: 0.40, green: 0.43, blue: 0.48)
        let edge = shade.opacity(0.6)
        TankPaint.seat(&c, in: CGRect(x: -40, y: -72, width: 96, height: 73), unit: s,
                       atmosphere: veil, seed: 131) { c in
            // Standing: x, height, whole (capital) or snapped.
            let standing: [(x: Double, h: Double, whole: Bool)] = [(-28, 50, false), (-4, 64, true)]
            for col in standing {
                // Base: a torus over a square plinth.
                let plinth = Path(CGRect(x: col.x - 9, y: -4, width: 18, height: 4))
                TankPaint.solid(&c, plinth, lit: lit, base: base, shade: shade, outline: edge, lineWidth: 0.4)
                let torus = Path(roundedRect: CGRect(x: col.x - 8, y: -7, width: 16, height: 3.4), cornerRadius: 1.7)
                TankPaint.cylinder(&c, torus, lit: lit, base: base, shade: shade, outline: edge, lineWidth: 0.35)
                // The shaft, a little narrower at the top.
                var shaft = Path()
                let top = -col.h
                shaft.move(to: CGPoint(x: col.x - 6.5, y: -7))
                shaft.addLine(to: CGPoint(x: col.x - 5.8, y: top))
                if col.whole {
                    shaft.addLine(to: CGPoint(x: col.x + 5.8, y: top))
                } else {
                    // A snapped top, jagged.
                    shaft.addLine(to: CGPoint(x: col.x - 3, y: top - 3))
                    shaft.addLine(to: CGPoint(x: col.x - 0.5, y: top + 1.5))
                    shaft.addLine(to: CGPoint(x: col.x + 2.5, y: top - 1.5))
                    shaft.addLine(to: CGPoint(x: col.x + 5.9, y: top + 3))
                }
                shaft.addLine(to: CGPoint(x: col.x + 6.5, y: -7))
                shaft.closeSubpath()
                TankPaint.cylinder(&c, shaft, lit: lit, base: base, shade: shade, outline: edge, lineWidth: 0.45)
                // Flutes: a dark groove with a lit edge beside it.
                var flutes = c
                flutes.clip(to: shaft)
                var grooves = Path()
                var lips = Path()
                for k in -2...2 {
                    let fx = col.x + Double(k) * 2.4
                    grooves.move(to: CGPoint(x: fx, y: top - 3)); grooves.addLine(to: CGPoint(x: fx, y: -7))
                    lips.move(to: CGPoint(x: fx + 0.6, y: top - 3)); lips.addLine(to: CGPoint(x: fx + 0.6, y: -7))
                }
                flutes.stroke(grooves, with: .color(shade.opacity(0.45)), lineWidth: 0.55)
                flutes.stroke(lips, with: .color(.white.opacity(0.30)), lineWidth: 0.35)
                TankPaint.speckle(&c, shaft, seed: UInt64(col.h) &* 131, count: 14, size: 0.9)
                if col.whole {
                    // An Ionic capital: echinus, abacus and two volutes.
                    let echinus = Path(roundedRect: CGRect(x: col.x - 7.5, y: top - 3, width: 15, height: 3.2),
                                       cornerRadius: 1.4)
                    TankPaint.cylinder(&c, echinus, lit: lit, base: base, shade: shade, outline: edge, lineWidth: 0.35)
                    let abacus = Path(CGRect(x: col.x - 9.5, y: top - 6, width: 19, height: 3))
                    TankPaint.solid(&c, abacus, lit: lit, base: base, shade: shade, outline: edge, lineWidth: 0.4)
                    for side in [-1.0, 1.0] {
                        let vc = CGPoint(x: col.x + side * 8, y: top - 1.8)
                        let volute = Path(ellipseIn: CGRect(x: vc.x - 2.4, y: vc.y - 2.4, width: 4.8, height: 4.8))
                        TankPaint.solid(&c, volute, lit: lit, base: base, shade: shade, outline: edge, lineWidth: 0.35, rim: 0.2)
                        var spiral = Path()
                        spiral.addArc(center: vc, radius: 1.2, startAngle: .degrees(0), endAngle: .degrees(300), clockwise: false)
                        c.stroke(spiral, with: .color(shade), lineWidth: 0.35)
                    }
                }
                TankPaint.moss(&c, clip: shaft, from: col.x - 7, to: col.x + 7, y: -7, height: 4,
                               seed: UInt64(col.h) &+ 5, fade: 0.8)
            }
            TankPaint.moss(&c, clip: nil, from: -40, to: 8, y: 0.4, height: 2.8, seed: 139)
            // The fallen drum lying out front, its fluted end toward us.
            var fallen = c
            fallen.translateBy(x: 34, y: -6)
            fallen.rotate(by: .radians(0.16))
            let drum = Path(roundedRect: CGRect(x: -20, y: -7, width: 38, height: 14), cornerRadius: 3)
            TankPaint.solid(&fallen, drum, lit: lit, base: base, shade: shade, outline: edge, lineWidth: 0.4)
            var drumFlutes = fallen
            drumFlutes.clip(to: drum)
            var lines = Path()
            for k in -2...2 {
                lines.move(to: CGPoint(x: -20, y: Double(k) * 2.4)); lines.addLine(to: CGPoint(x: 18, y: Double(k) * 2.4))
            }
            drumFlutes.stroke(lines, with: .color(shade.opacity(0.40)), lineWidth: 0.5)
            let end = Path(ellipseIn: CGRect(x: 14, y: -7, width: 8, height: 14))
            fallen.fill(end, with: .radialGradient(Gradient(colors: [lit, base]),
                                                   center: CGPoint(x: 17, y: -2), startRadius: 0, endRadius: 8))
            var scallops = Path()
            for k in 0..<10 {
                let a = Double(k) / 10 * .pi * 2
                scallops.addEllipse(in: CGRect(x: 18 + cos(a) * 3.2 - 0.6, y: sin(a) * 6 - 0.6, width: 1.2, height: 1.2))
            }
            fallen.fill(scallops, with: .color(shade.opacity(0.45)))
            fallen.stroke(end, with: .color(edge), lineWidth: 0.4)
            TankPaint.moss(&fallen, clip: drum, from: -18, to: 16, y: 7, height: 3, seed: 149, fade: 0.8)
        }
    }

    /// The cone: a broad shield with a rimmed crater bowl. Its throat
    /// always smoulders a little — a warm inner glow at any hour that
    /// goes molten at night (or in the dark themes), when the live
    /// pass's `drawVolcanoGlow` adds the halo and the ember climb. The
    /// glow is light, so it draws over the veil, never under it.
    private func drawVolcano(canvas: inout GraphicsContext, size: CGSize,
                             slot: AquariumModel.DecorSlot, veil: TankPaint.Atmosphere, lit: Bool) {
        let s = ownedScaleW(slot, unitWidth: 84, in: size)
        contactShadow(canvas: &canvas, x: slot.x * size.width, y: ownedBaseY(slot, in: size),
                      halfW: 40 * s)
        var c = slotContext(canvas, slot, scale: s, in: size)
        let bowl = Path(ellipseIn: CGRect(x: -14, y: -50, width: 28, height: 11))
        TankPaint.seat(&c, in: CGRect(x: -43, y: -52, width: 86, height: 53), unit: s,
                       atmosphere: veil, seed: 151) { c in
            // The cone silhouette: a broad base sweeping to a flat rim,
            // a shoulder kink each side so it reads as rock, not sand.
            var cone = Path()
            cone.move(to: CGPoint(x: -42, y: 0))
            cone.addQuadCurve(to: CGPoint(x: -30, y: -26), control: CGPoint(x: -40, y: -18))
            cone.addQuadCurve(to: CGPoint(x: -13, y: -44), control: CGPoint(x: -24, y: -40))
            cone.addLine(to: CGPoint(x: 13, y: -44))
            cone.addQuadCurve(to: CGPoint(x: 30, y: -26), control: CGPoint(x: 24, y: -40))
            cone.addQuadCurve(to: CGPoint(x: 42, y: 0), control: CGPoint(x: 40, y: -18))
            cone.closeSubpath()
            TankPaint.solid(&c, cone, lit: Color(red: 0.52, green: 0.46, blue: 0.44),
                            base: Color(red: 0.30, green: 0.26, blue: 0.25),
                            shade: Color(red: 0.12, green: 0.10, blue: 0.10),
                            outline: Color(red: 0.10, green: 0.08, blue: 0.08).opacity(0.5), lineWidth: 0.8)
            // Basalt: pitted, with a few old flows banding the flanks.
            TankPaint.speckle(&c, cone, seed: 151, count: 60, size: 1.4,
                              dark: .black.opacity(0.24), light: Color(red: 0.85, green: 0.75, blue: 0.65).opacity(0.14))
            var strata = c
            strata.clip(to: cone)
            var bands = Path()
            for k in 0..<3 {
                let y = -12.0 - Double(k) * 9
                bands.move(to: CGPoint(x: -44, y: y + 3))
                bands.addQuadCurve(to: CGPoint(x: 44, y: y + 2), control: CGPoint(x: 0, y: y - 3))
            }
            strata.stroke(bands, with: .color(.black.opacity(0.16)), lineWidth: 1.1)
            strata.stroke(bands.offsetBy(dx: 0, dy: -1), with: .color(.white.opacity(0.06)), lineWidth: 0.6)
            TankPaint.moss(&c, clip: cone, from: -40, to: 40, y: 0.5, height: 4, seed: 157, fade: 0.7)
            // Flank shading: darker seams running down from the rim.
            var seams = Path()
            for k in [-1.0, 1.0] {
                seams.move(to: CGPoint(x: k * 12, y: -42))
                seams.addQuadCurve(to: CGPoint(x: k * 32, y: -4), control: CGPoint(x: k * 20, y: -24))
            }
            strata.stroke(seams, with: .color(.black.opacity(0.18)), lineWidth: 1.4)
            // The crater bowl, dark until the heat shows.
            c.fill(bowl, with: .color(lit ? Color(red: 0.55, green: 0.14, blue: 0.05)
                                          : Color(red: 0.12, green: 0.09, blue: 0.09)))
            c.stroke(bowl, with: .color(.black.opacity(0.35)), lineWidth: 0.7)
        }
        // The smoulder: a warm breath in the throat at every hour,
        // molten once lit, and the lava's old path down the face.
        var g = c
        g.blendMode = .plusLighter
        g.fill(bowl, with: .radialGradient(
            Gradient(colors: [Color(red: 1.0, green: 0.5, blue: 0.12).opacity(lit ? 0.95 : 0.28), .clear]),
            center: CGPoint(x: 0, y: -45), startRadius: 0, endRadius: 18))
        var lava = Path()
        lava.move(to: CGPoint(x: 4, y: -42))
        lava.addQuadCurve(to: CGPoint(x: 12, y: -12), control: CGPoint(x: 8, y: -26))
        c.stroke(lava, with: .color(Color(red: 0.95, green: 0.36, blue: 0.10).opacity(lit ? 0.85 : 0.14)),
                 style: StrokeStyle(lineWidth: 2.0, lineCap: .round))
    }

    /// The live side of the owned decor: the volcano's ember drift
    /// (only when the crater's lit — night or a dark theme).
    private func drawVolcanoGlow(canvas: inout GraphicsContext, size: CGSize,
                                 t: Double, slot: AquariumModel.DecorSlot) {
        let x = slot.x * size.width
        let s = ownedScaleW(slot, unitWidth: 84, in: size)
        let craterY = ownedBaseY(slot, in: size) - 45 * s
        var g = canvas
        g.blendMode = .plusLighter
        g.fill(Path(ellipseIn: CGRect(x: x - 40 * s, y: craterY - 40 * s,
                                      width: 80 * s, height: 80 * s)),
               with: .radialGradient(
                   Gradient(colors: [Color(red: 1.0, green: 0.42, blue: 0.12).opacity(0.30), .clear]),
                   center: CGPoint(x: x, y: craterY), startRadius: 0,
                   endRadius: 40 * s))
        guard !reduceMotion else { return }
        for i in 0..<5 {
            var h = AquariumModel.stableHash("ember-\(i)")
            h ^= h >> 33; h &*= 0xff51afd7ed558ccd; h ^= h >> 33
            let period = 4 + Double(h & 0xF) * 0.4
            let p = frac(t / period + Double((h >> 8) & 0xFF) / 0xFF)
            let ex = x + (Double((h >> 16) & 0xFF) / 0xFF - 0.5) * 18 * s
                + sin(p * 5 + Double(i)) * 5 * s
            let ey = craterY - p * 55 * s
            let er = (1.2 + Double((h >> 24) & 0x3) * 0.5) * s
            var e = canvas
            e.blendMode = .plusLighter
            e.opacity = (1 - p) * 0.9
            e.fill(Path(ellipseIn: CGRect(x: ex - er * 2.5, y: ey - er * 2.5,
                                          width: er * 5, height: er * 5)),
                   with: .radialGradient(
                       Gradient(colors: [Color(red: 1.0, green: 0.62, blue: 0.22), Color(red: 1.0, green: 0.35, blue: 0.08).opacity(0)]),
                       center: CGPoint(x: ex, y: ey), startRadius: 0, endRadius: er * 2.5))
        }
    }

    // MARK: Owned decor — front row

    /// The bought decor on the near crest (docs/TOYS.md shop), the
    /// half that moves: the anemone's swaying bed, the jelly lamp's
    /// pulsing dome, the bubble wall's curtain and a lit volcano's
    /// glow, drawn over the fish lane. The still pieces bake into the
    /// near bed behind it (`drawOwnedFrontStill`).
    func drawOwnedFrontDecor(canvas: inout GraphicsContext, size: CGSize, t: Double) {
        guard let game else { return }
        func slot(_ item: ShopItem) -> AquariumModel.DecorSlot? {
            game.shows(item) ? AquariumModel.decorSlot(for: item) : nil
        }
        let tone = decorTone()
        if let s = slot(.anemoneBed) { drawAnemone(canvas: &canvas, size: size, t: t, slot: s, tone: tone) }
        if let s = slot(.moonJellyLamp) { drawJellyLamp(canvas: &canvas, size: size, t: t, slot: s, tone: tone) }
        if let s = slot(.bubbleWall) { drawBubbleWall(canvas: &canvas, size: size, t: t, slot: s) }
        // The volcano's live half rides along when the crater's lit.
        if let s = game.shows(.volcano) ? AquariumModel.decorSlot(for: .volcano) : nil,
           nightFactor(t: t) > 0.45 || isDarkTheme {
            drawVolcanoGlow(canvas: &canvas, size: size, t: t, slot: s)
        }
    }

    /// The front-row pieces that never move — the driftwood, the coral
    /// garden, the bubble wall's air stone — baked into the near bed
    /// with the rest, so the live pass only pays for what sways.
    func drawOwnedFrontStill(canvas: inout GraphicsContext, size: CGSize, t: Double) {
        guard let game else { return }
        func slot(_ item: ShopItem) -> AquariumModel.DecorSlot? {
            game.shows(item) ? AquariumModel.decorSlot(for: item) : nil
        }
        let veil = atmosphere(depth: Self.frontRowDepth, t: t)
        if let s = slot(.driftwood) { drawDriftwood(canvas: &canvas, size: size, slot: s, veil: veil) }
        if let s = slot(.coralGarden) { drawCoralGarden(canvas: &canvas, size: size, slot: s, veil: veil) }
        if let s = slot(.bubbleWall) { drawAirStone(canvas: &canvas, size: size, slot: s, veil: veil) }
    }

    /// A water-logged branch half settled into the sand: silvered,
    /// grained wood lit along its top, a forked stub, a knot, weed
    /// where it meets the bed.
    private func drawDriftwood(canvas: inout GraphicsContext, size: CGSize,
                               slot: AquariumModel.DecorSlot, veil: TankPaint.Atmosphere) {
        let s = ownedScaleW(slot, unitWidth: 60, in: size)
        contactShadow(canvas: &canvas, x: slot.x * size.width, y: ownedBaseY(slot, in: size),
                      halfW: 30 * s)
        var c = slotContext(canvas, slot, scale: s, in: size)
        let lit = Color(red: 0.86, green: 0.78, blue: 0.66)
        let wood = Color(red: 0.58, green: 0.49, blue: 0.38)
        let dark = Color(red: 0.26, green: 0.20, blue: 0.15)
        let edge = dark.opacity(0.55)
        TankPaint.seat(&c, in: CGRect(x: -31, y: -29, width: 64, height: 31), unit: s,
                       atmosphere: veil, seed: 163) { c in
            // The forked stub first, behind the log.
            var stub = Path()
            stub.move(to: CGPoint(x: -11, y: -9))
            stub.addQuadCurve(to: CGPoint(x: -19, y: -27), control: CGPoint(x: -12, y: -20))
            stub.addLine(to: CGPoint(x: -16, y: -28))
            stub.addQuadCurve(to: CGPoint(x: -5, y: -11), control: CGPoint(x: -8, y: -19))
            stub.closeSubpath()
            TankPaint.solid(&c, stub, lit: lit, base: wood, shade: dark, outline: edge, lineWidth: 0.5)
            TankPaint.grain(&c, stub, from: CGPoint(x: -8, y: -10), to: CGPoint(x: -18, y: -27),
                            spacing: 1.3, width: 0.25, seed: 163, color: dark.opacity(0.30))
            var log = Path()
            log.move(to: CGPoint(x: -30, y: -3))
            log.addQuadCurve(to: CGPoint(x: -18, y: -10), control: CGPoint(x: -28, y: -9))
            log.addQuadCurve(to: CGPoint(x: 26, y: -15), control: CGPoint(x: 4, y: -16))
            log.addQuadCurve(to: CGPoint(x: 31, y: -7), control: CGPoint(x: 31, y: -13))
            log.addQuadCurve(to: CGPoint(x: -26, y: 1), control: CGPoint(x: 2, y: -2))
            log.closeSubpath()
            TankPaint.solid(&c, log, lit: lit, base: wood, shade: dark, outline: edge, lineWidth: 0.6, rim: 0.4)
            TankPaint.grain(&c, log, from: CGPoint(x: -28, y: -4), to: CGPoint(x: 30, y: -11),
                            spacing: 1.5, width: 0.28, seed: 167, color: dark.opacity(0.30))
            // A knot, and the broken end's rings.
            let knot = Path(ellipseIn: CGRect(x: 4, y: -12, width: 5, height: 3.2))
            c.fill(knot, with: .radialGradient(Gradient(colors: [dark, wood]),
                                               center: CGPoint(x: 6.5, y: -10.4), startRadius: 0, endRadius: 3))
            let end = Path(ellipseIn: CGRect(x: 27, y: -14, width: 5, height: 8))
            c.fill(end, with: .color(Color(red: 0.80, green: 0.68, blue: 0.52)))
            c.stroke(Path(ellipseIn: CGRect(x: 28.2, y: -12, width: 2.6, height: 4.4)),
                     with: .color(dark.opacity(0.5)), lineWidth: 0.35)
            c.stroke(end, with: .color(edge), lineWidth: 0.4)
            TankPaint.moss(&c, clip: log, from: -28, to: 28, y: 1, height: 3, seed: 173, fade: 0.8)
        }
    }

    /// A bed of anemones: fat columns under crowns of tentacles that
    /// sway in a slow wave, each tentacle lit along its length with a
    /// glowing tip — the live pass keeps them breathing; Reduce Motion
    /// holds a soft lean.
    private func drawAnemone(canvas: inout GraphicsContext, size: CGSize,
                             t: Double, slot: AquariumModel.DecorSlot, tone: TankPaint.Tone) {
        let s = ownedScaleW(slot, unitWidth: 44, in: size)
        contactShadow(canvas: &canvas, x: slot.x * size.width, y: ownedBaseY(slot, in: size),
                      halfW: 24 * s)
        var c = slotContext(canvas, slot, scale: s, in: size)
        let still = reduceMotion
        // Two anemones: one rose, one violet, the smaller behind.
        let heads: [(x: Double, r: Double, lit: Color, deep: Color, tip: Color, seed: String)] = [
            (8, 9, tone(Color(red: 0.74, green: 0.56, blue: 0.96)), tone(Color(red: 0.36, green: 0.18, blue: 0.54)),
             tone(Color(red: 0.94, green: 0.88, blue: 1.0)), "anemone-b"),
            (-7, 12, tone(Color(red: 1.0, green: 0.58, blue: 0.64)), tone(Color(red: 0.58, green: 0.18, blue: 0.30)),
             tone(Color(red: 1.0, green: 0.92, blue: 0.82)), "anemone"),
        ]
        for head in heads {
            // The column.
            var column = Path()
            column.move(to: CGPoint(x: head.x - head.r * 0.55, y: 0))
            column.addQuadCurve(to: CGPoint(x: head.x - head.r * 0.8, y: -head.r * 0.9),
                                control: CGPoint(x: head.x - head.r * 0.45, y: -head.r * 0.45))
            column.addLine(to: CGPoint(x: head.x + head.r * 0.8, y: -head.r * 0.9))
            column.addQuadCurve(to: CGPoint(x: head.x + head.r * 0.55, y: 0),
                                control: CGPoint(x: head.x + head.r * 0.45, y: -head.r * 0.45))
            column.closeSubpath()
            TankPaint.cylinder(&c, column, lit: head.lit.opacity(0.95), base: head.deep.opacity(0.95),
                               shade: head.deep, outline: head.deep.opacity(0.5), lineWidth: 0.4)
            let count = Int(head.r * 1.4)
            // All of one head's tentacles go down in three strokes and
            // one fill — the live pass pays per call, not per tentacle.
            var tentacles = Path()
            var tips = Path()
            for i in 0..<count {
                let h = scatter(AquariumModel.stableHash(head.seed), i)
                let u = Double(i) / Double(max(1, count - 1)) - 0.5
                let rootX = head.x + u * head.r * 1.5
                let rootY = -head.r * 0.85
                let reach = head.r * (0.9 + Double((h >> 8) & 0xFF) / 0xFF * 0.8)
                let lean = u * head.r * 1.6 + (Double((h >> 16) & 0xFF) / 0xFF - 0.5) * 4
                let sway = still ? 1.5
                    : sin(t * 1.25 + u * 2.4 + Double((h >> 24) & 0xFF) * 0.02) * 3.2
                let tip = CGPoint(x: rootX + lean + sway, y: rootY - reach)
                tentacles.move(to: CGPoint(x: rootX, y: rootY))
                tentacles.addQuadCurve(to: tip,
                                       control: CGPoint(x: rootX + lean * 0.2, y: rootY - reach * 0.6))
                tips.addEllipse(in: CGRect(x: tip.x - 1.4, y: tip.y - 1.4, width: 2.8, height: 2.8))
            }
            let crown = -head.r * 0.85 - head.r * 1.7
            c.stroke(tentacles, with: .color(head.deep.opacity(0.85)),
                     style: StrokeStyle(lineWidth: 2.8, lineCap: .round))
            c.stroke(tentacles, with: .linearGradient(
                Gradient(colors: [head.deep, head.lit]),
                startPoint: CGPoint(x: head.x, y: -head.r * 0.85), endPoint: CGPoint(x: head.x, y: crown)),
                     style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
            TankPaint.glow(&c, at: CGPoint(x: head.x, y: crown + head.r * 0.4), radius: head.r * 1.6,
                           color: head.tip.opacity(0.20))
            c.fill(tips, with: .color(head.tip))
        }
    }

    /// A glass dome on a turned brass base with a moon jelly inside;
    /// its glow breathes on a six-second pulse, additive, and the
    /// glass catches a highlight.
    private func drawJellyLamp(canvas: inout GraphicsContext, size: CGSize,
                               t: Double, slot: AquariumModel.DecorSlot, tone: TankPaint.Tone) {
        let s = ownedScaleH(slot, unitHeight: 52, in: size)
        contactShadow(canvas: &canvas, x: slot.x * size.width, y: ownedBaseY(slot, in: size),
                      halfW: 12 * s)
        let pulse = reduceMotion ? 0.6 : 0.55 + 0.45 * sin(t * .pi * 2 / 6)
        var c = slotContext(canvas, slot, scale: s, in: size)
        let glowColor = Color(red: 0.55, green: 0.85, blue: 0.98)
        // The glow first — under the glass it reads as coming through.
        TankPaint.glow(&c, at: CGPoint(x: 0, y: -24), radius: 28, color: glowColor.opacity(0.30 * pulse + 0.08))
        // The brass base: a turned foot and a collar.
        let foot = Path(roundedRect: CGRect(x: -11, y: -4, width: 22, height: 4), cornerRadius: 1.5)
        let collar = Path(roundedRect: CGRect(x: -9, y: -8, width: 18, height: 4.5), cornerRadius: 1.2)
        let brassLit = tone(Color(red: 1.0, green: 0.88, blue: 0.54))
        let brass = tone(Color(red: 0.76, green: 0.57, blue: 0.26))
        let brassDark = tone(Color(red: 0.36, green: 0.24, blue: 0.09))
        TankPaint.cylinder(&c, foot, lit: brassLit, base: brass, shade: brassDark, outline: brassDark.opacity(0.6), lineWidth: 0.4)
        TankPaint.cylinder(&c, collar, lit: brassLit, base: brass, shade: brassDark, outline: brassDark.opacity(0.6), lineWidth: 0.4)
        // The dome.
        var dome = Path()
        dome.move(to: CGPoint(x: -9.5, y: -8))
        dome.addCurve(to: CGPoint(x: 9.5, y: -8),
                      control1: CGPoint(x: -11, y: -46), control2: CGPoint(x: 11, y: -46))
        dome.closeSubpath()
        c.fill(dome, with: .linearGradient(
            Gradient(colors: [glowColor.opacity(0.10), glowColor.opacity(0.26)]),
            startPoint: CGPoint(x: 0, y: -38), endPoint: CGPoint(x: 0, y: -8)))
        // The jelly: a bell & four trailing arms, brighter on the pulse.
        let bob = reduceMotion ? 0 : sin(t * .pi * 2 / 6) * 1.2
        var bell = Path()
        bell.move(to: CGPoint(x: -6.5, y: -24 + bob))
        bell.addQuadCurve(to: CGPoint(x: 6.5, y: -24 + bob), control: CGPoint(x: 0, y: -35 + bob))
        bell.addQuadCurve(to: CGPoint(x: -6.5, y: -24 + bob), control: CGPoint(x: 0, y: -21.5 + bob))
        bell.closeSubpath()
        c.fill(bell, with: .radialGradient(
            Gradient(colors: [Color.white.opacity(0.75 + 0.2 * pulse), glowColor.opacity(0.45)]),
            center: CGPoint(x: -1.5, y: -29 + bob), startRadius: 0, endRadius: 8))
        // The four pale rings a moon jelly shows through its bell.
        var rings = Path()
        for k in -1...1 where k != 0 {
            rings.addEllipse(in: CGRect(x: Double(k) * 2.6 - 1.4, y: -27.5 + bob, width: 2.8, height: 2.2))
        }
        c.stroke(rings, with: .color(Color(red: 0.95, green: 0.75, blue: 0.95).opacity(0.7)), lineWidth: 0.5)
        var arms = Path()
        for k in 0..<4 {
            let ax = -4.5 + Double(k) * 3
            arms.move(to: CGPoint(x: ax, y: -23.5 + bob))
            arms.addQuadCurve(to: CGPoint(x: ax + (reduceMotion ? 0 : sin(t * 1.3 + Double(k)) * 2), y: -12),
                              control: CGPoint(x: ax - 2, y: -17 + bob))
        }
        c.stroke(arms, with: .color(Color.white.opacity(0.30 + 0.25 * pulse)), lineWidth: 0.6)
        // The glass: an edge and a long highlight.
        c.stroke(dome, with: .color(Color(red: 0.85, green: 0.95, blue: 1.0).opacity(0.55)), lineWidth: 0.7)
        var shine = Path()
        shine.move(to: CGPoint(x: -6.5, y: -12))
        shine.addQuadCurve(to: CGPoint(x: -2, y: -34), control: CGPoint(x: -7.5, y: -28))
        c.stroke(shine, with: .color(.white.opacity(0.55)), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
        c.fill(Path(ellipseIn: CGRect(x: -1.6, y: -38.2, width: 3.2, height: 1.6)), with: .color(brass))
    }

    /// A cluster of varied corals sharing one footprint — a rose fan
    /// each side with a lace of branches, a ridged brain mound, a
    /// violet staghorn sprig with pale tips.
    private func drawCoralGarden(canvas: inout GraphicsContext, size: CGSize,
                                 slot: AquariumModel.DecorSlot, veil: TankPaint.Atmosphere) {
        let s = ownedScaleW(slot, unitWidth: 64, in: size)
        contactShadow(canvas: &canvas, x: slot.x * size.width, y: ownedBaseY(slot, in: size),
                      halfW: 32 * s)
        var c = slotContext(canvas, slot, scale: s, in: size)
        let fanDeep = Color(red: 0.56, green: 0.14, blue: 0.26)
        TankPaint.seat(&c, in: CGRect(x: -40, y: -31, width: 80, height: 32), unit: s,
                       atmosphere: veil, seed: 181) { c in
            // The fans: a blade with a lace of branches.
            for side in [-1.0, 1.0] {
                let bx = side * 17
                var fan = Path()
                fan.move(to: CGPoint(x: bx, y: 0))
                fan.addCurve(to: CGPoint(x: bx + side * 16, y: -27),
                             control1: CGPoint(x: bx - side * 6, y: -14),
                             control2: CGPoint(x: bx + side * 2, y: -30))
                fan.addCurve(to: CGPoint(x: bx + side * 3, y: 0),
                             control1: CGPoint(x: bx + side * 22, y: -20),
                             control2: CGPoint(x: bx + side * 12, y: -6))
                fan.closeSubpath()
                c.fill(fan, with: .linearGradient(
                    Gradient(colors: [fanDeep, Color(red: 1.0, green: 0.54, blue: 0.60)]),
                    startPoint: CGPoint(x: bx, y: 0), endPoint: CGPoint(x: bx + side * 14, y: -26)))
                var lace = c
                lace.clip(to: fan)
                var branches = Path()
                for k in 0..<7 {
                    let a = -.pi / 2 + side * (Double(k) / 6 - 0.15) * 1.3
                    branches.move(to: CGPoint(x: bx + side * 1.5, y: 0))
                    branches.addQuadCurve(to: CGPoint(x: bx + side * 1.5 + cos(a) * 30, y: sin(a) * 30),
                                          control: CGPoint(x: bx + cos(a) * 12, y: sin(a) * 18))
                }
                var cross = Path()
                for k in 1..<6 {
                    let r = Double(k) * 5.5
                    cross.addArc(center: CGPoint(x: bx, y: 0), radius: r,
                                 startAngle: .degrees(side > 0 ? -95 : -85), endAngle: .degrees(side > 0 ? -20 : -160),
                                 clockwise: side < 0)
                }
                lace.stroke(branches, with: .color(fanDeep.opacity(0.55)), lineWidth: 0.7)
                lace.stroke(cross, with: .color(fanDeep.opacity(0.35)), lineWidth: 0.45)
                lace.stroke(branches.offsetBy(dx: -0.5, dy: -0.4), with: .color(.white.opacity(0.18)), lineWidth: 0.4)
                c.stroke(fan, with: .color(fanDeep.opacity(0.5)), lineWidth: 0.5)
            }
            // The staghorn sprig, centre-back.
            var sprig = Path()
            sprig.move(to: CGPoint(x: 2, y: -2)); sprig.addQuadCurve(to: CGPoint(x: 3, y: -25), control: CGPoint(x: 0, y: -14))
            sprig.move(to: CGPoint(x: 1.5, y: -12)); sprig.addQuadCurve(to: CGPoint(x: -6, y: -22), control: CGPoint(x: -4, y: -14))
            sprig.move(to: CGPoint(x: 2.5, y: -16)); sprig.addQuadCurve(to: CGPoint(x: 11, y: -26), control: CGPoint(x: 9, y: -17))
            sprig.move(to: CGPoint(x: 8, y: -20)); sprig.addLine(to: CGPoint(x: 12, y: -18))
            c.stroke(sprig.offsetBy(dx: 0.6, dy: 0.4), with: .color(Color(red: 0.30, green: 0.14, blue: 0.40)),
                     style: StrokeStyle(lineWidth: 3.2, lineCap: .round))
            c.stroke(sprig, with: .linearGradient(
                Gradient(colors: [Color(red: 0.54, green: 0.34, blue: 0.66), Color(red: 0.90, green: 0.76, blue: 1.0)]),
                startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: -26)),
                     style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
            var tips = Path()
            for tip in [CGPoint(x: 3, y: -25), CGPoint(x: -6, y: -22), CGPoint(x: 11, y: -26), CGPoint(x: 12, y: -18)] {
                tips.addEllipse(in: CGRect(x: tip.x - 1.3, y: tip.y - 1.3, width: 2.6, height: 2.6))
            }
            c.fill(tips, with: .color(Color(red: 0.98, green: 0.93, blue: 1.0)))
            // The brain mound with its meandering ridges.
            var mound = Path()
            mound.move(to: CGPoint(x: -11, y: 0))
            mound.addCurve(to: CGPoint(x: 11, y: 0), control1: CGPoint(x: -12, y: -17), control2: CGPoint(x: 12, y: -17))
            mound.closeSubpath()
            TankPaint.solid(&c, mound, lit: Color(red: 1.0, green: 0.90, blue: 0.62),
                            base: Color(red: 0.86, green: 0.66, blue: 0.36),
                            shade: Color(red: 0.46, green: 0.30, blue: 0.13),
                            outline: Color(red: 0.36, green: 0.22, blue: 0.10).opacity(0.5), lineWidth: 0.4)
            var ridges = c
            ridges.clip(to: mound)
            var maze = Path()
            for k in 0..<5 {
                let gy = -11.0 + Double(k) * 2.6
                maze.move(to: CGPoint(x: -11, y: gy + 1))
                var gx = -11.0
                var up = k.isMultiple(of: 2)
                while gx < 11 {
                    maze.addQuadCurve(to: CGPoint(x: gx + 2.6, y: gy + (up ? 0.9 : -0.9)),
                                      control: CGPoint(x: gx + 1.3, y: gy - 1.2))
                    gx += 2.6
                    up.toggle()
                }
            }
            ridges.stroke(maze, with: .color(Color(red: 0.46, green: 0.28, blue: 0.10).opacity(0.6)), lineWidth: 0.55)
            ridges.stroke(maze.offsetBy(dx: 0, dy: -0.4), with: .color(.white.opacity(0.25)), lineWidth: 0.3)
        }
    }

    /// The bubble wall's air stone: a porous bar set in the sand.
    private func drawAirStone(canvas: inout GraphicsContext, size: CGSize,
                              slot: AquariumModel.DecorSlot, veil: TankPaint.Atmosphere) {
        let x = slot.x * size.width
        let baseY = ownedBaseY(slot, in: size)
        let s = ownedScaleW(slot, unitWidth: 40, in: size)
        contactShadow(canvas: &canvas, x: x, y: baseY, halfW: 18 * s)
        let stone = Path(roundedRect: CGRect(x: x - 18 * s, y: baseY - 6, width: 36 * s, height: 7),
                         cornerRadius: 3.5)
        TankPaint.seat(&canvas, in: stone.boundingRect, atmosphere: veil, seed: 191, caustics: false) { c in
            TankPaint.solid(&c, stone, lit: Color(red: 0.60, green: 0.58, blue: 0.56),
                            base: Color(red: 0.34, green: 0.32, blue: 0.32),
                            shade: Color(red: 0.14, green: 0.13, blue: 0.13),
                            outline: Color(red: 0.10, green: 0.10, blue: 0.10).opacity(0.5), lineWidth: 0.5)
            TankPaint.speckle(&c, stone, seed: 181, count: 30, size: 1.2,
                              dark: .black.opacity(0.35), light: .white.opacity(0.12))
        }
    }

    /// A curtain of bubbles off an air stone — the column of fizz
    /// runs on the live pass; the stone bakes into the bed
    /// (`drawAirStone`).
    private func drawBubbleWall(canvas: inout GraphicsContext, size: CGSize,
                                t: Double, slot: AquariumModel.DecorSlot) {
        let x = slot.x * size.width
        let baseY = ownedBaseY(slot, in: size)
        let s = ownedScaleW(slot, unitWidth: 40, in: size)
        let tt = reduceMotion ? 0 : t
        // The curtain: several parallel bubble streams, each a seeded
        // column rising & wobbling to the surface.
        for i in 0..<5 {
            let h = scatter(AquariumModel.stableHash("bubwall"), i)
            let bx = x + (Double(i) - 2) * 6 * s
            let speed = 30 + Double(h & 0xFF) / 0xFF * 22
            for k in 0..<6 {
                let ph = frac(tt * speed / 400 + Double(k) / 6
                              + Double((h >> 8) & 0xFF) / 0xFF)
                let by = baseY - 8 - ph * (baseY - 18)
                guard by > 14 else { continue }
                let wx = bx + sin(tt * 2.2 + Double(k) * 1.7 + Double(i)) * 3
                let br = (1.0 + Double((h >> 16) & 0x3) * 0.5 + ph * 1.2) * s * 0.7
                drawBubble(canvas: &canvas, at: CGPoint(x: wx, y: by), radius: br, alpha: 1 - ph * 0.4)
            }
        }
    }

    /// The idle game's collectables (docs/TOYS.md): a full-grown fish
    /// sheds a pearl now and then. It falls from where the fish was
    /// when the tank first saw it — 1.4 s, easing out with a little
    /// side wobble — and rests on the sand at that spot for good,
    /// softly pulsing until tapped or the snail reaches it. A drop the
    /// tank finds already old (a relaunch) just rests. Each drop's
    /// hitbox goes into `motion.dropBoxes` — the tap gesture collects
    /// through `toy.collectDrop`, which is the only mutation; the
    /// drawing itself is inert.
    func drawDrops(canvas: inout GraphicsContext, size: CGSize, t: Double,
                   layouts: [String: Layout]) {
        guard let game else { return }
        let m = motion
        m.dropBoxes.removeAll(keepingCapacity: true)
        if m.dropSpots.count > game.drops.count {
            let live = Set(game.drops.map(\.id))
            m.dropSpots = m.dropSpots.filter { live.contains($0.key) }
        }
        let arcade = themeKey == "arcade"
        for drop in game.drops {
            let at = dropPoint(drop, size: size, t: t, layouts: layouts)
            let seed = Double(drop.at.truncatingRemainder(dividingBy: 6))
            let pulse = reduceMotion ? 0.5 : 0.5 + 0.5 * sin(t * 2.2 + seed)
            if arcade {
                // Arcade pearls come as coins: a fast spin as they fall,
                // a slow one at rest. A crowned fish's drop is a gem.
                let rate = at.fall < 1 ? 9.0 : 0.9
                let spin = reduceMotion ? 1 : abs(cos(t * rate + seed))
                let gem = motion.dropSpots[drop.id]?.gem ?? false
                drawCoin(canvas: &canvas, at: at.point, spin: spin, gem: gem, resting: at.fall >= 1)
            } else {
                drawPearl(canvas: &canvas, at: at.point, pulse: pulse, resting: at.fall >= 1)
            }
            m.dropBoxes.append((drop.id, CGRect(x: at.point.x - 16, y: at.point.y - 16,
                                                width: 32, height: 32)))
        }
    }

    /// Where a drop was first seen and how it came to rest (see
    /// `drawDrops`); `gem` pins whether a crowned fish minted it.
    struct DropSpot {
        var x: Double
        var fromY: Double?
        var seenAt: Double
        var gem = false
    }

    /// How long a fresh drop takes to reach the sand.
    static let dropFallSeconds = 1.4

    /// Where a drop rests on the sand: pinned the first time the tank
    /// sees it, never re-read from its fish.
    func dropRest(_ drop: PearlDrop, size: CGSize, layouts: [String: Layout],
                  t: Double) -> CGPoint {
        let spot = dropSpot(drop, size: size, layouts: layouts, t: t)
        let x = min(size.width - 16, max(16, spot.x * size.width))
        return CGPoint(x: x, y: sandTop(atX: x, in: size) - 5)
    }

    /// The drop this frame: where it is and how far through its fall
    /// (1 resting).
    func dropPoint(_ drop: PearlDrop, size: CGSize, t: Double,
                   layouts: [String: Layout]) -> (point: CGPoint, fall: Double) {
        let spot = dropSpot(drop, size: size, layouts: layouts, t: t)
        let rest = dropRest(drop, size: size, layouts: layouts, t: t)
        guard let fromY = spot.fromY else { return (rest, 1) }
        let p = clamp01((t - spot.seenAt) / Self.dropFallSeconds)
        guard p < 1 else { return (rest, 1) }
        let eased = 1 - (1 - p) * (1 - p) * (1 - p)
        let startY = min(rest.y, fromY * size.height)
        let y = startY + (rest.y - startY) * eased
        let wobble = sin(p * .pi * 3) * 5 * (1 - p)
        return (CGPoint(x: rest.x + wobble, y: y), p)
    }

    /// The pinned spot, taken the first frame a drop id shows up: its
    /// fish's x and y if the fish is in the tank, else a steady hashed
    /// spot along the bed. Only a fresh drop falls.
    private func dropSpot(_ drop: PearlDrop, size: CGSize, layouts: [String: Layout],
                          t: Double) -> DropSpot {
        if let spot = motion.dropSpots[drop.id] { return spot }
        let fresh = t - drop.at < 25 && !reduceMotion
        var spot: DropSpot
        if let l = layouts[drop.fishID], size.width > 0, size.height > 0 {
            spot = DropSpot(x: l.x / size.width, fromY: fresh ? l.y / size.height : nil, seenAt: t)
        } else {
            let h = AquariumModel.stableHash("drop-\(drop.id)")
            spot = DropSpot(x: 0.12 + 0.76 * Double(h & 0xFFFF) / 0xFFFF, fromY: nil, seenAt: t)
        }
        if let game {
            let stage = game.pets[drop.fishID]?.stage ?? 0
            spot.gem = game.hat(for: drop.fishID) == nil
                && AquariumBehavior.wearsCrown(streakDays: game.streakDays, stage: stage)
        }
        motion.dropSpots[drop.id] = spot
        return spot
    }

    /// An Arcade coin at `p`: a gold disc with a dark rim, an embossed
    /// ring and a hard white highlight, squeezed to `spin` (|cos|) as it
    /// turns — or, for a crowned fish's drop, a faceted cyan gem that
    /// twinkles instead. Worth the same pearl either way.
    func drawCoin(canvas: inout GraphicsContext, at p: CGPoint, spin: Double, gem: Bool,
                  resting: Bool, radius: Double = 6.5) {
        let r = radius
        if resting {
            contactShadow(canvas: &canvas, x: p.x, y: p.y + r * 0.9, halfW: r * 0.9, alpha: 0.32)
        }
        var halo = canvas
        halo.blendMode = .plusLighter
        let glow = gem ? Color(red: 0.55, green: 0.95, blue: 1.0) : Color(red: 1.0, green: 0.86, blue: 0.40)
        halo.fill(Path(ellipseIn: CGRect(x: p.x - r * 2.4, y: p.y - r * 2.4, width: r * 4.8, height: r * 4.8)),
                  with: .radialGradient(Gradient(colors: [glow.opacity(0.30), .clear]),
                                        center: p, startRadius: 0, endRadius: r * 2.4))
        if gem {
            drawGem(canvas: &canvas, at: p, radius: r * 1.05, twinkle: spin)
            return
        }
        let w = max(0.2, spin)
        var c = canvas
        c.translateBy(x: p.x, y: p.y)
        c.scaleBy(x: w, y: 1)
        let disc = Path(ellipseIn: CGRect(x: -r, y: -r, width: r * 2, height: r * 2))
        c.fill(disc, with: .linearGradient(
            Gradient(colors: [Color(red: 1.0, green: 0.93, blue: 0.52), Color(red: 0.96, green: 0.70, blue: 0.14),
                              Color(red: 0.78, green: 0.48, blue: 0.06)]),
            startPoint: CGPoint(x: -r, y: -r), endPoint: CGPoint(x: r, y: r)))
        let ink = Color(red: 0.42, green: 0.24, blue: 0.02)
        c.stroke(disc, with: .color(ink), lineWidth: 1.3 / w)
        // The embossed ring and its centre dot.
        let ring = Path(ellipseIn: CGRect(x: -r * 0.55, y: -r * 0.55, width: r * 1.1, height: r * 1.1))
        c.stroke(ring, with: .color(Color(red: 0.72, green: 0.44, blue: 0.05).opacity(0.9)), lineWidth: 1.0 / w)
        c.fill(Path(ellipseIn: CGRect(x: -r * 0.18, y: -r * 0.18, width: r * 0.36, height: r * 0.36)),
               with: .color(Color(red: 0.72, green: 0.44, blue: 0.05).opacity(0.9)))
        // The hard highlight blob, upper left.
        c.fill(Path(ellipseIn: CGRect(x: -r * 0.72, y: -r * 0.78, width: r * 0.52, height: r * 0.40)),
               with: .color(.white.opacity(0.92)))
    }

    /// A crowned fish's drop in the Arcade tank: a cut cyan gem with
    /// lit and shaded facets and a star glint that comes and goes.
    private func drawGem(canvas: inout GraphicsContext, at p: CGPoint, radius r: Double,
                         twinkle: Double) {
        let top = CGPoint(x: p.x, y: p.y - r)
        let left = CGPoint(x: p.x - r, y: p.y - r * 0.2)
        let right = CGPoint(x: p.x + r, y: p.y - r * 0.2)
        let bottom = CGPoint(x: p.x, y: p.y + r)
        let mid = CGPoint(x: p.x, y: p.y - r * 0.2)
        func facet(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> Path {
            var path = Path()
            path.move(to: a)
            path.addLine(to: b)
            path.addLine(to: c)
            path.closeSubpath()
            return path
        }
        canvas.fill(facet(top, left, mid), with: .color(Color(red: 0.80, green: 1.0, blue: 1.0)))
        canvas.fill(facet(top, mid, right), with: .color(Color(red: 0.42, green: 0.90, blue: 1.0)))
        canvas.fill(facet(left, bottom, mid), with: .color(Color(red: 0.20, green: 0.70, blue: 0.95)))
        canvas.fill(facet(mid, bottom, right), with: .color(Color(red: 0.08, green: 0.45, blue: 0.78)))
        var outline = Path()
        outline.move(to: top)
        outline.addLine(to: right)
        outline.addLine(to: bottom)
        outline.addLine(to: left)
        outline.closeSubpath()
        canvas.stroke(outline, with: .color(Color(red: 0.02, green: 0.20, blue: 0.40)),
                      style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
        let glint = 0.4 + 0.6 * (1 - twinkle)
        drawSparkle(canvas: &canvas, at: CGPoint(x: p.x - r * 0.35, y: p.y - r * 0.45),
                    size: r * 0.9 * glint, alpha: glint)
    }

    /// One pearl at `p`: a warm halo so it reads as a pick-up, the
    /// nacre and a highlight, and a contact shadow once it rests.
    private func drawPearl(canvas: inout GraphicsContext, at p: CGPoint, pulse: Double,
                           resting: Bool) {
        let x = p.x, y = p.y
        let r = 5.0 + pulse * 1.0
        if resting {
            contactShadow(canvas: &canvas, x: x, y: y + r * 0.9, halfW: r * 0.9, alpha: 0.30)
        }
        var halo = canvas
        halo.blendMode = .plusLighter
        halo.fill(Path(ellipseIn: CGRect(x: x - r * 2.6, y: y - r * 2.6,
                                         width: r * 5.2, height: r * 5.2)),
                  with: .radialGradient(
                    Gradient(colors: [Color(red: 1, green: 0.94, blue: 0.76).opacity(0.24 + 0.14 * pulse),
                                      .clear]),
                    center: CGPoint(x: x, y: y), startRadius: 0, endRadius: r * 2.6))
        let pearl = Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
        canvas.fill(pearl, with: .radialGradient(
            Gradient(stops: [
                .init(color: .white, location: 0),
                .init(color: Color(red: 0.97, green: 0.93, blue: 0.86), location: 0.45),
                .init(color: Color(red: 0.86, green: 0.80, blue: 0.84), location: 0.8),
                .init(color: Color(red: 0.62, green: 0.56, blue: 0.54), location: 1),
            ]),
            center: CGPoint(x: x - r * 0.3, y: y - r * 0.35),
            startRadius: 0, endRadius: r * 1.2))
        // Nacre: a faint rose-and-sea sheen across the lower half.
        var nacre = canvas
        nacre.clip(to: pearl)
        nacre.fill(Path(ellipseIn: CGRect(x: x - r * 0.9, y: y, width: r * 1.8, height: r)),
                   with: .linearGradient(
                       Gradient(colors: [Color(red: 1.0, green: 0.78, blue: 0.86).opacity(0.25),
                                         Color(red: 0.70, green: 0.90, blue: 1.0).opacity(0.25)]),
                       startPoint: CGPoint(x: x - r, y: y), endPoint: CGPoint(x: x + r, y: y)))
        canvas.fill(Path(ellipseIn: CGRect(x: x - r * 0.55, y: y - r * 0.62, width: r * 0.5, height: r * 0.34)),
                    with: .color(.white.opacity(0.9)))
    }

    /// The tank's silent "bloop": an eaten pellet, a collected drop or
    /// a tap on the glass pops a small ring with three bubbles thrown
    /// off it. Under a second, then gone.
    func drawPuffs(canvas: inout GraphicsContext, size: CGSize, now: Date) {
        for puff in motion.puffs {
            let p = clamp01(now.timeIntervalSince(puff.bornAt) / 0.7)
            guard p < 1 else { continue }
            let x = puff.x * size.width
            let y = puff.y * size.height
            let e = 1 - (1 - p) * (1 - p)
            let rr = 3 + e * 14
            var ring = canvas
            ring.opacity = (1 - p) * 0.6
            ring.stroke(Path(ellipseIn: CGRect(x: x - rr, y: y - rr, width: rr * 2, height: rr * 2)),
                        with: .color(.white), lineWidth: 1.2 * (1 - p) + 0.4)
            for k in 0..<3 {
                let a = Double(k) * 2.1 + 0.4
                let bx = x + cos(a) * rr * 0.7
                let by = y + sin(a) * rr * 0.7 - p * 10
                drawBubble(canvas: &canvas, at: CGPoint(x: bx, y: by), radius: 1.3 + Double(k) * 0.5,
                           alpha: 1 - p)
            }
        }
    }

    /// Pearls fly home: a collected drop or an eaten pellet's pearl
    /// arcs up to the counter chip on a little hop and blinks out on
    /// arrival. Where the toast's "+1" visibly comes from.
    func drawFlights(canvas: inout GraphicsContext, size: CGSize, now: Date) {
        // Home is the pearl chip, wherever it measured itself.
        let target = motion.pearlChip ?? Self.pearlChipCenter
        for flight in motion.flights {
            let p = now.timeIntervalSince(flight.bornAt) / 0.75
            guard p < 1 else { continue }
            let at = AquariumBehavior.flightPoint(from: flight.from, to: target, p: p)
            let fade = 1 - smooth(clamp01((p - 0.85) / 0.15))
            let r = 3.4
            var f = canvas
            f.opacity = fade
            var trail = f
            trail.blendMode = .plusLighter
            trail.fill(Path(ellipseIn: CGRect(x: at.x - r * 2.4, y: at.y - r * 2.4, width: r * 4.8, height: r * 4.8)),
                       with: .radialGradient(Gradient(colors: [Color(red: 1, green: 0.95, blue: 0.80).opacity(0.35), .clear]),
                                             center: at, startRadius: 0, endRadius: r * 2.4))
            if themeKey == "arcade" {
                let spin = abs(cos(p * 14))
                drawCoin(canvas: &f, at: at, spin: spin, gem: false, resting: false, radius: 4)
                continue
            }
            f.fill(Path(ellipseIn: CGRect(x: at.x - r, y: at.y - r, width: r * 2, height: r * 2)),
                   with: .radialGradient(
                    Gradient(colors: [.white, Color(red: 0.95, green: 0.90, blue: 0.80)]),
                    center: CGPoint(x: at.x - r * 0.3, y: at.y - r * 0.3), startRadius: 0, endRadius: r))
        }
    }

    /// The hermit crab walks the bed one way, sits tucked in its shell,
    /// turns round — squashing through zero, never a one-frame flip —
    /// and walks back (`HermitCrabRounds`). Reduce Motion parks it near
    /// the middle.
    func drawHermitCrab(canvas: inout GraphicsContext, size: CGSize, t: Double) {
        let tone = decorTone()
        let rounds = reduceMotion ? (x: 0.45, facing: 1.0, walking: false)
            : HermitCrabRounds.pose(at: t)
        let walking = rounds.walking
        let x = size.width * rounds.x
        let y = sandTop(atX: x, in: size) - 2
        contactShadow(canvas: &canvas, x: x - 1, y: y + 2, halfW: 8, alpha: 0.30)
        var c = canvas
        c.translateBy(x: x, y: y)
        c.scaleBy(x: 16 * rounds.facing, y: 12)
        let flesh = tone(Color(red: 0.94, green: 0.44, blue: 0.28))
        let fleshDark = tone(Color(red: 0.54, green: 0.16, blue: 0.09))
        let edge = fleshDark.opacity(0.6)
        if walking && !reduceMotion {
            // Jointed legs stepping under the shell.
            let step = sin(t * 14)
            var legs = Path()
            for k in 0..<3 {
                let lx = -0.18 + Double(k) * 0.20
                let swing = step * (k.isMultiple(of: 2) ? 0.09 : -0.09)
                legs.move(to: CGPoint(x: lx, y: -0.04))
                legs.addLine(to: CGPoint(x: lx + 0.08 + swing, y: -0.02))
                legs.addLine(to: CGPoint(x: lx + 0.10 + swing * 1.4, y: 0.12))
            }
            c.stroke(legs, with: .color(fleshDark), style: StrokeStyle(lineWidth: 0.07, lineCap: .round, lineJoin: .round))
            c.stroke(legs, with: .color(flesh), style: StrokeStyle(lineWidth: 0.04, lineCap: .round, lineJoin: .round))
        }
        // The borrowed shell: a whorled conch, banded and lit.
        var sh = Path()
        sh.move(to: CGPoint(x: -0.44, y: 0.06))
        sh.addQuadCurve(to: CGPoint(x: 0.30, y: 0.04), control: CGPoint(x: -0.05, y: 0.14))
        sh.addQuadCurve(to: CGPoint(x: 0.34, y: -0.30), control: CGPoint(x: 0.46, y: -0.08))
        sh.addQuadCurve(to: CGPoint(x: -0.20, y: -0.54), control: CGPoint(x: 0.20, y: -0.58))
        sh.addQuadCurve(to: CGPoint(x: -0.52, y: -0.30), control: CGPoint(x: -0.44, y: -0.50))
        sh.addQuadCurve(to: CGPoint(x: -0.44, y: 0.06), control: CGPoint(x: -0.58, y: -0.10))
        sh.closeSubpath()
        let shellShade = tone(Color(red: 0.48, green: 0.32, blue: 0.21))
        TankPaint.solid(&c, sh, lit: tone(Color(red: 1.0, green: 0.94, blue: 0.82)),
                        base: tone(Color(red: 0.86, green: 0.68, blue: 0.50)),
                        shade: shellShade, outline: shellShade.opacity(0.6), lineWidth: 0.03, rim: 0.4)
        var whorl = Path()
        whorl.move(to: CGPoint(x: -0.08, y: -0.26))
        for k in 1...24 {
            let a = Double(k) * 0.42
            let r = 0.02 + Double(k) * 0.012
            whorl.addLine(to: CGPoint(x: -0.08 + cos(a) * r * 1.2, y: -0.26 + sin(a) * r))
        }
        var bands = c
        bands.clip(to: sh)
        bands.stroke(whorl, with: .color(tone(Color(red: 0.44, green: 0.26, blue: 0.15)).opacity(0.65)), lineWidth: 0.035)
        TankPaint.speckle(&bands, sh, seed: 191, count: 10, size: 0.05,
                          dark: tone(Color(red: 0.56, green: 0.30, blue: 0.15)).opacity(0.5), light: .white.opacity(0.4))
        // Eyes on stalks peek from under the shell lip — out when
        // walking, tucked (hidden) when resting.
        if walking {
            for dx in [0.30, 0.44] {
                var stalk = Path()
                stalk.move(to: CGPoint(x: dx - 0.06, y: -0.06))
                stalk.addQuadCurve(to: CGPoint(x: dx, y: -0.30), control: CGPoint(x: dx - 0.02, y: -0.20))
                c.stroke(stalk, with: .color(fleshDark), style: StrokeStyle(lineWidth: 0.06, lineCap: .round))
                c.stroke(stalk, with: .color(flesh), style: StrokeStyle(lineWidth: 0.035, lineCap: .round))
                c.fill(Path(ellipseIn: CGRect(x: dx - 0.045, y: -0.36, width: 0.09, height: 0.10)),
                       with: .color(tone(Color(red: 0.06, green: 0.06, blue: 0.09))))
                c.fill(Path(ellipseIn: CGRect(x: dx - 0.01, y: -0.345, width: 0.03, height: 0.03)),
                       with: .color(.white.opacity(0.9)))
            }
            // The big claw.
            var claw = Path()
            claw.move(to: CGPoint(x: 0.40, y: 0.06))
            claw.addQuadCurve(to: CGPoint(x: 0.66, y: -0.14), control: CGPoint(x: 0.62, y: 0.06))
            claw.addLine(to: CGPoint(x: 0.58, y: -0.03))
            claw.addLine(to: CGPoint(x: 0.66, y: 0.00))
            claw.addQuadCurve(to: CGPoint(x: 0.40, y: 0.06), control: CGPoint(x: 0.56, y: 0.10))
            claw.closeSubpath()
            TankPaint.solid(&c, claw, lit: tone(Color(red: 1.0, green: 0.66, blue: 0.50)), base: flesh,
                            shade: fleshDark, outline: edge, lineWidth: 0.025)
        }
    }

    /// The snail (`SnailSim`): it hustles to the oldest pearl resting
    /// on the sand — legs going, a little dust behind — picks it up with
    /// a clink and a bloop, and otherwise creeps end to end, napping now
    /// and then with its eyestalks in and a "z" rising. An hour with no
    /// pearl warms its shell toward red, and it huffs. It turns by
    /// squashing through zero, never a one-frame flip. The live wallpaper
    /// and screensaver only watch: their snail never fetches.
    func drawSnail(canvas: inout GraphicsContext, size: CGSize, t: Double) {
        let m = motion
        let dt = m.snailT > 0 ? t - m.snailT : 0
        m.snailT = t
        // The oldest pearl that has landed, if the snail may fetch.
        var target: (id: String, x: Double)?
        if !ambient, let game, size.width > 0 {
            let resting = game.drops
                .filter { !m.snailClaimed.contains($0.id) }
                .filter { dropPoint($0, size: size, t: t, layouts: [:]).fall >= 1 }
                .min { $0.at < $1.at }
            if let drop = resting {
                target = (drop.id, dropRest(drop, size: size, layouts: [:], t: t).x / size.width)
            }
        }
        let arrived = m.snail.step(dt: dt, pearl: target?.x, still: reduceMotion)
        if arrived, let target {
            m.snailClaimed.insert(target.id)
            m.pendingEvents.append(.snailCollected(target.id))
            let y = sandTop(atX: target.x * size.width, in: size) - 5
            m.puffs.append((x: target.x, y: y / max(1, size.height), bornAt: Date(timeIntervalSince1970: t)))
            m.flights.append((from: CGPoint(x: target.x * size.width, y: y),
                              bornAt: Date(timeIntervalSince1970: t)))
            queueEventDrain()
        }
        if let game, m.snailClaimed.count > 8 {
            let live = Set(game.drops.map(\.id))
            m.snailClaimed = m.snailClaimed.filter { live.contains($0) }
        }
        drawSnailBody(canvas: &canvas, size: size, t: t, sim: m.snail)
    }

    /// The snail at its sim's pose.
    func drawSnailBody(canvas: inout GraphicsContext, size: CGSize, t: Double, sim: SnailSim) {
        let tone = decorTone()
        let x = size.width * sim.x
        // It inches along the dune crest, not the glass bottom.
        let y = sandTop(atX: x, in: size) - 1
        let still = reduceMotion
        contactShadow(canvas: &canvas, x: x, y: y + 1.5, halfW: 12, alpha: 0.28)
        // A hustle kicks up a little dust behind it.
        if sim.hustling && !still {
            for k in 0..<3 {
                let ph = frac(t * 2.4 + Double(k) / 3)
                let dx = -sim.facing * (14 + ph * 10)
                let r = 1.4 + ph * 2.2
                canvas.fill(Path(ellipseIn: CGRect(x: x + dx - r, y: y - 3 - ph * 5 - r, width: r * 2, height: r * 2)),
                            with: .color(TankPaint.color(sandPalette.lit, 0.55 * (1 - ph))))
            }
        }
        var s = canvas
        s.translateBy(x: x, y: y)
        // Hustling, it bobs with its stride.
        let bob = sim.hustling && !still ? abs(sin(t * 16)) * 0.04 : 0
        s.scaleBy(x: 25 * sim.facing, y: 19 * (1 - bob))
        let flesh = tone(Color(red: 0.76, green: 0.70, blue: 0.60))
        let fleshDark = tone(Color(red: 0.38, green: 0.32, blue: 0.26))
        var body = Path()
        body.move(to: CGPoint(x: -0.52, y: 0.05))
        body.addQuadCurve(to: CGPoint(x: 0.62, y: 0.02), control: CGPoint(x: 0.1, y: 0.16))
        body.addQuadCurve(to: CGPoint(x: 0.55, y: -0.18), control: CGPoint(x: 0.68, y: -0.08))
        body.addQuadCurve(to: CGPoint(x: -0.1, y: -0.14), control: CGPoint(x: 0.2, y: -0.26))
        body.addQuadCurve(to: CGPoint(x: -0.52, y: 0.05), control: CGPoint(x: -0.36, y: -0.08))
        body.closeSubpath()
        TankPaint.solid(&s, body, lit: tone(Color(red: 0.94, green: 0.90, blue: 0.80)), base: flesh, shade: fleshDark,
                        outline: fleshDark.opacity(0.55), lineWidth: 0.025, rim: 0.3)
        // Two eyestalks: tall and forward on a hustle, drawn in for a nap.
        let reach = sim.napping ? 0.45 : (sim.hustling ? 1.15 : 1)
        let lean = sim.hustling ? 0.06 : 0
        for dx in [0.42, 0.55] {
            let tip = CGPoint(x: dx + lean, y: -0.14 - 0.28 * reach)
            var stalk = Path()
            stalk.move(to: CGPoint(x: dx - 0.1, y: -0.14))
            stalk.addQuadCurve(to: tip, control: CGPoint(x: dx - 0.05 + lean * 0.5, y: -0.14 - 0.16 * reach))
            s.stroke(stalk, with: .color(fleshDark), style: StrokeStyle(lineWidth: 0.06, lineCap: .round))
            s.stroke(stalk, with: .color(flesh), style: StrokeStyle(lineWidth: 0.035, lineCap: .round))
            let eye = CGRect(x: tip.x - 0.05, y: tip.y - 0.06, width: 0.10, height: sim.napping ? 0.035 : 0.10)
            s.fill(Path(ellipseIn: eye), with: .color(tone(Color(red: 0.12, green: 0.10, blue: 0.10))))
            if !sim.napping {
                s.fill(Path(ellipseIn: CGRect(x: tip.x - 0.015, y: tip.y - 0.05, width: 0.035, height: 0.035)),
                       with: .color(.white.opacity(0.9)))
            }
        }
        // The shell: a banded spiral, lit from above — warming toward
        // red the longer it has gone without a pearl.
        let huff = sim.huff
        let shellRect = CGRect(x: -0.44, y: -0.66, width: 0.62, height: 0.62)
        let shell = Path(ellipseIn: shellRect)
        func warm(_ r: Double, _ g: Double, _ b: Double) -> Color {
            tone(Color(red: r + (0.95 - r) * huff, green: g * (1 - 0.55 * huff), blue: b * (1 - 0.6 * huff)))
        }
        let shellShade = warm(0.36, 0.19, 0.08)
        TankPaint.solid(&s, shell, lit: warm(0.98, 0.80, 0.52),
                        base: warm(0.76, 0.47, 0.23),
                        shade: shellShade, outline: shellShade.opacity(0.6), lineWidth: 0.03, rim: 0.35)
        var spiral = Path()
        let cx = shellRect.midX + 0.03, cy = shellRect.midY + 0.02
        spiral.move(to: CGPoint(x: cx, y: cy))
        for k in 1...40 {
            let a = Double(k) * 0.32
            let r = Double(k) * 0.0068
            spiral.addLine(to: CGPoint(x: cx + cos(a) * r, y: cy + sin(a) * r))
        }
        var inner = s
        inner.clip(to: shell)
        inner.stroke(spiral, with: .color(warm(0.98, 0.90, 0.72).opacity(0.7)), lineWidth: 0.05)
        inner.stroke(spiral.offsetBy(dx: 0.012, dy: 0.012),
                     with: .color(warm(0.30, 0.14, 0.06).opacity(0.55)), lineWidth: 0.025)
        // A nap breathes out a "z"; a huff puffs a little cloud.
        if !still, sim.napping || huff > 0.3 {
            let ph = frac(t / 2.6)
            let bx = x + sim.facing * 10 + ph * 6
            let by = y - 22 - ph * 16
            var bubble = canvas
            bubble.opacity = (1 - ph) * 0.85
            if sim.napping {
                bubble.draw(Text("z").font(.system(size: 9 + ph * 3, weight: .bold, design: .rounded))
                    .foregroundStyle(.white), at: CGPoint(x: bx, y: by))
            } else {
                let r = 2.5 + ph * 3
                bubble.fill(Path(ellipseIn: CGRect(x: bx - r, y: by - r, width: r * 2, height: r * 2)),
                            with: .color(Color(red: 1.0, green: 0.55, blue: 0.45).opacity(0.7 * huff)))
            }
        }
    }
}
