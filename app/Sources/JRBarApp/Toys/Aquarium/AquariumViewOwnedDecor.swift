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

    /// A sunken hull: broken keel listing on the dune, a snapped mast
    /// leaning off it, all dim browns behind the swimmers.
    private func drawShipwreck(canvas: inout GraphicsContext, size: CGSize,
                               slot: AquariumModel.DecorSlot) {
        let x = slot.x * size.width
        let baseY = ownedBaseY(slot, in: size)
        let s = ownedScaleW(slot, unitWidth: 90, in: size)
        groundShadow(canvas: &canvas, x: x, y: baseY + 1,
                     halfW: 46 * s, alpha: 0.20)
        var c = canvas
        c.translateBy(x: x, y: baseY)
        c.scaleBy(x: s, y: s)
        c.opacity = 0.80
        let wood = Color(red: 0.30, green: 0.22, blue: 0.14)
        let woodDark = Color(red: 0.18, green: 0.13, blue: 0.08)
        // The hull: a wallowing bowl with a jagged break amidships.
        var hull = Path()
        hull.move(to: CGPoint(x: -44, y: -26))
        hull.addQuadCurve(to: CGPoint(x: -10, y: 0), control: CGPoint(x: -40, y: -4))
        hull.addLine(to: CGPoint(x: -4, y: -8))
        hull.addLine(to: CGPoint(x: 4, y: -2))
        hull.addLine(to: CGPoint(x: 12, y: -10))
        hull.addQuadCurve(to: CGPoint(x: 44, y: -20), control: CGPoint(x: 30, y: -6))
        hull.addQuadCurve(to: CGPoint(x: 36, y: 0), control: CGPoint(x: 44, y: -8))
        hull.closeSubpath()
        c.fill(hull, with: .color(wood))
        c.stroke(hull, with: .color(woodDark), lineWidth: 1.2)
        // Plank seams.
        for k in 0..<3 {
            var seam = Path()
            let y = -6.0 - Double(k) * 7
            seam.move(to: CGPoint(x: -40, y: y))
            seam.addQuadCurve(to: CGPoint(x: 40, y: y - 4),
                              control: CGPoint(x: 0, y: y + 4))
            c.stroke(seam, with: .color(woodDark.opacity(0.5)), lineWidth: 0.8)
        }
        // The snapped mast leaning forward, tattered yard still on.
        var mast = Path()
        mast.move(to: CGPoint(x: -6, y: -10))
        mast.addLine(to: CGPoint(x: 6, y: -62))
        c.stroke(mast, with: .color(wood), lineWidth: 3.5)
        var yard = Path()
        yard.move(to: CGPoint(x: -8, y: -46))
        yard.addLine(to: CGPoint(x: 22, y: -52))
        c.stroke(yard, with: .color(woodDark), lineWidth: 2)
        var sail = Path()
        sail.move(to: CGPoint(x: -6, y: -46))
        sail.addLine(to: CGPoint(x: 18, y: -51))
        sail.addLine(to: CGPoint(x: 10, y: -30))
        sail.addLine(to: CGPoint(x: 2, y: -36))
        sail.closeSubpath()
        c.fill(sail, with: .color(Color(red: 0.45, green: 0.42, blue: 0.36)
                                  .opacity(0.55)))
    }

    /// The tipped storage jar — the octopus's home when it has one.
    private func drawAmphora(canvas: inout GraphicsContext, size: CGSize,
                             slot: AquariumModel.DecorSlot) {
        let x = slot.x * size.width
        let baseY = ownedBaseY(slot, in: size)
        let s = ownedScaleW(slot, unitWidth: 34, in: size)
        groundShadow(canvas: &canvas, x: x, y: baseY + 1,
                     halfW: 22 * s, alpha: 0.22)
        var c = canvas
        c.translateBy(x: x, y: baseY)
        c.scaleBy(x: s, y: s)
        c.rotate(by: .radians(-1.15))
        let clay = Color(red: 0.52, green: 0.36, blue: 0.24)
        let clayDark = Color(red: 0.34, green: 0.22, blue: 0.14)
        var jar = Path()
        jar.move(to: CGPoint(x: -8, y: -34))
        jar.addCurve(to: CGPoint(x: -14, y: -6),
                     control1: CGPoint(x: -16, y: -28),
                     control2: CGPoint(x: -16, y: -14))
        jar.addQuadCurve(to: CGPoint(x: 14, y: -6),
                         control: CGPoint(x: 0, y: 4))
        jar.addCurve(to: CGPoint(x: 8, y: -34),
                     control1: CGPoint(x: 16, y: -14),
                     control2: CGPoint(x: 16, y: -28))
        jar.closeSubpath()
        c.fill(jar, with: .color(clay))
        c.stroke(jar, with: .color(clayDark), lineWidth: 1)
        // Rim & the dark mouth the octopus watches from.
        c.fill(Path(ellipseIn: CGRect(x: -9, y: -37, width: 18, height: 7)),
               with: .color(clayDark))
        c.fill(Path(ellipseIn: CGRect(x: -6.5, y: -36, width: 13, height: 5)),
               with: .color(.black.opacity(0.85)))
        // A band & a handle stub.
        c.stroke(Path(ellipseIn: CGRect(x: -13, y: -20, width: 26, height: 10)),
                 with: .color(clayDark.opacity(0.6)), lineWidth: 1)
    }

    /// A bust on a plinth — someone important, once.
    private func drawStatue(canvas: inout GraphicsContext, size: CGSize,
                            slot: AquariumModel.DecorSlot) {
        let x = slot.x * size.width
        let baseY = ownedBaseY(slot, in: size)
        let s = ownedScaleH(slot, unitHeight: 45, in: size)
        groundShadow(canvas: &canvas, x: x, y: baseY + 1,
                     halfW: 20 * s, alpha: 0.22)
        var c = canvas
        c.translateBy(x: x, y: baseY)
        c.scaleBy(x: s, y: s)
        c.opacity = 0.85
        let stone = Color(red: 0.52, green: 0.55, blue: 0.58)
        let stoneDark = Color(red: 0.34, green: 0.36, blue: 0.40)
        // Plinth.
        c.fill(Path(CGRect(x: -12, y: -16, width: 24, height: 16)),
               with: .color(stoneDark))
        c.stroke(Path(CGRect(x: -12, y: -16, width: 24, height: 16)),
                 with: .color(stone.opacity(0.5)), lineWidth: 0.8)
        // Shoulders & head.
        var bust = Path()
        bust.move(to: CGPoint(x: -11, y: -16))
        bust.addQuadCurve(to: CGPoint(x: -5, y: -30), control: CGPoint(x: -11, y: -26))
        bust.addQuadCurve(to: CGPoint(x: 5, y: -30), control: CGPoint(x: 0, y: -33))
        bust.addQuadCurve(to: CGPoint(x: 11, y: -16), control: CGPoint(x: 11, y: -26))
        bust.closeSubpath()
        c.fill(bust, with: .color(stone))
        c.fill(Path(ellipseIn: CGRect(x: -6, y: -44, width: 12, height: 15)),
               with: .color(stone))
        // Nose & brow shadow — a face, barely.
        c.stroke(Path(ellipseIn: CGRect(x: -6, y: -44, width: 12, height: 15)),
                 with: .color(stoneDark), lineWidth: 0.8)
        var nose = Path()
        nose.move(to: CGPoint(x: 1, y: -38))
        nose.addLine(to: CGPoint(x: 3, y: -34))
        c.stroke(nose, with: .color(stoneDark), lineWidth: 1)
    }

    /// Three fluted columns, one fallen — the ruin's rhythm.
    private func drawColumns(canvas: inout GraphicsContext, size: CGSize,
                             slot: AquariumModel.DecorSlot) {
        let x = slot.x * size.width
        let baseY = ownedBaseY(slot, in: size)
        let s = ownedScaleH(slot, unitHeight: 72, in: size)
        groundShadow(canvas: &canvas, x: x, y: baseY + 1,
                     halfW: 44 * s, alpha: 0.20)
        var c = canvas
        c.translateBy(x: x, y: baseY)
        c.scaleBy(x: s, y: s)
        c.opacity = 0.82
        let marble = Color(red: 0.56, green: 0.58, blue: 0.62)
        let marbleDark = Color(red: 0.38, green: 0.40, blue: 0.44)
        // Two standing, heights varied, flutes stroked down.
        let heights: [(x: Double, h: Double)] = [(-28, 54), (-4, 67)]
        for col in heights {
            c.fill(Path(CGRect(x: col.x - 7, y: -col.h, width: 14, height: col.h)),
                   with: .color(marble))
            c.stroke(Path(CGRect(x: col.x - 7, y: -col.h, width: 14, height: col.h)),
                     with: .color(marbleDark), lineWidth: 1)
            for k in -1...1 {
                var flute = Path()
                flute.move(to: CGPoint(x: col.x + Double(k) * 4, y: -col.h + 3))
                flute.addLine(to: CGPoint(x: col.x + Double(k) * 4, y: -4))
                c.stroke(flute, with: .color(marbleDark.opacity(0.45)), lineWidth: 0.9)
            }
            // Capital.
            c.fill(Path(CGRect(x: col.x - 9, y: -col.h - 5, width: 18, height: 5)),
                   with: .color(marbleDark))
        }
        // The fallen one on its side out front.
        var fallen = canvas
        fallen.translateBy(x: x + 36 * s, y: baseY - 6 * s)
        fallen.scaleBy(x: s, y: s)
        fallen.rotate(by: .radians(0.22))
        fallen.opacity = 0.82
        fallen.fill(Path(roundedRect: CGRect(x: -22, y: -7, width: 44, height: 14),
                         cornerRadius: 5),
                    with: .color(marble))
        fallen.stroke(Path(roundedRect: CGRect(x: -22, y: -7, width: 44, height: 14),
                           cornerRadius: 5),
                      with: .color(marbleDark), lineWidth: 1)
    }

    /// The cone: a broad shield with a rimmed crater bowl. Its throat
    /// always smoulders a little — a warm inner glow at any hour that
    /// goes molten at night (or in the dark themes), when the live
    /// pass's `drawVolcanoGlow` adds the halo and the ember climb.
    private func drawVolcano(canvas: inout GraphicsContext, size: CGSize,
                             slot: AquariumModel.DecorSlot, lit: Bool) {
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
        c.fill(cone, with: .linearGradient(
            Gradient(colors: [Color(red: 0.30, green: 0.26, blue: 0.24),
                              Color(red: 0.14, green: 0.11, blue: 0.11)]),
            startPoint: CGPoint(x: 0, y: -44), endPoint: CGPoint(x: 0, y: 0)))
        c.stroke(cone, with: .color(.black.opacity(0.35)), lineWidth: 1.2)
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
                                  ? Color(red: 0.55, green: 0.14, blue: 0.05)
                                  : Color(red: 0.10, green: 0.08, blue: 0.08)))
        c.stroke(bowl, with: .color(.black.opacity(0.4)), lineWidth: 0.8)
        // The smoulder: a warm breath in the throat at every hour,
        // molten once lit — plus a thin hot rim on the crater's lip.
        var g = c
        g.blendMode = .plusLighter
        g.fill(bowl, with: .radialGradient(
            Gradient(colors: [Color(red: 1.0, green: 0.5, blue: 0.12)
                                .opacity(lit ? 0.95 : 0.30), .clear]),
            center: CGPoint(x: 0, y: -45), startRadius: 0, endRadius: 18))
        // A dull orange seam down the cone's face — the lava's old path.
        var lava = Path()
        lava.move(to: CGPoint(x: 4, y: -42))
        lava.addQuadCurve(to: CGPoint(x: 12, y: -12), control: CGPoint(x: 8, y: -26))
        c.stroke(lava, with: .color(Color(red: 0.75, green: 0.25, blue: 0.08)
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
        if let s = slot(.driftwood) { drawDriftwood(canvas: &canvas, size: size, slot: s) }
        if let s = slot(.anemoneBed) { drawAnemone(canvas: &canvas, size: size, t: t, slot: s) }
        if let s = slot(.moonJellyLamp) { drawJellyLamp(canvas: &canvas, size: size, t: t, slot: s) }
        if let s = slot(.coralGarden) { drawCoralGarden(canvas: &canvas, size: size, slot: s) }
        if let s = slot(.bubbleWall) { drawBubbleWall(canvas: &canvas, size: size, t: t, slot: s) }
        // The volcano's live half rides along when the crater's lit.
        if let s = game.owns(.volcano) ? AquariumModel.decorSlot(for: .volcano) : nil,
           nightFactor(t: t) > 0.45 || isDarkTheme {
            drawVolcanoGlow(canvas: &canvas, size: size, t: t, slot: s)
        }
    }

    /// A smoothed water-logged branch, half settled into the sand.
    private func drawDriftwood(canvas: inout GraphicsContext, size: CGSize,
                               slot: AquariumModel.DecorSlot) {
        let x = slot.x * size.width
        let baseY = ownedBaseY(slot, in: size)
        let s = ownedScaleW(slot, unitWidth: 60, in: size)
        groundShadow(canvas: &canvas, x: x, y: baseY + 1,
                     halfW: 30 * s, alpha: 0.24)
        var c = canvas
        c.translateBy(x: x, y: baseY)
        c.scaleBy(x: s, y: s)
        let wood = Color(red: 0.48, green: 0.40, blue: 0.32)
        let woodDark = Color(red: 0.30, green: 0.24, blue: 0.18)
        var log = Path()
        log.move(to: CGPoint(x: -30, y: -4))
        log.addQuadCurve(to: CGPoint(x: 26, y: -14), control: CGPoint(x: -6, y: -16))
        log.addQuadCurve(to: CGPoint(x: 30, y: -6), control: CGPoint(x: 28, y: -11))
        log.addQuadCurve(to: CGPoint(x: -26, y: 0), control: CGPoint(x: 2, y: -3))
        log.closeSubpath()
        c.fill(log, with: .color(wood))
        c.stroke(log, with: .color(woodDark), lineWidth: 1)
        // A forked stub and grain lines.
        var stub = Path()
        stub.move(to: CGPoint(x: -8, y: -10))
        stub.addQuadCurve(to: CGPoint(x: -16, y: -24), control: CGPoint(x: -10, y: -18))
        c.stroke(stub, with: .color(wood), lineWidth: 4)
        for k in 0..<2 {
            var grain = Path()
            let y = -6.0 - Double(k) * 4
            grain.move(to: CGPoint(x: -26, y: y))
            grain.addQuadCurve(to: CGPoint(x: 24, y: y - 6),
                               control: CGPoint(x: -2, y: y - 2))
            c.stroke(grain, with: .color(woodDark.opacity(0.4)), lineWidth: 0.8)
        }
    }

    /// A bed of anemone tentacles, swaying in a slow wave — the live
    /// pass keeps them breathing; Reduce Motion holds a soft lean.
    private func drawAnemone(canvas: inout GraphicsContext, size: CGSize,
                             t: Double, slot: AquariumModel.DecorSlot) {
        let x = slot.x * size.width
        let baseY = ownedBaseY(slot, in: size)
        let s = ownedScaleW(slot, unitWidth: 44, in: size)
        groundShadow(canvas: &canvas, x: x, y: baseY + 1,
                     halfW: 26 * s, alpha: 0.22)
        var c = canvas
        c.translateBy(x: x, y: baseY)
        c.scaleBy(x: s, y: s)
        for i in 0..<14 {
            let h = scatter(AquariumModel.stableHash("anemone"), i)
            let rootX = (Double(h & 0xFF) / 0xFF - 0.5) * 40
            let reach = 14 + Double((h >> 8) & 0xFF) / 0xFF * 14
            let lean = (Double((h >> 16) & 0xFF) / 0xFF - 0.5) * 10
            let sway = reduceMotion ? 2.0
                : sin(t * 1.3 + Double(h >> 24 & 0xFF) * 0.1) * 4
            var tent = Path()
            tent.move(to: CGPoint(x: rootX, y: 0))
            tent.addQuadCurve(
                to: CGPoint(x: rootX + lean + sway, y: -reach),
                control: CGPoint(x: rootX + lean * 0.3, y: -reach * 0.5))
            let hue = Double((h >> 32) & 0xFF) / 0xFF
            c.stroke(tent, with: .color(
                Color(red: 0.75 + hue * 0.15, green: 0.35 + hue * 0.25,
                      blue: 0.50 + hue * 0.20).opacity(0.85)),
                     style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
            // The pale tip.
            c.fill(Path(ellipseIn: CGRect(x: rootX + lean + sway - 1.8,
                                          y: -reach - 1.8,
                                          width: 3.6, height: 3.6)),
                   with: .color(Color(red: 0.95, green: 0.80, blue: 0.85)
                                .opacity(0.9)))
        }
    }

    /// A glass dome on a brass base with a moon jelly inside; its
    /// glow breathes on a six-second pulse, additive.
    private func drawJellyLamp(canvas: inout GraphicsContext, size: CGSize,
                               t: Double, slot: AquariumModel.DecorSlot) {
        let x = slot.x * size.width
        let baseY = ownedBaseY(slot, in: size)
        let s = ownedScaleH(slot, unitHeight: 52, in: size)
        groundShadow(canvas: &canvas, x: x, y: baseY + 1,
                     halfW: 16 * s, alpha: 0.22)
        let pulse = reduceMotion ? 0.6 : 0.55 + 0.45 * sin(t * .pi * 2 / 6)
        var c = canvas
        c.translateBy(x: x, y: baseY)
        c.scaleBy(x: s, y: s)
        // The glow first — under the glass it reads as coming through.
        var g = c
        g.blendMode = .plusLighter
        g.fill(Path(ellipseIn: CGRect(x: -22, y: -52, width: 44, height: 52)),
               with: .radialGradient(
                   Gradient(colors: [Color(red: 0.55, green: 0.85, blue: 0.95)
                                       .opacity(0.35 * pulse + 0.08), .clear]),
                   center: CGPoint(x: 0, y: -28), startRadius: 0, endRadius: 26))
        // Base & dome.
        c.fill(Path(roundedRect: CGRect(x: -9, y: -6, width: 18, height: 6),
                    cornerRadius: 2),
               with: .color(Color(red: 0.55, green: 0.45, blue: 0.25)))
        var dome = Path()
        dome.move(to: CGPoint(x: -11, y: -6))
        dome.addQuadCurve(to: CGPoint(x: 11, y: -6), control: CGPoint(x: 0, y: -46))
        dome.closeSubpath()
        c.fill(dome, with: .color(Color(red: 0.65, green: 0.85, blue: 0.95)
                                  .opacity(0.18)))
        c.stroke(dome, with: .color(Color(red: 0.80, green: 0.92, blue: 1.0)
                                    .opacity(0.45)),
                 lineWidth: 1)
        // The jelly: a bell & two trailing arms, brighter on the pulse.
        c.fill(Path(ellipseIn: CGRect(x: -6, y: -30, width: 12, height: 8)),
               with: .color(Color(red: 0.80, green: 0.92, blue: 1.0)
                            .opacity(0.5 + 0.3 * pulse)))
        for k in -1...1 {
            var arm = Path()
            arm.move(to: CGPoint(x: Double(k) * 3, y: -22))
            arm.addQuadCurve(to: CGPoint(x: Double(k) * 3 + sin(t + Double(k)) * 2,
                                         y: -12),
                             control: CGPoint(x: Double(k) * 3 - 2, y: -17))
            c.stroke(arm, with: .color(Color(red: 0.80, green: 0.92, blue: 1.0)
                                       .opacity(0.35 + 0.25 * pulse)),
                     lineWidth: 1)
        }
    }

    /// A cluster of varied corals — a couple of fans, a brain, a
    /// branching sprig — sharing one footprint.
    private func drawCoralGarden(canvas: inout GraphicsContext, size: CGSize,
                                 slot: AquariumModel.DecorSlot) {
        let x = slot.x * size.width
        let baseY = ownedBaseY(slot, in: size)
        let s = ownedScaleW(slot, unitWidth: 64, in: size)
        groundShadow(canvas: &canvas, x: x, y: baseY + 1,
                     halfW: 34 * s, alpha: 0.24)
        var c = canvas
        c.translateBy(x: x, y: baseY)
        c.scaleBy(x: s, y: s)
        // A fan coral each side — reuse the seeded piece's geometry in
        // miniature.
        for side in [-1.0, 1.0] {
            var fan = Path()
            let bx = side * 16
            fan.move(to: CGPoint(x: bx, y: 0))
            fan.addQuadCurve(to: CGPoint(x: bx + side * 14, y: -26),
                             control: CGPoint(x: bx + side * 2, y: -20))
            fan.addQuadCurve(to: CGPoint(x: bx + side * 6, y: -10),
                             control: CGPoint(x: bx + side * 12, y: -12))
            fan.closeSubpath()
            c.fill(fan, with: .color(Color(red: 0.82, green: 0.42, blue: 0.50)
                                     .opacity(0.85)))
            c.stroke(fan, with: .color(Color(red: 0.55, green: 0.22, blue: 0.32)),
                     lineWidth: 0.8)
        }
        // The brain mound with its grooves.
        c.fill(Path(ellipseIn: CGRect(x: -10, y: -14, width: 20, height: 14)),
               with: .color(Color(red: 0.85, green: 0.68, blue: 0.42)))
        for k in 0..<3 {
            var groove = Path()
            let gy = -12 + Double(k) * 4
            groove.move(to: CGPoint(x: -8, y: gy))
            groove.addQuadCurve(to: CGPoint(x: 8, y: gy),
                                control: CGPoint(x: 0, y: gy - 4))
            c.stroke(groove, with: .color(Color(red: 0.55, green: 0.40, blue: 0.22)),
                     lineWidth: 0.8)
        }
        // Branching sprig centre-back.
        var sprig = Path()
        sprig.move(to: CGPoint(x: 2, y: -2))
        sprig.addLine(to: CGPoint(x: 2, y: -22))
        sprig.move(to: CGPoint(x: 2, y: -14))
        sprig.addLine(to: CGPoint(x: -4, y: -20))
        sprig.move(to: CGPoint(x: 2, y: -16))
        sprig.addLine(to: CGPoint(x: 9, y: -24))
        c.stroke(sprig, with: .color(Color(red: 0.70, green: 0.45, blue: 0.70)),
                 style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
    }

    /// A curtain of bubbles off an air stone — the column of fizz
    /// runs on the live pass; the stone itself is a dark pebble bar.
    private func drawBubbleWall(canvas: inout GraphicsContext, size: CGSize,
                                t: Double, slot: AquariumModel.DecorSlot) {
        let x = slot.x * size.width
        let baseY = ownedBaseY(slot, in: size)
        let s = ownedScaleW(slot, unitWidth: 40, in: size)
        // The air stone.
        canvas.fill(Path(roundedRect: CGRect(x: x - 18 * s,
                                             y: baseY - 5,
                                             width: 36 * s, height: 6),
                         cornerRadius: 3),
                    with: .color(Color(red: 0.18, green: 0.16, blue: 0.14)))
        groundShadow(canvas: &canvas, x: x, y: baseY + 1,
                     halfW: 20 * s, alpha: 0.18)
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
        let flesh = Color(red: 0.78, green: 0.42, blue: 0.30)
        let shell = Color(red: 0.68, green: 0.55, blue: 0.42)
        if walking && !reduceMotion {
            // Little stepping legs under the shell.
            let step = sin(t * 14)
            for k in 0..<3 {
                var leg = Path()
                let lx = -0.25 + Double(k) * 0.22
                leg.move(to: CGPoint(x: lx, y: -0.05))
                leg.addLine(to: CGPoint(x: lx + step * (k.isMultiple(of: 2) ? 0.10 : -0.10),
                                        y: 0.10))
                c.stroke(leg, with: .color(flesh), lineWidth: 0.06)
            }
        }
        // The borrowed shell: a bump with a spiral hint.
        var sh = Path()
        sh.move(to: CGPoint(x: -0.42, y: 0.06))
        sh.addQuadCurve(to: CGPoint(x: 0.30, y: 0.04), control: CGPoint(x: -0.05, y: 0.14))
        sh.addQuadCurve(to: CGPoint(x: 0.34, y: -0.30), control: CGPoint(x: 0.44, y: -0.08))
        sh.addQuadCurve(to: CGPoint(x: -0.20, y: -0.52), control: CGPoint(x: 0.20, y: -0.56))
        sh.addQuadCurve(to: CGPoint(x: -0.42, y: 0.06), control: CGPoint(x: -0.48, y: -0.30))
        sh.closeSubpath()
        c.fill(sh, with: .color(shell))
        c.stroke(sh, with: .color(Color(red: 0.45, green: 0.34, blue: 0.26)),
                 lineWidth: 0.04)
        c.stroke(Path(ellipseIn: CGRect(x: -0.22, y: -0.40, width: 0.24, height: 0.22)),
                 with: .color(Color(red: 0.45, green: 0.34, blue: 0.24).opacity(0.7)),
                 lineWidth: 0.045)
        // Eyes on stalks peek from under the shell lip — out when
        // walking, tucked (hidden) when resting.
        if walking {
            for dx in [0.30, 0.44] {
                var stalk = Path()
                stalk.move(to: CGPoint(x: dx - 0.06, y: -0.06))
                stalk.addQuadCurve(to: CGPoint(x: dx, y: -0.30),
                                   control: CGPoint(x: dx - 0.02, y: -0.20))
                c.stroke(stalk, with: .color(flesh), lineWidth: 0.045)
                c.fill(Path(ellipseIn: CGRect(x: dx - 0.035, y: -0.345,
                                              width: 0.07, height: 0.07)),
                       with: .color(.white))
                c.fill(Path(ellipseIn: CGRect(x: dx - 0.012, y: -0.322,
                                              width: 0.03, height: 0.03)),
                       with: .color(.black))
            }
            // One claw.
            var claw = Path()
            claw.move(to: CGPoint(x: 0.44, y: 0.04))
            claw.addQuadCurve(to: CGPoint(x: 0.62, y: -0.10),
                              control: CGPoint(x: 0.58, y: 0.02))
            claw.addQuadCurve(to: CGPoint(x: 0.52, y: 0.02),
                              control: CGPoint(x: 0.60, y: -0.02))
            claw.closeSubpath()
            c.fill(claw, with: .color(flesh))
        }
    }

    /// A snail inches along the sand — about four minutes a crossing.
    /// Reduce Motion sits it mid-tank.
    func drawSnail(canvas: inout GraphicsContext, size: CGSize, t: Double) {
        let crawl = reduceMotion ? 0.42 : frac(t * 0.0042 + 0.6)
        let x = size.width * (0.06 + crawl * 0.88)
        // It inches along the dune crest, not the glass bottom.
        let y = sandTop(atX: x, in: size) - 1
        var s = canvas
        s.opacity = 0.85
        s.translateBy(x: x, y: y)
        s.scaleBy(x: 25, y: 19)
        let flesh = Color(red: 0.55, green: 0.45, blue: 0.34)
        var body = Path()
        body.move(to: CGPoint(x: -0.5, y: 0.05))
        body.addQuadCurve(to: CGPoint(x: 0.62, y: 0.02), control: CGPoint(x: 0.1, y: 0.16))
        body.addQuadCurve(to: CGPoint(x: 0.55, y: -0.18), control: CGPoint(x: 0.66, y: -0.08))
        body.addQuadCurve(to: CGPoint(x: -0.1, y: -0.14), control: CGPoint(x: 0.2, y: -0.26))
        body.addQuadCurve(to: CGPoint(x: -0.5, y: 0.05), control: CGPoint(x: -0.36, y: -0.08))
        body.closeSubpath()
        s.fill(body, with: .color(flesh))
        // The shell, with a hint of spiral.
        s.fill(Path(ellipseIn: CGRect(x: -0.42, y: -0.62, width: 0.58, height: 0.58)),
               with: .color(Color(red: 0.62, green: 0.40, blue: 0.24)))
        s.stroke(Path(ellipseIn: CGRect(x: -0.30, y: -0.50, width: 0.34, height: 0.34)),
                 with: .color(Color(red: 0.40, green: 0.25, blue: 0.14).opacity(0.8)),
                 lineWidth: 0.06)
        // Two eyestalks, because it is a screensaver.
        for dx in [0.42, 0.55] {
            var stalk = Path()
            stalk.move(to: CGPoint(x: dx - 0.1, y: -0.14))
            stalk.addQuadCurve(to: CGPoint(x: dx, y: -0.42), control: CGPoint(x: dx - 0.05, y: -0.30))
            s.stroke(stalk, with: .color(flesh), lineWidth: 0.05)
            s.fill(Path(ellipseIn: CGRect(x: dx - 0.045, y: -0.47, width: 0.09, height: 0.09)),
                   with: .color(.white.opacity(0.9)))
        }
    }
}
