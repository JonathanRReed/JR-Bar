import AppKit
import JRBarCore
import SwiftUI

/// The decor bought in the shop, back row then front row.
extension AquariumView {
    // MARK: Owned decor — back row

    /// Where an owned back-row piece roots: its slot's x on the far
    /// dune, dimmed for depth like the seeded deep pieces.
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

    /// The bought decor rooted on the far dune (docs/TOYS.md shop):
    /// shipwreck, amphora, statue, columns, volcano — still pieces
    /// behind the fish lane, baked into the bed. Each sits under a
    /// pooled shadow, dimmed for depth.
    func drawOwnedBackDecor(canvas: inout GraphicsContext, size: CGSize,
                                    t: Double) {
        guard let game else { return }
        func slot(_ item: ShopItem) -> AquariumModel.DecorSlot? {
            game.owns(item) ? AquariumModel.decorSlot(for: item) : nil
        }
        if let s = slot(.shipwreck) { drawShipwreck(canvas: &canvas, size: size, slot: s) }
        if let s = slot(.amphora) { drawAmphora(canvas: &canvas, size: size, slot: s) }
        if let s = slot(.sunkenStatue) { drawStatue(canvas: &canvas, size: size, slot: s) }
        if let s = slot(.ruinedColumns) { drawColumns(canvas: &canvas, size: size, slot: s) }
        if let s = slot(.volcano) {
            drawVolcano(canvas: &canvas, size: size, slot: s,
                        lit: nightFactor(t: t) > 0.45 || isDarkTheme)
        }
    }

    /// A sunken hull: a listing, broken-backed ship on the dune — lit
    /// planking over a dark hold, a brass porthole, barnacles and
    /// weed along the waterline, a snapped mast still flying its
    /// tattered sail.
    private func drawShipwreck(canvas: inout GraphicsContext, size: CGSize,
                               slot: AquariumModel.DecorSlot) {
        let tone = decorTone()
        let x = slot.x * size.width
        let baseY = ownedBaseY(slot, in: size)
        let s = ownedScaleW(slot, unitWidth: 90, in: size)
        groundShadow(canvas: &canvas, x: x, y: baseY + 1,
                     halfW: 48 * s, alpha: 0.26)
        var c = canvas
        c.translateBy(x: x, y: baseY)
        c.scaleBy(x: s, y: s)
        c.opacity = 0.9
        let woodLit = tone(Color(red: 0.62, green: 0.44, blue: 0.27))
        let wood = tone(Color(red: 0.40, green: 0.27, blue: 0.16))
        let woodDark = tone(Color(red: 0.16, green: 0.10, blue: 0.06))
        let line = tone(Color(red: 0.10, green: 0.06, blue: 0.04)).opacity(0.8)

        // The snapped mast behind the hull, then its tattered sail.
        var mast = Path()
        mast.move(to: CGPoint(x: -8, y: -8))
        mast.addLine(to: CGPoint(x: -4.5, y: -8))
        mast.addLine(to: CGPoint(x: 8.5, y: -60))
        mast.addLine(to: CGPoint(x: 6.5, y: -63))
        mast.addLine(to: CGPoint(x: 5, y: -59))
        mast.addLine(to: CGPoint(x: 4, y: -62))
        mast.closeSubpath()
        TankPaint.cylinder(&c, mast, lit: woodLit, base: wood, shade: woodDark, outline: line, lineWidth: 0.6)
        var yard = Path()
        yard.move(to: CGPoint(x: -10, y: -45))
        yard.addLine(to: CGPoint(x: 24, y: -51))
        c.stroke(yard, with: .color(line), style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
        c.stroke(yard, with: .color(wood), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
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
            Gradient(colors: [tone(Color(red: 0.86, green: 0.80, blue: 0.66)).opacity(0.62),
                              tone(Color(red: 0.55, green: 0.50, blue: 0.40)).opacity(0.45)]),
            startPoint: CGPoint(x: -8, y: -48), endPoint: CGPoint(x: 18, y: -30)),
               style: FillStyle(eoFill: true))
        c.stroke(sail, with: .color(line.opacity(0.5)), lineWidth: 0.5)
        // A slack stay from the masthead to the stern.
        var stay = Path()
        stay.move(to: CGPoint(x: 7, y: -58))
        stay.addQuadCurve(to: CGPoint(x: 40, y: -20), control: CGPoint(x: 28, y: -34))
        c.stroke(stay, with: .color(line.opacity(0.55)), lineWidth: 0.5)

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
        TankPaint.solid(&c, hull, lit: woodLit, base: wood, shade: woodDark, outline: line, lineWidth: 0.9)
        // Planking that follows the hull's sweep.
        var inner = c
        inner.clip(to: hull)
        var planks = Path()
        for k in 0..<6 {
            let y = -3.0 - Double(k) * 4.2
            planks.move(to: CGPoint(x: -46, y: y - 6))
            planks.addQuadCurve(to: CGPoint(x: 46, y: y - 4), control: CGPoint(x: 0, y: y + 5))
        }
        inner.stroke(planks, with: .color(woodDark.opacity(0.55)), lineWidth: 0.55)
        inner.stroke(planks.offsetBy(dx: 0, dy: 0.7), with: .color(woodLit.opacity(0.35)), lineWidth: 0.4)
        TankPaint.grain(&inner, hull, from: CGPoint(x: -44, y: -12), to: CGPoint(x: 44, y: -10),
                        spacing: 1.6, width: 0.22, seed: 71, color: woodDark.opacity(0.22))
        // The break: the dark hold with a rib or two showing.
        var hole = Path()
        hole.move(to: CGPoint(x: -7, y: -4))
        hole.addLine(to: CGPoint(x: -3, y: -10))
        hole.addLine(to: CGPoint(x: 1, y: -6))
        hole.addLine(to: CGPoint(x: 5, y: -13))
        hole.addLine(to: CGPoint(x: 11, y: -9))
        hole.addQuadCurve(to: CGPoint(x: -7, y: -4), control: CGPoint(x: 3, y: -1))
        hole.closeSubpath()
        inner.fill(hole, with: .color(tone(Color(red: 0.05, green: 0.04, blue: 0.04)).opacity(0.85)))
        var ribs = Path()
        for rx in [-2.0, 4.0] {
            ribs.move(to: CGPoint(x: rx, y: -12))
            ribs.addQuadCurve(to: CGPoint(x: rx + 1.5, y: -2), control: CGPoint(x: rx - 1.5, y: -6))
        }
        inner.stroke(ribs, with: .color(wood), lineWidth: 1)
        // A brass porthole near the bow.
        let port = CGRect(x: 25, y: -17, width: 6, height: 6)
        c.fill(Path(ellipseIn: port.insetBy(dx: -1.1, dy: -1.1)), with: .linearGradient(
            Gradient(colors: [tone(Color(red: 0.95, green: 0.80, blue: 0.40)), tone(Color(red: 0.50, green: 0.34, blue: 0.10))]),
            startPoint: CGPoint(x: port.minX, y: port.minY), endPoint: CGPoint(x: port.maxX, y: port.maxY)))
        c.fill(Path(ellipseIn: port), with: .radialGradient(
            Gradient(colors: [tone(Color(red: 0.30, green: 0.50, blue: 0.55)), tone(Color(red: 0.04, green: 0.08, blue: 0.10))]),
            center: CGPoint(x: port.midX - 1, y: port.midY - 1), startRadius: 0, endRadius: 3.5))
        c.fill(Path(ellipseIn: CGRect(x: port.minX + 1.2, y: port.minY + 1, width: 1.6, height: 1)),
               with: .color(.white.opacity(0.7)))
        // The gunwale's rail along the top edge.
        var rail = Path()
        rail.move(to: CGPoint(x: -45, y: -27))
        rail.addQuadCurve(to: CGPoint(x: -10, y: -14), control: CGPoint(x: -28, y: -16))
        rail.move(to: CGPoint(x: 12, y: -10))
        rail.addQuadCurve(to: CGPoint(x: 45, y: -21), control: CGPoint(x: 30, y: -10))
        c.stroke(rail, with: .color(woodDark), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
        c.stroke(rail.offsetBy(dx: 0, dy: -0.5), with: .color(woodLit.opacity(0.6)),
                 style: StrokeStyle(lineWidth: 0.5, lineCap: .round))
        // Barnacles and weed along the waterline.
        TankPaint.speckle(&c, hull, seed: 83, count: 26, size: 1.2,
                          dark: tone(Color(red: 0.10, green: 0.10, blue: 0.08)).opacity(0.3),
                          light: tone(Color(red: 0.92, green: 0.90, blue: 0.80)).opacity(0.55))
        TankPaint.moss(&c, clip: hull, from: -40, to: 40, y: 1, height: 5, seed: 89, fade: 0.9)
    }

    /// The tipped storage jar — the octopus's home when it has one:
    /// glazed terracotta with a black-figure key band, two handles and
    /// a dark mouth.
    private func drawAmphora(canvas: inout GraphicsContext, size: CGSize,
                             slot: AquariumModel.DecorSlot) {
        let tone = decorTone()
        let x = slot.x * size.width
        let baseY = ownedBaseY(slot, in: size)
        let s = ownedScaleW(slot, unitWidth: 34, in: size)
        groundShadow(canvas: &canvas, x: x, y: baseY + 1,
                     halfW: 24 * s, alpha: 0.26)
        var c = canvas
        c.translateBy(x: x, y: baseY)
        c.scaleBy(x: s, y: s)
        c.rotate(by: .radians(-1.15))
        let clayLit = tone(Color(red: 0.86, green: 0.58, blue: 0.36))
        let clay = tone(Color(red: 0.66, green: 0.40, blue: 0.24))
        let clayDark = tone(Color(red: 0.30, green: 0.16, blue: 0.10))
        let line = tone(Color(red: 0.16, green: 0.08, blue: 0.05)).opacity(0.8)
        // Handles first, behind the body.
        var handles = Path()
        handles.move(to: CGPoint(x: -9, y: -31))
        handles.addCurve(to: CGPoint(x: -12, y: -20), control1: CGPoint(x: -19, y: -33), control2: CGPoint(x: -19, y: -22))
        handles.move(to: CGPoint(x: 9, y: -31))
        handles.addCurve(to: CGPoint(x: 12, y: -20), control1: CGPoint(x: 19, y: -33), control2: CGPoint(x: 19, y: -22))
        c.stroke(handles, with: .color(line), style: StrokeStyle(lineWidth: 3.2, lineCap: .round))
        c.stroke(handles, with: .color(clay), style: StrokeStyle(lineWidth: 2.0, lineCap: .round))
        var jar = Path()
        jar.move(to: CGPoint(x: -7, y: -34))
        jar.addCurve(to: CGPoint(x: -14, y: -8),
                     control1: CGPoint(x: -16, y: -28),
                     control2: CGPoint(x: -17, y: -15))
        jar.addQuadCurve(to: CGPoint(x: 0, y: 2), control: CGPoint(x: -10, y: 0))
        jar.addQuadCurve(to: CGPoint(x: 14, y: -8), control: CGPoint(x: 10, y: 0))
        jar.addCurve(to: CGPoint(x: 7, y: -34),
                     control1: CGPoint(x: 17, y: -15),
                     control2: CGPoint(x: 16, y: -28))
        jar.closeSubpath()
        TankPaint.cylinder(&c, jar, lit: clayLit, base: clay, shade: clayDark, outline: line, lineWidth: 0.8)
        // The black-figure band: a key pattern between two rules.
        var band = c
        band.clip(to: jar)
        band.fill(Path(CGRect(x: -20, y: -21, width: 40, height: 7)),
                  with: .color(tone(Color(red: 0.10, green: 0.06, blue: 0.05)).opacity(0.82)))
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
        band.stroke(rules, with: .color(tone(Color(red: 0.10, green: 0.06, blue: 0.05)).opacity(0.7)), lineWidth: 0.6)
        // The glaze's gloss.
        band.fill(Path(ellipseIn: CGRect(x: -10, y: -30, width: 4, height: 18)),
                  with: .color(.white.opacity(0.18)))
        // Rim & the dark mouth the octopus watches from.
        let rim = Path(ellipseIn: CGRect(x: -9.5, y: -38, width: 19, height: 7))
        TankPaint.solid(&c, rim, lit: clayLit, base: clay, shade: clayDark, outline: line, lineWidth: 0.6, rim: 0)
        c.fill(Path(ellipseIn: CGRect(x: -6.5, y: -36.6, width: 13, height: 4.4)),
               with: .radialGradient(Gradient(colors: [.black, tone(Color(red: 0.12, green: 0.06, blue: 0.04))]),
                                     center: CGPoint(x: 0, y: -34.4), startRadius: 0, endRadius: 7))
        TankPaint.speckle(&c, jar, seed: 97, count: 18, size: 1.0,
                          dark: clayDark.opacity(0.3), light: tone(Color(red: 0.95, green: 0.92, blue: 0.82)).opacity(0.35))
    }

    /// A marble bust on a stepped plinth — someone important, once:
    /// curled hair, a strong brow and a chipped nose, draped shoulders,
    /// weed on the plinth.
    private func drawStatue(canvas: inout GraphicsContext, size: CGSize,
                            slot: AquariumModel.DecorSlot) {
        let tone = decorTone()
        let x = slot.x * size.width
        let baseY = ownedBaseY(slot, in: size)
        let s = ownedScaleH(slot, unitHeight: 45, in: size)
        groundShadow(canvas: &canvas, x: x, y: baseY + 1,
                     halfW: 22 * s, alpha: 0.26)
        var c = canvas
        c.translateBy(x: x, y: baseY)
        c.scaleBy(x: s, y: s)
        c.opacity = 0.9
        let lit = tone(Color(red: 0.90, green: 0.90, blue: 0.88))
        let base = tone(Color(red: 0.70, green: 0.72, blue: 0.72))
        let shade = tone(Color(red: 0.36, green: 0.40, blue: 0.44))
        let line = tone(Color(red: 0.16, green: 0.18, blue: 0.22)).opacity(0.7)
        // The stepped plinth.
        let foot = Path(CGRect(x: -14, y: -4, width: 28, height: 4))
        let block = Path(CGRect(x: -11.5, y: -16, width: 23, height: 12))
        TankPaint.solid(&c, foot, lit: lit, base: base, shade: shade, outline: line, lineWidth: 0.5)
        TankPaint.solid(&c, block, lit: lit, base: base, shade: shade, outline: line, lineWidth: 0.5)
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
        TankPaint.cylinder(&c, bust, lit: lit, base: base, shade: shade, outline: line, lineWidth: 0.55)
        var folds = c
        folds.clip(to: bust)
        var drape = Path()
        for k in 0..<3 {
            let o = Double(k) * 3
            drape.move(to: CGPoint(x: -9 + o, y: -26 + o * 0.3))
            drape.addQuadCurve(to: CGPoint(x: 2 + o, y: -16), control: CGPoint(x: -4 + o, y: -18))
        }
        folds.stroke(drape, with: .color(shade.opacity(0.7)), lineWidth: 0.55)
        // The neck and head.
        let neck = Path(CGRect(x: -2.6, y: -32, width: 5.2, height: 5))
        TankPaint.cylinder(&c, neck, lit: lit, base: base, shade: shade, outline: line, lineWidth: 0.4)
        let head = Path(ellipseIn: CGRect(x: -6, y: -45, width: 12, height: 14.5))
        TankPaint.cylinder(&c, head, lit: lit, base: base, shade: shade, outline: line, lineWidth: 0.55)
        // Curls across the crown.
        var curls = Path()
        for (cx, cy) in [(-4.5, -42.5), (-2.0, -44.2), (1.0, -44.6), (3.8, -43.4), (-5.5, -39.5)] as [(Double, Double)] {
            curls.addEllipse(in: CGRect(x: cx - 1.5, y: cy - 1.3, width: 3, height: 2.6))
        }
        c.fill(curls, with: .color(base))
        c.stroke(curls, with: .color(shade.opacity(0.9)), lineWidth: 0.4)
        // The face: a brow's shadow, closed eyes, a chipped nose, lips.
        var face = c
        face.clip(to: head)
        face.fill(Path(ellipseIn: CGRect(x: -1, y: -40.2, width: 6, height: 2.2)),
                  with: .color(shade.opacity(0.45)))
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
        var ear = Path()
        ear.addEllipse(in: CGRect(x: -3.2, y: -39, width: 2.2, height: 3.4))
        face.stroke(ear, with: .color(shade.opacity(0.8)), lineWidth: 0.4)
        // Weed on the plinth and a little on the shoulders.
        TankPaint.moss(&c, clip: block, from: -12, to: 12, y: -4, height: 3.2, seed: 107, fade: 0.8)
        TankPaint.moss(&c, clip: bust, from: -11, to: -3, y: -16, height: 2.4, seed: 109, fade: 0.6)
        TankPaint.moss(&c, clip: nil, from: -15, to: 15, y: 0.4, height: 2.6, seed: 113)
    }

    /// The ruin: two fluted columns on their bases — one whole under
    /// its capital, one snapped — and a fallen drum out front, marble
    /// lit from the surface, weed at every foot.
    private func drawColumns(canvas: inout GraphicsContext, size: CGSize,
                             slot: AquariumModel.DecorSlot) {
        let tone = decorTone()
        let x = slot.x * size.width
        let baseY = ownedBaseY(slot, in: size)
        let s = ownedScaleH(slot, unitHeight: 72, in: size)
        groundShadow(canvas: &canvas, x: x, y: baseY + 1,
                     halfW: 46 * s, alpha: 0.26)
        var c = canvas
        c.translateBy(x: x, y: baseY)
        c.scaleBy(x: s, y: s)
        c.opacity = 0.9
        let lit = tone(Color(red: 0.92, green: 0.91, blue: 0.88))
        let base = tone(Color(red: 0.72, green: 0.72, blue: 0.72))
        let shade = tone(Color(red: 0.36, green: 0.39, blue: 0.44))
        let line = tone(Color(red: 0.16, green: 0.18, blue: 0.22)).opacity(0.7)
        // Standing: x, height, whole (capital) or snapped.
        let standing: [(x: Double, h: Double, whole: Bool)] = [(-28, 50, false), (-4, 64, true)]
        for col in standing {
            // Base: a torus over a square plinth.
            let plinth = Path(CGRect(x: col.x - 9, y: -4, width: 18, height: 4))
            TankPaint.solid(&c, plinth, lit: lit, base: base, shade: shade, outline: line, lineWidth: 0.5)
            let torus = Path(roundedRect: CGRect(x: col.x - 8, y: -7, width: 16, height: 3.4), cornerRadius: 1.7)
            TankPaint.cylinder(&c, torus, lit: lit, base: base, shade: shade, outline: line, lineWidth: 0.45)
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
            TankPaint.cylinder(&c, shaft, lit: lit, base: base, shade: shade, outline: line, lineWidth: 0.55)
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
            flutes.stroke(grooves, with: .color(shade.opacity(0.55)), lineWidth: 0.55)
            flutes.stroke(lips, with: .color(.white.opacity(0.28)), lineWidth: 0.35)
            TankPaint.speckle(&c, shaft, seed: UInt64(col.h) &* 131, count: 14, size: 0.9)
            if col.whole {
                // An Ionic capital: echinus, abacus and two volutes.
                let echinus = Path(roundedRect: CGRect(x: col.x - 7.5, y: top - 3, width: 15, height: 3.2),
                                   cornerRadius: 1.4)
                TankPaint.cylinder(&c, echinus, lit: lit, base: base, shade: shade, outline: line, lineWidth: 0.45)
                let abacus = Path(CGRect(x: col.x - 9.5, y: top - 6, width: 19, height: 3))
                TankPaint.solid(&c, abacus, lit: lit, base: base, shade: shade, outline: line, lineWidth: 0.5)
                for side in [-1.0, 1.0] {
                    var volute = Path()
                    let vc = CGPoint(x: col.x + side * 8, y: top - 1.8)
                    volute.addArc(center: vc, radius: 2.4, startAngle: .degrees(0), endAngle: .degrees(360), clockwise: false)
                    TankPaint.solid(&c, volute, lit: lit, base: base, shade: shade, outline: line, lineWidth: 0.4, rim: 0.2)
                    var spiral = Path()
                    spiral.addArc(center: vc, radius: 1.2, startAngle: .degrees(0), endAngle: .degrees(300), clockwise: false)
                    c.stroke(spiral, with: .color(shade), lineWidth: 0.35)
                }
            }
            TankPaint.moss(&c, clip: shaft, from: col.x - 7, to: col.x + 7, y: -7, height: 4, seed: UInt64(col.h) &+ 5, fade: 0.8)
        }
        TankPaint.moss(&c, clip: nil, from: -40, to: 8, y: 0.4, height: 2.8, seed: 139)

        // The fallen drum lying out front, its fluted end toward us.
        var fallen = canvas
        fallen.translateBy(x: x + 34 * s, y: baseY - 6 * s)
        fallen.scaleBy(x: s, y: s)
        fallen.rotate(by: .radians(0.16))
        fallen.opacity = 0.9
        let drum = Path(roundedRect: CGRect(x: -20, y: -7, width: 38, height: 14), cornerRadius: 3)
        fallen.fill(drum, with: .linearGradient(
            Gradient(stops: [.init(color: lit, location: 0.1), .init(color: base, location: 0.5),
                             .init(color: shade, location: 1)]),
            startPoint: CGPoint(x: 0, y: -7), endPoint: CGPoint(x: 0, y: 7)))
        fallen.stroke(drum, with: .color(line), lineWidth: 0.5)
        var drumFlutes = fallen
        drumFlutes.clip(to: drum)
        var lines = Path()
        for k in -2...2 {
            lines.move(to: CGPoint(x: -20, y: Double(k) * 2.4)); lines.addLine(to: CGPoint(x: 18, y: Double(k) * 2.4))
        }
        drumFlutes.stroke(lines, with: .color(shade.opacity(0.45)), lineWidth: 0.5)
        let end = Path(ellipseIn: CGRect(x: 14, y: -7, width: 8, height: 14))
        fallen.fill(end, with: .radialGradient(Gradient(colors: [lit, base]),
                                               center: CGPoint(x: 17, y: -2), startRadius: 0, endRadius: 8))
        var scallops = Path()
        for k in 0..<10 {
            let a = Double(k) / 10 * .pi * 2
            scallops.addEllipse(in: CGRect(x: 18 + cos(a) * 3.2 - 0.6, y: sin(a) * 6 - 0.6, width: 1.2, height: 1.2))
        }
        fallen.fill(scallops, with: .color(shade.opacity(0.5)))
        fallen.stroke(end, with: .color(line), lineWidth: 0.5)
        TankPaint.moss(&fallen, clip: drum, from: -18, to: 16, y: 7, height: 3, seed: 149, fade: 0.8)
    }

    /// The cone: a broad shield with a rimmed crater bowl. Its throat
    /// always smoulders a little — a warm inner glow at any hour that
    /// goes molten at night (or in the dark themes), when the live
    /// pass's `drawVolcanoGlow` adds the halo and the ember climb.
    private func drawVolcano(canvas: inout GraphicsContext, size: CGSize,
                             slot: AquariumModel.DecorSlot, lit: Bool) {
        let tone = decorTone()
        let x = slot.x * size.width
        let baseY = ownedBaseY(slot, in: size)
        let s = ownedScaleW(slot, unitWidth: 84, in: size)
        groundShadow(canvas: &canvas, x: x, y: baseY + 1,
                     halfW: 40 * s, alpha: 0.24)
        var c = canvas
        c.translateBy(x: x, y: baseY)
        c.scaleBy(x: s, y: s)
        c.opacity = 0.90
        // The cone silhouette: a broad base sweeping to a flat rim,
        // with a shoulder kink each side so it reads as rock, not a
        // sand hump.
        var cone = Path()
        cone.move(to: CGPoint(x: -42, y: 0))
        cone.addQuadCurve(to: CGPoint(x: -30, y: -26), control: CGPoint(x: -40, y: -18))
        cone.addQuadCurve(to: CGPoint(x: -13, y: -44), control: CGPoint(x: -24, y: -40))
        cone.addLine(to: CGPoint(x: 13, y: -44))
        cone.addQuadCurve(to: CGPoint(x: 30, y: -26), control: CGPoint(x: 24, y: -40))
        cone.addQuadCurve(to: CGPoint(x: 42, y: 0), control: CGPoint(x: 40, y: -18))
        cone.closeSubpath()
        TankPaint.solid(&c, cone, lit: tone(Color(red: 0.46, green: 0.40, blue: 0.38)),
                        base: tone(Color(red: 0.27, green: 0.23, blue: 0.22)),
                        shade: tone(Color(red: 0.10, green: 0.08, blue: 0.08)),
                        outline: .black.opacity(0.45), lineWidth: 1.0)
        // Basalt: pitted, with a few old flows banding the flanks.
        TankPaint.speckle(&c, cone, seed: 151, count: 60, size: 1.4,
                          dark: .black.opacity(0.28), light: tone(Color(red: 0.8, green: 0.7, blue: 0.6)).opacity(0.14))
        var strata = c
        strata.clip(to: cone)
        var bands = Path()
        for k in 0..<3 {
            let y = -12.0 - Double(k) * 9
            bands.move(to: CGPoint(x: -44, y: y + 3))
            bands.addQuadCurve(to: CGPoint(x: 44, y: y + 2), control: CGPoint(x: 0, y: y - 3))
        }
        strata.stroke(bands, with: .color(.black.opacity(0.18)), lineWidth: 1.1)
        TankPaint.moss(&c, clip: cone, from: -40, to: 40, y: 0.5, height: 4, seed: 157, fade: 0.7)
        // Flank shading: darker seams running down from the rim so the
        // cone has faces.
        for k in [-1.0, 1.0] {
            var seam = Path()
            seam.move(to: CGPoint(x: k * 12, y: -42))
            seam.addQuadCurve(to: CGPoint(x: k * 32, y: -4),
                              control: CGPoint(x: k * 20, y: -24))
            c.stroke(seam, with: .color(.black.opacity(0.22)), lineWidth: 1.4)
        }
        // The crater bowl: a dark ellipse set into the rim, its near
        // lip catching whatever heat is inside.
        let bowl = Path(ellipseIn: CGRect(x: -14, y: -50, width: 28, height: 11))
        c.fill(bowl, with: .color(lit
                                  ? tone(Color(red: 0.55, green: 0.14, blue: 0.05))
                                  : tone(Color(red: 0.10, green: 0.08, blue: 0.08))))
        c.stroke(bowl, with: .color(.black.opacity(0.4)), lineWidth: 0.8)
        // The smoulder: a warm breath in the throat at every hour,
        // molten once lit — plus a thin hot rim on the crater's lip.
        var g = c
        g.blendMode = .plusLighter
        g.fill(bowl, with: .radialGradient(
            Gradient(colors: [tone(Color(red: 1.0, green: 0.5, blue: 0.12))
                                .opacity(lit ? 0.95 : 0.30), .clear]),
            center: CGPoint(x: 0, y: -45), startRadius: 0, endRadius: 18))
        // A dull orange seam down the cone's face — the lava's old path.
        var lava = Path()
        lava.move(to: CGPoint(x: 4, y: -42))
        lava.addQuadCurve(to: CGPoint(x: 12, y: -12), control: CGPoint(x: 8, y: -26))
        c.stroke(lava, with: .color(tone(Color(red: 0.75, green: 0.25, blue: 0.08))
                                    .opacity(lit ? 0.85 : 0.18)),
                 style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
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
                   Gradient(colors: [Color(red: 1.0, green: 0.42, blue: 0.12)
                                       .opacity(0.30), .clear]),
                   center: CGPoint(x: x, y: craterY), startRadius: 0,
                   endRadius: 40 * s))
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
            e.fill(Path(ellipseIn: CGRect(x: ex - er, y: ey - er,
                                          width: er * 2, height: er * 2)),
                   with: .color(Color(red: 1.0, green: 0.45, blue: 0.12)))
        }
    }

    // MARK: Owned decor — front row

    /// The bought decor on the near crest (docs/TOYS.md shop):
    /// driftwood, the anemone's swaying bed, the jelly lamp's pulsing
    /// dome, the coral garden, the bubble wall's curtain — drawn over
    /// the fish lane like the shop's original four.
    func drawOwnedFrontDecor(canvas: inout GraphicsContext, size: CGSize,
                                     t: Double) {
        guard let game else { return }
        func slot(_ item: ShopItem) -> AquariumModel.DecorSlot? {
            game.owns(item) ? AquariumModel.decorSlot(for: item) : nil
        }
        if let s = slot(.anemoneBed) { drawAnemone(canvas: &canvas, size: size, t: t, slot: s) }
        if let s = slot(.moonJellyLamp) { drawJellyLamp(canvas: &canvas, size: size, t: t, slot: s) }
        if let s = slot(.bubbleWall) { drawBubbleWall(canvas: &canvas, size: size, t: t, slot: s) }
        // The volcano's live half rides along when the crater's lit.
        if let s = game.owns(.volcano) ? AquariumModel.decorSlot(for: .volcano) : nil,
           nightFactor(t: t) > 0.45 || isDarkTheme {
            drawVolcanoGlow(canvas: &canvas, size: size, t: t, slot: s)
        }
    }

    /// The front-row pieces that never move — the driftwood, the coral
    /// garden, the bubble wall's air stone — baked into the cached bed
    /// with the rest, so the live pass only pays for what sways.
    func drawOwnedFrontStill(canvas: inout GraphicsContext, size: CGSize) {
        guard let game else { return }
        func slot(_ item: ShopItem) -> AquariumModel.DecorSlot? {
            game.owns(item) ? AquariumModel.decorSlot(for: item) : nil
        }
        if let s = slot(.driftwood) { drawDriftwood(canvas: &canvas, size: size, slot: s) }
        if let s = slot(.coralGarden) { drawCoralGarden(canvas: &canvas, size: size, slot: s) }
        if let s = slot(.bubbleWall) { drawAirStone(canvas: &canvas, size: size, slot: s) }
    }

    /// A water-logged branch half settled into the sand: silvered,
    /// grained wood lit along its top, a forked stub, a knot, weed
    /// where it meets the bed.
    private func drawDriftwood(canvas: inout GraphicsContext, size: CGSize,
                               slot: AquariumModel.DecorSlot) {
        let tone = decorTone()
        let x = slot.x * size.width
        let baseY = ownedBaseY(slot, in: size)
        let s = ownedScaleW(slot, unitWidth: 60, in: size)
        groundShadow(canvas: &canvas, x: x, y: baseY + 1,
                     halfW: 32 * s, alpha: 0.30)
        var c = canvas
        c.translateBy(x: x, y: baseY)
        c.scaleBy(x: s, y: s)
        let lit = tone(Color(red: 0.80, green: 0.72, blue: 0.60))
        let wood = tone(Color(red: 0.55, green: 0.46, blue: 0.36))
        let dark = tone(Color(red: 0.24, green: 0.19, blue: 0.14))
        let line = tone(Color(red: 0.14, green: 0.10, blue: 0.07)).opacity(0.75)
        // The forked stub first, behind the log.
        var stub = Path()
        stub.move(to: CGPoint(x: -11, y: -9))
        stub.addQuadCurve(to: CGPoint(x: -19, y: -27), control: CGPoint(x: -12, y: -20))
        stub.addLine(to: CGPoint(x: -16, y: -28))
        stub.addQuadCurve(to: CGPoint(x: -5, y: -11), control: CGPoint(x: -8, y: -19))
        stub.closeSubpath()
        TankPaint.solid(&c, stub, lit: lit, base: wood, shade: dark, outline: line, lineWidth: 0.6)
        TankPaint.grain(&c, stub, from: CGPoint(x: -8, y: -10), to: CGPoint(x: -18, y: -27),
                        spacing: 1.3, width: 0.25, seed: 163, color: dark.opacity(0.35))
        var log = Path()
        log.move(to: CGPoint(x: -30, y: -3))
        log.addQuadCurve(to: CGPoint(x: -18, y: -10), control: CGPoint(x: -28, y: -9))
        log.addQuadCurve(to: CGPoint(x: 26, y: -15), control: CGPoint(x: 4, y: -16))
        log.addQuadCurve(to: CGPoint(x: 31, y: -7), control: CGPoint(x: 31, y: -13))
        log.addQuadCurve(to: CGPoint(x: -26, y: 1), control: CGPoint(x: 2, y: -2))
        log.closeSubpath()
        TankPaint.solid(&c, log, lit: lit, base: wood, shade: dark, outline: line, lineWidth: 0.7, rim: 0.4)
        TankPaint.grain(&c, log, from: CGPoint(x: -28, y: -4), to: CGPoint(x: 30, y: -11),
                        spacing: 1.5, width: 0.28, seed: 167, color: dark.opacity(0.35))
        // A knot, and the broken end's rings.
        let knot = Path(ellipseIn: CGRect(x: 4, y: -12, width: 5, height: 3.2))
        c.fill(knot, with: .radialGradient(Gradient(colors: [dark, wood]),
                                           center: CGPoint(x: 6.5, y: -10.4), startRadius: 0, endRadius: 3))
        c.stroke(knot, with: .color(line.opacity(0.6)), lineWidth: 0.35)
        let end = Path(ellipseIn: CGRect(x: 27, y: -14, width: 5, height: 8))
        c.fill(end, with: .color(tone(Color(red: 0.72, green: 0.60, blue: 0.44))))
        c.stroke(Path(ellipseIn: CGRect(x: 28.2, y: -12, width: 2.6, height: 4.4)),
                 with: .color(dark.opacity(0.6)), lineWidth: 0.35)
        c.stroke(end, with: .color(line), lineWidth: 0.5)
        TankPaint.moss(&c, clip: log, from: -28, to: 28, y: 1, height: 3, seed: 173, fade: 0.8)
    }

    /// A bed of anemones: fat columns under crowns of tentacles that
    /// sway in a slow wave, each tentacle lit along its length with a
    /// glowing tip — the live pass keeps them breathing; Reduce Motion
    /// holds a soft lean.
    private func drawAnemone(canvas: inout GraphicsContext, size: CGSize,
                             t: Double, slot: AquariumModel.DecorSlot) {
        let tone = decorTone()
        let x = slot.x * size.width
        let baseY = ownedBaseY(slot, in: size)
        let s = ownedScaleW(slot, unitWidth: 44, in: size)
        groundShadow(canvas: &canvas, x: x, y: baseY + 1,
                     halfW: 26 * s, alpha: 0.26)
        var c = canvas
        c.translateBy(x: x, y: baseY)
        c.scaleBy(x: s, y: s)
        // Two anemones: one rose, one violet, the smaller behind.
        let heads: [(x: Double, r: Double, lit: Color, deep: Color, tip: Color, seed: String)] = [
            (8, 9, tone(Color(red: 0.72, green: 0.52, blue: 0.95)), tone(Color(red: 0.34, green: 0.16, blue: 0.52)),
             tone(Color(red: 0.92, green: 0.86, blue: 1.0)), "anemone-b"),
            (-7, 12, tone(Color(red: 1.0, green: 0.56, blue: 0.64)), tone(Color(red: 0.56, green: 0.16, blue: 0.28)),
             tone(Color(red: 1.0, green: 0.90, blue: 0.80)), "anemone"),
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
            TankPaint.cylinder(&c, column, lit: head.lit.opacity(0.9), base: head.deep.opacity(0.95),
                               shade: head.deep, outline: .black.opacity(0.3), lineWidth: 0.4)
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
                let sway = reduceMotion ? 1.5
                    : sin(t * 1.25 + u * 2.4 + Double((h >> 24) & 0xFF) * 0.02) * 3.2
                let tip = CGPoint(x: rootX + lean + sway, y: rootY - reach)
                tentacles.move(to: CGPoint(x: rootX, y: rootY))
                tentacles.addQuadCurve(to: tip,
                                       control: CGPoint(x: rootX + lean * 0.2, y: rootY - reach * 0.6))
                tips.addEllipse(in: CGRect(x: tip.x - 1.3, y: tip.y - 1.3, width: 2.6, height: 2.6))
            }
            let crown = -head.r * 0.85 - head.r * 1.7
            c.stroke(tentacles, with: .color(head.deep.opacity(0.9)),
                     style: StrokeStyle(lineWidth: 2.8, lineCap: .round))
            c.stroke(tentacles, with: .linearGradient(
                Gradient(colors: [head.deep, head.lit]),
                startPoint: CGPoint(x: head.x, y: -head.r * 0.85), endPoint: CGPoint(x: head.x, y: crown)),
                     style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
            TankPaint.glow(&c, at: CGPoint(x: head.x, y: crown + head.r * 0.4), radius: head.r * 1.6,
                           color: head.tip.opacity(0.22))
            c.fill(tips, with: .color(head.tip))
        }
    }

    /// A glass dome on a turned brass base with a moon jelly inside;
    /// its glow breathes on a six-second pulse, additive, and the
    /// glass catches a highlight.
    private func drawJellyLamp(canvas: inout GraphicsContext, size: CGSize,
                               t: Double, slot: AquariumModel.DecorSlot) {
        let x = slot.x * size.width
        let baseY = ownedBaseY(slot, in: size)
        let s = ownedScaleH(slot, unitHeight: 52, in: size)
        groundShadow(canvas: &canvas, x: x, y: baseY + 1,
                     halfW: 16 * s, alpha: 0.26)
        let pulse = reduceMotion ? 0.6 : 0.55 + 0.45 * sin(t * .pi * 2 / 6)
        var c = canvas
        c.translateBy(x: x, y: baseY)
        c.scaleBy(x: s, y: s)
        let glowColor = Color(red: 0.55, green: 0.85, blue: 0.98)
        // The glow first — under the glass it reads as coming through.
        TankPaint.glow(&c, at: CGPoint(x: 0, y: -24), radius: 28, color: glowColor.opacity(0.30 * pulse + 0.08))
        // The brass base: a turned foot and a collar.
        let foot = Path(roundedRect: CGRect(x: -11, y: -4, width: 22, height: 4), cornerRadius: 1.5)
        let collar = Path(roundedRect: CGRect(x: -9, y: -8, width: 18, height: 4.5), cornerRadius: 1.2)
        let brassLit = Color(red: 0.98, green: 0.84, blue: 0.48)
        let brass = Color(red: 0.72, green: 0.54, blue: 0.24)
        let brassDark = Color(red: 0.34, green: 0.22, blue: 0.08)
        TankPaint.cylinder(&c, foot, lit: brassLit, base: brass, shade: brassDark, outline: .black.opacity(0.4), lineWidth: 0.5)
        TankPaint.cylinder(&c, collar, lit: brassLit, base: brass, shade: brassDark, outline: .black.opacity(0.4), lineWidth: 0.5)
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
        for k in 0..<4 {
            let ax = -4.5 + Double(k) * 3
            var arm = Path()
            arm.move(to: CGPoint(x: ax, y: -23.5 + bob))
            arm.addQuadCurve(to: CGPoint(x: ax + (reduceMotion ? 0 : sin(t * 1.3 + Double(k)) * 2), y: -12),
                             control: CGPoint(x: ax - 2, y: -17 + bob))
            c.stroke(arm, with: .color(Color.white.opacity(0.30 + 0.25 * pulse)), lineWidth: 0.6)
        }
        // The glass: an edge and a long highlight.
        c.stroke(dome, with: .color(Color(red: 0.85, green: 0.95, blue: 1.0).opacity(0.55)), lineWidth: 0.8)
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
                                 slot: AquariumModel.DecorSlot) {
        let tone = decorTone()
        let x = slot.x * size.width
        let baseY = ownedBaseY(slot, in: size)
        let s = ownedScaleW(slot, unitWidth: 64, in: size)
        groundShadow(canvas: &canvas, x: x, y: baseY + 1,
                     halfW: 34 * s, alpha: 0.28)
        var c = canvas
        c.translateBy(x: x, y: baseY)
        c.scaleBy(x: s, y: s)
        // The fans: a translucent blade with a lace of branches.
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
                Gradient(colors: [tone(Color(red: 0.62, green: 0.18, blue: 0.30)).opacity(0.9),
                                  tone(Color(red: 1.0, green: 0.52, blue: 0.58)).opacity(0.75)]),
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
            lace.stroke(branches, with: .color(tone(Color(red: 0.45, green: 0.08, blue: 0.18)).opacity(0.55)), lineWidth: 0.7)
            lace.stroke(cross, with: .color(tone(Color(red: 0.45, green: 0.08, blue: 0.18)).opacity(0.35)), lineWidth: 0.45)
            c.stroke(fan, with: .color(tone(Color(red: 0.40, green: 0.08, blue: 0.16)).opacity(0.7)), lineWidth: 0.6)
        }
        // The staghorn sprig, centre-back.
        var sprig = Path()
        sprig.move(to: CGPoint(x: 2, y: -2)); sprig.addQuadCurve(to: CGPoint(x: 3, y: -25), control: CGPoint(x: 0, y: -14))
        sprig.move(to: CGPoint(x: 1.5, y: -12)); sprig.addQuadCurve(to: CGPoint(x: -6, y: -22), control: CGPoint(x: -4, y: -14))
        sprig.move(to: CGPoint(x: 2.5, y: -16)); sprig.addQuadCurve(to: CGPoint(x: 11, y: -26), control: CGPoint(x: 9, y: -17))
        sprig.move(to: CGPoint(x: 8, y: -20)); sprig.addLine(to: CGPoint(x: 12, y: -18))
        c.stroke(sprig, with: .color(tone(Color(red: 0.26, green: 0.12, blue: 0.34))), style: StrokeStyle(lineWidth: 3.6, lineCap: .round))
        c.stroke(sprig, with: .linearGradient(
            Gradient(colors: [tone(Color(red: 0.50, green: 0.30, blue: 0.62)), tone(Color(red: 0.88, green: 0.72, blue: 0.98))]),
            startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: -26)),
                 style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
        for tip in [CGPoint(x: 3, y: -25), CGPoint(x: -6, y: -22), CGPoint(x: 11, y: -26), CGPoint(x: 12, y: -18)] {
            c.fill(Path(ellipseIn: CGRect(x: tip.x - 1.2, y: tip.y - 1.2, width: 2.4, height: 2.4)),
                   with: .color(tone(Color(red: 0.98, green: 0.92, blue: 1.0))))
        }
        // The brain mound with its meandering ridges.
        var mound = Path()
        mound.move(to: CGPoint(x: -11, y: 0))
        mound.addCurve(to: CGPoint(x: 11, y: 0), control1: CGPoint(x: -12, y: -17), control2: CGPoint(x: 12, y: -17))
        mound.closeSubpath()
        TankPaint.solid(&c, mound, lit: tone(Color(red: 0.98, green: 0.86, blue: 0.56)),
                        base: tone(Color(red: 0.84, green: 0.64, blue: 0.34)),
                        shade: tone(Color(red: 0.44, green: 0.28, blue: 0.12)),
                        outline: tone(Color(red: 0.30, green: 0.18, blue: 0.08)).opacity(0.7), lineWidth: 0.5)
        var ridges = c
        ridges.clip(to: mound)
        var maze = Path()
        for k in 0..<5 {
            let gy = -11.0 + Double(k) * 2.6
            maze.move(to: CGPoint(x: -11, y: gy + 1))
            var gx = -11.0
            while gx < 11 {
                maze.addQuadCurve(to: CGPoint(x: gx + 2.6, y: gy + (Int(gx) % 2 == 0 ? 0.9 : -0.9)),
                                  control: CGPoint(x: gx + 1.3, y: gy - 1.2))
                gx += 2.6
            }
        }
        ridges.stroke(maze, with: .color(tone(Color(red: 0.46, green: 0.28, blue: 0.10)).opacity(0.7)), lineWidth: 0.55)
    }

    /// The bubble wall's air stone: a porous bar set in the sand.
    private func drawAirStone(canvas: inout GraphicsContext, size: CGSize,
                              slot: AquariumModel.DecorSlot) {
        let tone = decorTone()
        let x = slot.x * size.width
        let baseY = ownedBaseY(slot, in: size)
        let s = ownedScaleW(slot, unitWidth: 40, in: size)
        groundShadow(canvas: &canvas, x: x, y: baseY + 1,
                     halfW: 20 * s, alpha: 0.24)
        let stone = Path(roundedRect: CGRect(x: x - 18 * s, y: baseY - 6, width: 36 * s, height: 7),
                         cornerRadius: 3.5)
        TankPaint.solid(&canvas, stone, lit: tone(Color(red: 0.52, green: 0.50, blue: 0.50)),
                        base: tone(Color(red: 0.30, green: 0.28, blue: 0.28)),
                        shade: tone(Color(red: 0.12, green: 0.11, blue: 0.11)), outline: .black.opacity(0.45), lineWidth: 0.7)
        TankPaint.speckle(&canvas, stone, seed: 181, count: 30, size: 1.2,
                          dark: .black.opacity(0.4), light: .white.opacity(0.12))
    }

    /// A curtain of bubbles off an air stone — the column of fizz
    /// runs on the live pass; the stone bakes into the bed
    /// (`drawAirStone`).
    private func drawBubbleWall(canvas: inout GraphicsContext, size: CGSize,
                                t: Double, slot: AquariumModel.DecorSlot) {
        let x = slot.x * size.width
        let baseY = ownedBaseY(slot, in: size)
        let s = ownedScaleW(slot, unitWidth: 40, in: size)
        // The curtain: several parallel bubble streams, each a seeded
        // column rising & wobbling to the surface.
        for i in 0..<5 {
            let h = scatter(AquariumModel.stableHash("bubwall"), i)
            let bx = x + (Double(i) - 2) * 6 * s
            let speed = 30 + Double(h & 0xFF) / 0xFF * 22
            for k in 0..<6 {
                let ph = frac(t * speed / 400 + Double(k) / 6
                              + Double((h >> 8) & 0xFF) / 0xFF)
                let by = baseY - 8 - ph * (baseY - 18)
                guard by > 14 else { continue }
                let wx = bx + sin(t * 2.2 + Double(k) * 1.7 + Double(i)) * 3
                let br = (1.0 + Double((h >> 16) & 0x3) * 0.5 + ph * 1.2) * s * 0.7
                var b = canvas
                b.opacity = 0.5 * (1 - ph * 0.4)
                b.stroke(Path(ellipseIn: CGRect(x: wx - br, y: by - br,
                                                width: br * 2, height: br * 2)),
                         with: .color(.white), lineWidth: 0.7)
            }
        }
    }

    /// The idle game's collectables (docs/TOYS.md): a full-grown fish
    /// sheds a pearl now and then; it rests on the sand under where
    /// the fish was, softly pulsing until tapped or the snail reaches
    /// it. Each drop's hitbox goes into `motion.dropBoxes` — the tap
    /// gesture collects through `toy.collectDrop`, which is the only
    /// mutation; the drawing itself is inert.
    func drawDrops(canvas: inout GraphicsContext, size: CGSize, t: Double,
                           layouts: [String: Layout]) {
        guard let game else { return }
        let m = motion
        m.dropBoxes.removeAll(keepingCapacity: true)
        for drop in game.drops {
            // Anchor near the minting fish's x if it's still in the
            // tank; otherwise a stable per-drop spot along the bed.
            let unitX: Double
            if let l = layouts[drop.fishID] {
                unitX = l.x / size.width
            } else {
                let h = AquariumModel.stableHash("drop-\(drop.id)")
                unitX = 0.12 + 0.76 * Double(h & 0xFFFF) / 0xFFFF
            }
            let x = min(size.width - 16, max(16, unitX * size.width))
            let y = sandTop(atX: x, in: size) - 5
            let pulse = reduceMotion ? 0.5 : 0.5 + 0.5 * sin(t * 2.2 + Double(drop.at.truncatingRemainder(dividingBy: 6)))
            let r = 5.0 + pulse * 1.2
            // A warm halo under the pearl so it reads as a pick-up.
            var halo = canvas
            halo.blendMode = .plusLighter
            halo.fill(Path(ellipseIn: CGRect(x: x - r * 2.4, y: y - r * 2.4,
                                             width: r * 4.8, height: r * 4.8)),
                      with: .radialGradient(
                        Gradient(colors: [Color(red: 1, green: 0.92, blue: 0.70).opacity(0.28 + 0.14 * pulse),
                                          .clear]),
                        center: CGPoint(x: x, y: y), startRadius: 0, endRadius: r * 2.4))
            canvas.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                        with: .radialGradient(
                            Gradient(stops: [
                                .init(color: .white, location: 0),
                                .init(color: Color(red: 0.95, green: 0.88, blue: 0.72), location: 0.55),
                                .init(color: Color(red: 0.72, green: 0.60, blue: 0.46), location: 1),
                            ]),
                            center: CGPoint(x: x - r * 0.3, y: y - r * 0.3),
                            startRadius: 0, endRadius: r * 1.1))
            canvas.stroke(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                          with: .color(.white.opacity(0.35)), lineWidth: 0.6)
            m.dropBoxes.append((drop.id, CGRect(x: x - 16, y: y - 16, width: 32, height: 32)))
        }
    }

    /// The tank's silent "bloop": an eaten pellet, a collected drop or
    /// a tap on the glass pops a small ring with three specks thrown
    /// off it. Under a second, then gone.
    func drawPuffs(canvas: inout GraphicsContext, size: CGSize, now: Date) {
        for puff in motion.puffs {
            let p = clamp01(now.timeIntervalSince(puff.bornAt) / 0.7)
            guard p < 1 else { continue }
            let x = puff.x * size.width
            let y = puff.y * size.height
            let rr = 3 + p * 13
            var ring = canvas
            ring.opacity = (1 - p) * 0.55
            ring.stroke(Path(ellipseIn: CGRect(x: x - rr, y: y - rr,
                                               width: rr * 2, height: rr * 2)),
                        with: .color(.white), lineWidth: 1.1)
            for k in 0..<3 {
                let a = Double(k) * 2.1 + 0.4
                let bx = x + cos(a) * rr * 0.7
                let by = y + sin(a) * rr * 0.7 - p * 8
                let br = 1.2 + Double(k) * 0.5
                var speck = canvas
                speck.opacity = (1 - p) * 0.5
                speck.stroke(Path(ellipseIn: CGRect(x: bx - br, y: by - br,
                                                    width: br * 2, height: br * 2)),
                             with: .color(.white), lineWidth: 0.6)
            }
        }
    }

    /// Pearls fly home: a collected drop or an eaten pellet's pearl
    /// arcs up to the counter chip on a little hop and blinks out on
    /// arrival. Where the toast's "+1" visibly comes from.
    func drawFlights(canvas: inout GraphicsContext, size: CGSize, now: Date) {
        // The pearl HUD chip sits top-left; the approximation is fine —
        // the flight is a flourish, not a survey.
        let target = CGPoint(x: 34, y: 20)
        for flight in motion.flights {
            let p = now.timeIntervalSince(flight.bornAt) / 0.75
            guard p < 1 else { continue }
            let at = AquariumBehavior.flightPoint(from: flight.from, to: target, p: p)
            let fade = 1 - smooth(clamp01((p - 0.85) / 0.15))
            let r = 3.4
            var f = canvas
            f.opacity = fade
            f.fill(Path(ellipseIn: CGRect(x: at.x - r, y: at.y - r,
                                          width: r * 2, height: r * 2)),
                   with: .radialGradient(
                    Gradient(colors: [.white, Color(red: 0.95, green: 0.88, blue: 0.72)]),
                    center: at, startRadius: 0, endRadius: r))
            f.stroke(Path(ellipseIn: CGRect(x: at.x - r, y: at.y - r,
                                            width: r * 2, height: r * 2)),
                     with: .color(.white.opacity(0.6)), lineWidth: 0.6)
        }
    }

    /// The hermit crab shuffles sideways along the sand, pausing to
    /// tuck into its shell. Reduce Motion parks it near the middle.
    func drawHermitCrab(canvas: inout GraphicsContext, size: CGSize, t: Double) {
        let tone = decorTone()
        // A slow shuttle across the bed with rest stops: walk 70% of
        // each ~90 s lap, sit tucked the rest.
        let lap = reduceMotion ? 0.45 : frac(t / 90 + 0.13)
        let walking = lap < 0.7
        let progress = walking ? lap / 0.7 : 1
        let x = size.width * (0.10 + 0.78 * progress)
        let y = sandTop(atX: x, in: size) - 2
        var c = canvas
        c.translateBy(x: x, y: y)
        c.scaleBy(x: 16, y: 12)
        let flesh = tone(Color(red: 0.92, green: 0.40, blue: 0.26))
        let fleshDark = tone(Color(red: 0.52, green: 0.14, blue: 0.08))
        let line = tone(Color(red: 0.25, green: 0.10, blue: 0.06)).opacity(0.8)
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
        TankPaint.solid(&c, sh, lit: tone(Color(red: 1.0, green: 0.93, blue: 0.80)),
                        base: tone(Color(red: 0.84, green: 0.66, blue: 0.48)),
                        shade: tone(Color(red: 0.46, green: 0.30, blue: 0.20)),
                        outline: tone(Color(red: 0.30, green: 0.18, blue: 0.10)).opacity(0.8), lineWidth: 0.035, rim: 0.4)
        var whorl = Path()
        whorl.move(to: CGPoint(x: -0.08, y: -0.26))
        for k in 1...24 {
            let a = Double(k) * 0.42
            let r = 0.02 + Double(k) * 0.012
            whorl.addLine(to: CGPoint(x: -0.08 + cos(a) * r * 1.2, y: -0.26 + sin(a) * r))
        }
        var bands = c
        bands.clip(to: sh)
        bands.stroke(whorl, with: .color(tone(Color(red: 0.42, green: 0.24, blue: 0.14)).opacity(0.75)), lineWidth: 0.035)
        TankPaint.speckle(&bands, sh, seed: 191, count: 10, size: 0.05,
                          dark: tone(Color(red: 0.55, green: 0.28, blue: 0.14)).opacity(0.55), light: .white.opacity(0.4))
        // Eyes on stalks peek from under the shell lip — out when
        // walking, tucked (hidden) when resting.
        if walking {
            for dx in [0.30, 0.44] {
                var stalk = Path()
                stalk.move(to: CGPoint(x: dx - 0.06, y: -0.06))
                stalk.addQuadCurve(to: CGPoint(x: dx, y: -0.30),
                                   control: CGPoint(x: dx - 0.02, y: -0.20))
                c.stroke(stalk, with: .color(fleshDark), style: StrokeStyle(lineWidth: 0.06, lineCap: .round))
                c.stroke(stalk, with: .color(flesh), style: StrokeStyle(lineWidth: 0.035, lineCap: .round))
                c.fill(Path(ellipseIn: CGRect(x: dx - 0.045, y: -0.36, width: 0.09, height: 0.10)),
                       with: .color(tone(Color(red: 0.05, green: 0.05, blue: 0.08))))
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
            TankPaint.solid(&c, claw, lit: tone(Color(red: 1.0, green: 0.62, blue: 0.46)), base: flesh,
                            shade: fleshDark, outline: line, lineWidth: 0.03)
        }
    }

    /// A snail inches along the sand — about four minutes a crossing.
    /// Reduce Motion sits it mid-tank.
    func drawSnail(canvas: inout GraphicsContext, size: CGSize, t: Double) {
        let tone = decorTone()
        let crawl = reduceMotion ? 0.42 : frac(t * 0.0042 + 0.6)
        let x = size.width * (0.06 + crawl * 0.88)
        // It inches along the dune crest, not the glass bottom.
        let y = sandTop(atX: x, in: size) - 1
        var s = canvas
        s.opacity = 0.85
        s.translateBy(x: x, y: y)
        s.scaleBy(x: 25, y: 19)
        let flesh = tone(Color(red: 0.72, green: 0.66, blue: 0.56))
        let fleshDark = tone(Color(red: 0.36, green: 0.30, blue: 0.24))
        var body = Path()
        body.move(to: CGPoint(x: -0.52, y: 0.05))
        body.addQuadCurve(to: CGPoint(x: 0.62, y: 0.02), control: CGPoint(x: 0.1, y: 0.16))
        body.addQuadCurve(to: CGPoint(x: 0.55, y: -0.18), control: CGPoint(x: 0.68, y: -0.08))
        body.addQuadCurve(to: CGPoint(x: -0.1, y: -0.14), control: CGPoint(x: 0.2, y: -0.26))
        body.addQuadCurve(to: CGPoint(x: -0.52, y: 0.05), control: CGPoint(x: -0.36, y: -0.08))
        body.closeSubpath()
        TankPaint.solid(&s, body, lit: tone(Color(red: 0.90, green: 0.86, blue: 0.76)), base: flesh, shade: fleshDark,
                        outline: fleshDark.opacity(0.8), lineWidth: 0.03, rim: 0.3)
        // Two eyestalks, because it is a screensaver.
        for dx in [0.42, 0.55] {
            var stalk = Path()
            stalk.move(to: CGPoint(x: dx - 0.1, y: -0.14))
            stalk.addQuadCurve(to: CGPoint(x: dx, y: -0.42), control: CGPoint(x: dx - 0.05, y: -0.30))
            s.stroke(stalk, with: .color(fleshDark), style: StrokeStyle(lineWidth: 0.06, lineCap: .round))
            s.stroke(stalk, with: .color(flesh), style: StrokeStyle(lineWidth: 0.035, lineCap: .round))
            s.fill(Path(ellipseIn: CGRect(x: dx - 0.05, y: -0.48, width: 0.10, height: 0.10)),
                   with: .color(tone(Color(red: 0.12, green: 0.10, blue: 0.10))))
            s.fill(Path(ellipseIn: CGRect(x: dx - 0.015, y: -0.47, width: 0.035, height: 0.035)),
                   with: .color(.white.opacity(0.9)))
        }
        // The shell: a banded spiral, lit from above.
        let shellRect = CGRect(x: -0.44, y: -0.66, width: 0.62, height: 0.62)
        let shell = Path(ellipseIn: shellRect)
        TankPaint.solid(&s, shell, lit: tone(Color(red: 0.96, green: 0.76, blue: 0.48)),
                        base: tone(Color(red: 0.72, green: 0.44, blue: 0.22)),
                        shade: tone(Color(red: 0.34, green: 0.18, blue: 0.08)),
                        outline: tone(Color(red: 0.26, green: 0.14, blue: 0.06)).opacity(0.85), lineWidth: 0.035, rim: 0.35)
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
        inner.stroke(spiral, with: .color(tone(Color(red: 0.98, green: 0.90, blue: 0.72)).opacity(0.7)), lineWidth: 0.05)
        inner.stroke(spiral.offsetBy(dx: 0.012, dy: 0.012),
                     with: .color(tone(Color(red: 0.30, green: 0.14, blue: 0.06)).opacity(0.6)), lineWidth: 0.025)
    }
}
