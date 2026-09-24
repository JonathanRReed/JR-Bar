import AppKit
import JRBarCore
import SwiftUI

/// The back wall's backdrop.
extension AquariumView {
    // MARK: Backdrop

    /// The distance behind the bed (docs/TOYS.md shop), layered like a
    /// painted set so the tank has depth: a far ridge barely darker
    /// than the water, then the backdrop's own tier — "classic" a
    /// distant reef of low coral heads, reefwall a coral wall that
    /// rises at both ends and dips in the middle so it frames the fish,
    /// rocky a stand of spires — and, for the walls, a nearer outcrop
    /// at each end. Each tier is one silhouette in the water's own
    /// colour, lit along its crown from the surface and fading into the
    /// haze at its foot, so far things are bluer and softer than near
    /// ones. Drawn on the far still pass.
    func drawBackdrop(canvas: inout GraphicsContext, size: CGSize) {
        // A canvas caught mid-layout with no height would lay its
        // silhouettes out of nothing; a tank that short has no wall.
        guard size.height >= 8, size.width > 0 else { return }
        let far = ridge(in: size, base: 0.665, swell: 0.05, seed: 11)
        paintTier(far, canvas: &canvas, size: size, depth: 0, top: size.height * 0.60)
        switch backdropKey {
        case "reefwall":
            let wall = reefTier(in: size, rise: 0.15, floor: 0.70, seed: 23, count: 22)
            paintTier(wall, canvas: &canvas, size: size, depth: 0.45, top: size.height * 0.50)
            let near = reefTier(in: size, rise: 0.24, floor: 0.80, seed: 41, count: 10, edgesOnly: true)
            paintTier(near, canvas: &canvas, size: size, depth: 0.8, top: size.height * 0.50)
        case "rocky":
            let tips = spireTips(in: size, rise: 0.20, floor: 0.72, seed: 61, spires: 9)
            let spires = rockTier(tips, in: size, floor: 0.72, seed: 61, rubble: true)
            paintTier(spires, canvas: &canvas, size: size, depth: 0.45, top: size.height * 0.46)
            paintFacets(tips, clip: spires, canvas: &canvas, size: size, depth: 0.45, floor: 0.72)
            let nearTips = spireTips(in: size, rise: 0.26, floor: 0.82, seed: 71, spires: 5, edgesOnly: true)
            let near = rockTier(nearTips, in: size, floor: 0.82, seed: 71, rubble: false)
            paintTier(near, canvas: &canvas, size: size, depth: 0.8, top: size.height * 0.46)
            paintFacets(nearTips, clip: near, canvas: &canvas, size: size, depth: 0.8, floor: 0.82)
        default:
            // Open water: a far reef of low coral heads, a fan or a
            // branch standing up here and there, a long way off.
            let reef = moundProfile(in: size, base: 0.765, seed: 83)
                .union(reefDressing(in: size, top: { _ in size.height * 0.75 }, unitScale: 0.8,
                                    count: 9, seed: 89))
            paintTier(reef, canvas: &canvas, size: size, depth: 0.3, top: size.height * 0.66)
        }
        // The horizon's haze, where the far bed and the water meet: a
        // luminous band, not a darkening.
        let haze = TankPaint.mix(waterRGB(at: 0.5), water.light, isDarkTheme ? 0.02 : 0.10)
        let horizon = size.height * 0.84
        canvas.fill(Path(CGRect(x: 0, y: size.height * 0.55, width: size.width, height: size.height * 0.45)),
                    with: .linearGradient(
                        Gradient(stops: [
                            .init(color: TankPaint.color(haze, 0), location: 0),
                            .init(color: TankPaint.color(haze, 0.26), location: 0.62),
                            .init(color: TankPaint.color(haze, 0.38), location: 1),
                        ]),
                        startPoint: CGPoint(x: 0, y: size.height * 0.55),
                        endPoint: CGPoint(x: 0, y: horizon)))
    }

    /// A tier's colour: a shade deeper than the water behind it, deeper
    /// still the nearer the tier — or, in water already near black, a
    /// breath lighter, the way a far reef shows against the dark.
    private func tierBody(depth: Double) -> TankPaint.RGB {
        let behind = waterRGB(at: 0.72)
        if isDarkTheme { return TankPaint.mix(behind, water.light, 0.05 + 0.04 * depth) }
        return TankPaint.mix(behind, waterRGB(at: 1), 0.28 + 0.40 * depth)
    }

    /// A tier's paint: its body with a crown lit from the surface, a
    /// thin rim of light wherever an upper edge meets the water — drawn
    /// as the body offset down over a lit copy, so a tier built from
    /// many shapes shows no seams — and the haze thickening toward its
    /// foot.
    private func paintTier(_ shape: Path, canvas: inout GraphicsContext, size: CGSize,
                           depth: Double, top: Double) {
        let base = size.height * 0.9
        let body = tierBody(depth: depth)
        let crown = TankPaint.mix(body, water.light, 0.05 + 0.06 * depth)
        let rim = TankPaint.mix(body, water.light, 0.08 + 0.16 * depth)
        canvas.fill(shape, with: .color(TankPaint.color(rim)))
        var inner = canvas
        inner.clip(to: shape)
        inner.fill(shape.offsetBy(dx: 0.8, dy: 1.4 + depth), with: .linearGradient(
            Gradient(colors: [TankPaint.color(crown), TankPaint.color(body)]),
            startPoint: CGPoint(x: 0, y: top), endPoint: CGPoint(x: 0, y: base)))
        let fog = TankPaint.mix(waterRGB(at: 0.55), water.light, isDarkTheme ? 0 : 0.06)
        inner.fill(Path(CGRect(x: 0, y: top - 20, width: size.width, height: base - top + 20)),
                   with: .linearGradient(
                       Gradient(stops: [
                           .init(color: TankPaint.color(fog, 0.08 * (1 - depth)), location: 0),
                           .init(color: TankPaint.color(fog, 0.28 + 0.24 * (1 - depth)), location: 1),
                       ]),
                       startPoint: CGPoint(x: 0, y: top), endPoint: CGPoint(x: 0, y: base)))
    }

    /// The far ridge: long low swells across the whole tank.
    private func ridge(in size: CGSize, base: Double, swell: Double, seed: UInt64) -> Path {
        var rng = TankPaint.Seeded(seed)
        let p1 = rng.next(0, .pi * 2), p2 = rng.next(0, .pi * 2)
        return closedProfile(in: size) { u in
            size.height * (base + swell * sin(u * .pi * 1.7 + p1)
                           + swell * 0.45 * sin(u * .pi * 4.3 + p2)
                           + swell * 0.18 * sin(u * .pi * 11 + p1 * 2))
        }
    }

    /// A reef's crown line: coral heads bulging along a wall that rises
    /// toward both ends (`edgesOnly` keeps just the ends, a nearer
    /// outcrop at each side).
    private func reefTop(atX x: Double, in size: CGSize, rise: Double, floor: Double,
                         seed: UInt64, edgesOnly: Bool = false) -> Double {
        let u = x / max(1, size.width)
        let edge = abs(u - 0.5) * 2
        let lift = edgesOnly ? max(0, (edge - 0.55) / 0.45) : edge * edge
        var rng = TankPaint.Seeded(seed)
        var bumps = 0.0
        for k in 0..<5 {
            let f = rng.next(3, 9) * Double(k + 1)
            bumps += sin(u * .pi * f + rng.next(0, .pi * 2)) / Double(k + 2)
        }
        let heads = abs(sin(u * .pi * rng.next(14, 22) + rng.next(0, 6))) * 0.012
        let top = floor - rise * lift - 0.018 * bumps - heads
        return size.height * (edgesOnly && lift <= 0 ? 1.1 : top)
    }

    /// A reef tier: the wall with its crown dressed, one silhouette.
    private func reefTier(in size: CGSize, rise: Double, floor: Double, seed: UInt64,
                          count: Int, edgesOnly: Bool = false) -> Path {
        let wall = closedProfile(in: size) {
            reefTop(atX: $0 * size.width, in: size, rise: rise, floor: floor, seed: seed, edgesOnly: edgesOnly)
        }
        let dressing = reefDressing(in: size, top: {
            reefTop(atX: $0, in: size, rise: rise, floor: floor, seed: seed, edgesOnly: edgesOnly)
        }, unitScale: edgesOnly ? 1.3 : 1, count: count, seed: seed &+ 7)
        return wall.union(dressing)
    }

    /// The reef's dressing along a crown line: branching coral, sea
    /// fans, table coral and tube sponges — shapes at a distance, not
    /// colours, painted with the tier they stand on.
    private func reefDressing(in size: CGSize, top: (Double) -> Double, unitScale: Double,
                              count: Int, seed: UInt64) -> Path {
        let unit = size.height * 0.018 * unitScale
        var shapes = Path()
        var strokes = Path()
        for i in 0..<count {
            var rng = TankPaint.Seeded(seed &+ UInt64(i) &* 0x9E37_79B9)
            let x = size.width * rng.next(0, 1)
            let y = top(x) + unit * 0.4
            guard y < size.height * 0.86 else { continue }
            switch Int(rng.next(0, 4)) {
            case 0:
                // A branching coral: forks from a short trunk.
                func branch(_ from: CGPoint, _ angle: Double, _ len: Double, _ depth: Int) {
                    let to = CGPoint(x: from.x + cos(angle) * len, y: from.y + sin(angle) * len)
                    strokes.move(to: from)
                    strokes.addQuadCurve(to: to, control: CGPoint(x: (from.x + to.x) / 2 + len * 0.12,
                                                                  y: (from.y + to.y) / 2))
                    guard depth > 0 else { return }
                    branch(to, angle - rng.next(0.3, 0.6), len * 0.72, depth - 1)
                    branch(to, angle + rng.next(0.3, 0.6), len * 0.72, depth - 1)
                }
                branch(CGPoint(x: x, y: y), -.pi / 2 + rng.next(-0.2, 0.2), unit * rng.next(1.2, 1.8), 3)
            case 1:
                // A sea fan: a flat lace on a stalk.
                let r = unit * rng.next(2.0, 3.2)
                var fan = Path()
                fan.move(to: CGPoint(x: x, y: y))
                fan.addCurve(to: CGPoint(x: x + r * 0.9, y: y - r * 1.6),
                             control1: CGPoint(x: x + r * 0.6, y: y - r * 0.2),
                             control2: CGPoint(x: x + r * 1.2, y: y - r * 1.1))
                fan.addQuadCurve(to: CGPoint(x: x - r * 0.9, y: y - r * 1.5),
                                 control: CGPoint(x: x, y: y - r * 2.2))
                fan.addCurve(to: CGPoint(x: x, y: y),
                             control1: CGPoint(x: x - r * 1.2, y: y - r * 1.0),
                             control2: CGPoint(x: x - r * 0.5, y: y - r * 0.2))
                fan.closeSubpath()
                shapes = shapes.union(fan)
            case 2:
                // Table coral: a flat plate on a short foot.
                let r = unit * rng.next(1.8, 2.8)
                let foot = Path(roundedRect: CGRect(x: x - unit * 0.25, y: y - r * 0.6,
                                                    width: unit * 0.5, height: r * 0.6),
                                cornerRadius: unit * 0.2)
                let plate = Path(ellipseIn: CGRect(x: x - r, y: y - r * 0.8, width: r * 2, height: r * 0.36))
                shapes = shapes.union(foot.union(plate))
            default:
                // Tube sponges: two or three stalks.
                let tubes = 2 + Int(rng.next(0, 1.99))
                for k in 0..<tubes {
                    let tx = x + (Double(k) - Double(tubes - 1) / 2) * unit * 0.8
                    let th = unit * rng.next(1.4, 2.6)
                    shapes = shapes.union(Path(roundedRect: CGRect(x: tx - unit * 0.3, y: y - th,
                                                                   width: unit * 0.6, height: th),
                                               cornerRadius: unit * 0.28))
                }
            }
        }
        let branches = strokes.strokedPath(StrokeStyle(lineWidth: max(1, unit * 0.34),
                                                       lineCap: .round, lineJoin: .round))
        return shapes.union(branches)
    }

    /// A rock tier's crown: seeded spires of different heights, rising
    /// toward the ends of the tank.
    private func spireTips(in size: CGSize, rise: Double, floor: Double, seed: UInt64,
                           spires: Int, edgesOnly: Bool = false) -> [CGPoint] {
        var rng = TankPaint.Seeded(seed)
        var tips: [CGPoint] = []
        for k in 0..<spires {
            let u = edgesOnly
                ? (k.isMultiple(of: 2) ? rng.next(-0.04, 0.16) : rng.next(0.84, 1.04))
                : (Double(k) + rng.next(0.1, 0.9)) / Double(spires)
            let edge = abs(u - 0.5) * 2
            let height = rise * (edgesOnly ? 1 : 0.35 + 0.65 * edge * edge) * rng.next(0.55, 1.1)
            tips.append(CGPoint(x: u * size.width, y: size.height * (floor - height)))
        }
        return tips.sorted { $0.x < $1.x }
    }

    /// The spires as one silhouette, with low rubble between them.
    private func rockTier(_ tips: [CGPoint], in size: CGSize, floor: Double, seed: UInt64,
                          rubble: Bool) -> Path {
        var tier = Path()
        for tip in tips {
            tier = tier.union(spire(tip, floor: size.height * floor, seed: seed))
        }
        if rubble {
            tier = tier.union(closedProfile(in: size) { u in
                size.height * (floor - 0.035 + 0.012 * sin(u * .pi * 9 + Double(seed)))
            })
        }
        return tier
    }

    /// One spire: a leaning, stepped pinnacle from its tip to the floor.
    private func spire(_ tip: CGPoint, floor: Double, seed: UInt64) -> Path {
        var rng = TankPaint.Seeded(seed ^ UInt64(max(0, tip.x * 10)))
        let height = max(8, floor - tip.y)
        let half = height * rng.next(0.28, 0.42)
        var p = Path()
        p.move(to: CGPoint(x: tip.x - half * 1.3, y: floor + 4))
        p.addLine(to: CGPoint(x: tip.x - half * rng.next(0.7, 0.9), y: tip.y + height * rng.next(0.45, 0.6)))
        p.addLine(to: CGPoint(x: tip.x - half * rng.next(0.35, 0.5), y: tip.y + height * rng.next(0.18, 0.3)))
        p.addLine(to: CGPoint(x: tip.x - half * 0.12, y: tip.y))
        p.addLine(to: CGPoint(x: tip.x + half * 0.2, y: tip.y + height * 0.04))
        p.addLine(to: CGPoint(x: tip.x + half * rng.next(0.45, 0.6), y: tip.y + height * rng.next(0.25, 0.4)))
        p.addLine(to: CGPoint(x: tip.x + half * rng.next(0.8, 1.0), y: tip.y + height * rng.next(0.55, 0.7)))
        p.addLine(to: CGPoint(x: tip.x + half * 1.3, y: floor + 4))
        p.closeSubpath()
        return p
    }

    /// The lit faces: each spire's left flank catches the surface
    /// light, so the stand reads as rock with facets, not a cut-out.
    private func paintFacets(_ tips: [CGPoint], clip: Path, canvas: inout GraphicsContext,
                             size: CGSize, depth: Double, floor: Double) {
        var faces = Path()
        for tip in tips {
            let height = max(8, size.height * floor - tip.y)
            var face = Path()
            face.move(to: CGPoint(x: tip.x - height * 0.05, y: tip.y + 1))
            face.addLine(to: CGPoint(x: tip.x - height * 0.30, y: tip.y + height * 0.55))
            face.addLine(to: CGPoint(x: tip.x - height * 0.10, y: tip.y + height * 0.95))
            face.addLine(to: CGPoint(x: tip.x + height * 0.02, y: tip.y + height * 0.35))
            face.closeSubpath()
            faces.addPath(face)
        }
        var lit = canvas
        lit.clip(to: clip)
        let top = tips.map(\.y).min() ?? size.height * 0.5
        lit.fill(faces, with: .linearGradient(
            Gradient(colors: [TankPaint.color(water.light, 0.08 + 0.06 * depth),
                              TankPaint.color(water.light, 0)]),
            startPoint: CGPoint(x: 0, y: top),
            endPoint: CGPoint(x: 0, y: size.height * floor)))
    }

    /// The far reef's low heads: overlapping domes along one line,
    /// joined into one outline.
    private func moundProfile(in size: CGSize, base: Double, seed: UInt64) -> Path {
        var rng = TankPaint.Seeded(seed)
        var domes: [(x: Double, r: Double, lift: Double)] = []
        var x = -20.0
        while x < size.width + 20 {
            let big = rng.next(0, 1) < 0.3
            let r = size.height * (big ? rng.next(0.05, 0.09) : rng.next(0.015, 0.04))
            domes.append((x, r, big ? rng.next(0.35, 0.6) : rng.next(0.6, 1.0)))
            x += r * rng.next(1.4, 3.4)
        }
        return closedProfile(in: size) { u in
            let px = u * size.width
            var top = size.height * (base + 0.008 * sin(u * .pi * 5))
            for dome in domes where abs(px - dome.x) < dome.r {
                let dx = (px - dome.x) / dome.r
                top = min(top, size.height * base - dome.r * dome.lift * (1 - dx * dx).squareRoot())
            }
            return top
        }
    }

    /// A closed silhouette from a crown line (`top(u)`, u 0…1 across)
    /// down past the floor.
    private func closedProfile(in size: CGSize, top: (Double) -> Double) -> Path {
        var p = Path()
        let step = max(3, size.width / 240)
        p.move(to: CGPoint(x: -4, y: size.height + 4))
        var x = -4.0
        while x <= size.width + 4 {
            p.addLine(to: CGPoint(x: x, y: top(x / max(1, size.width))))
            x += step
        }
        p.addLine(to: CGPoint(x: size.width + 4, y: top(1)))
        p.addLine(to: CGPoint(x: size.width + 4, y: size.height + 4))
        p.closeSubpath()
        return p
    }
}
