import AppKit
import JRBarCore
import SwiftUI

/// The reef's kelp bed, in the tank (docs/TOYS.md): a small stand of
/// kelp on the front sand that is as tall and as full as the kelp bed's
/// level, with pearl pods along its blades. The pods are dim buds while
/// the reef holds nothing and swell and glow as a harvest builds. A tap
/// on the bed brings the harvest in, the same as the chip in the HUD. Its
/// tap box goes into `motion.reefBox`.
extension AquariumView {
    /// Where the bed stands, 0…1 across the sand: between the leafy plant's
    /// slot and the rock's.
    static let reefBedX = 0.215

    /// How tall the bed's tallest blade stands for a kelp level, in points:
    /// it shoots up over the first levels and settles toward its full height.
    static func reefBedHeight(level: Int) -> Double {
        min(132, 40 + 30 * Double(max(1, level)).squareRoot())
    }

    /// How many blades the bed has: three to start, one more every four
    /// levels, nine at most.
    static func reefBedBlades(level: Int) -> Int {
        min(9, 3 + max(0, level - 1) / 4)
    }

    /// How many pods glow for a waiting harvest: one for anything at all,
    /// one more for each doubling past twenty pearls, six at most.
    static func reefPods(waiting: Int) -> Int {
        guard waiting > 0 else { return 0 }
        guard waiting >= 20 else { return 1 }
        return min(6, 2 + Int(log2(Double(waiting) / 20)))
    }

    func drawReefBed(canvas: inout GraphicsContext, size: CGSize, t: Double) {
        guard let game, size.width > 0 else {
            motion.reefBox = nil
            return
        }
        let level = game.reef.level(.kelp)
        let waiting = game.reef.waiting
        let tone = decorTone()
        let x = size.width * Self.reefBedX
        let y = sandTop(atX: x, in: size) + 1
        let tall = Self.reefBedHeight(level: level) * min(1, size.height / 480)
        let blades = Self.reefBedBlades(level: level)
        let lit = Self.reefPods(waiting: waiting)
        let still = reduceMotion || isStill
        contactShadow(canvas: &canvas, x: x, y: y, halfW: 10 + Double(blades) * 2.6, alpha: 0.26)

        var fronds = Path()
        var veins = Path()
        var pods: [(at: CGPoint, r: Double, lit: Bool)] = []
        for k in 0..<blades {
            let seed = scatter(0x51ED_270B_9E37_79B9, k &+ 7)
            let u = blades == 1 ? 0.5 : Double(k) / Double(blades - 1)
            // The middle blades stand tallest; the bed fans out a little.
            let height = tall * (0.62 + 0.38 * sin(u * .pi)) * (0.9 + Double(seed & 0xFF) / 0xFF * 0.2)
            let fan = (u - 0.5) * 0.62
            let phase = Double((seed >> 8) & 0xFF) / 0xFF * .pi * 2
            let sway = still ? 0 : sin(t * (0.5 + Double((seed >> 16) & 0xFF) / 0xFF * 0.3) + phase) * 0.07
            let angle = -.pi / 2 + fan + sway
            let base = CGPoint(x: x + (u - 0.5) * Double(blades) * 5.2, y: y)
            let width = max(4.5, height * 0.085)
            fronds.addPath(leaf(from: base, angle: angle, length: height, width: width,
                                curl: height * 0.10 * (u < 0.5 ? -1 : 1)))
            let tip = CGPoint(x: base.x + cos(angle) * height * 0.86, y: base.y + sin(angle) * height * 0.86)
            veins.move(to: base)
            veins.addQuadCurve(to: tip, control: CGPoint(x: base.x + cos(angle) * height * 0.45 + sin(angle) * width * 0.3,
                                                         y: base.y + sin(angle) * height * 0.45))
            // One pod a blade, part-way up, on alternating sides.
            let along = 0.46 + Double((seed >> 24) & 0xFF) / 0xFF * 0.30
            let side = k.isMultiple(of: 2) ? 1.0 : -1.0
            let at = CGPoint(x: base.x + cos(angle) * height * along - sin(angle) * width * 0.55 * side,
                             y: base.y + sin(angle) * height * along + cos(angle) * width * 0.55 * side)
            pods.append((at, 2.6 + height * 0.022, false))
        }
        // The harvest lights the pods from the middle of the bed outward.
        let order = pods.indices.sorted { abs($0 - blades / 2) < abs($1 - blades / 2) }
        for index in order.prefix(lit) { pods[index].lit = true }

        let top = CGPoint(x: x, y: y - tall), foot = CGPoint(x: x, y: y)
        canvas.fill(fronds, with: .linearGradient(
            Gradient(stops: [
                .init(color: tone(TankPaint.color(.init(0.16, 0.34, 0.14))), location: 0),
                .init(color: tone(TankPaint.color(.init(0.42, 0.56, 0.18))), location: 0.5),
                .init(color: tone(TankPaint.color(.init(0.72, 0.83, 0.35))), location: 1),
            ]),
            startPoint: foot, endPoint: top))
        var lightEdge = canvas
        lightEdge.clip(to: fronds)
        lightEdge.fill(CartoonFish.crescent(of: fronds, in: fronds.boundingRect, dy: 1.6),
                       with: .color(tone(TankPaint.color(.init(0.91, 1.0, 0.98), 0.42))), style: FillStyle(eoFill: true))
        canvas.stroke(veins, with: .color(tone(TankPaint.color(.init(0.86, 0.92, 0.50), 0.45))), lineWidth: 0.8)

        let pulse = still ? 0.6 : 0.5 + 0.5 * sin(t * 2.1)
        let pearl = TankPaint.color(.init(1.0, 0.95, 0.80))
        for pod in pods {
            let r = pod.lit ? pod.r * (1.25 + 0.12 * pulse) : pod.r * 0.8
            let rect = CGRect(x: pod.at.x - r, y: pod.at.y - r, width: r * 2, height: r * 2)
            if pod.lit {
                var halo = canvas
                halo.blendMode = .plusLighter
                halo.fill(Path(ellipseIn: rect.insetBy(dx: -r * 2.2, dy: -r * 2.2)),
                          with: .radialGradient(Gradient(colors: [pearl.opacity(0.30 + 0.25 * pulse), .clear]),
                                                center: pod.at, startRadius: 0, endRadius: r * 3.2))
                canvas.fill(Path(ellipseIn: rect), with: .radialGradient(
                    Gradient(colors: [.white, tone(TankPaint.color(.init(0.96, 0.86, 0.60)))]),
                    center: CGPoint(x: pod.at.x - r * 0.3, y: pod.at.y - r * 0.35), startRadius: 0, endRadius: r * 1.25))
            } else {
                canvas.fill(Path(ellipseIn: rect), with: .color(tone(TankPaint.color(.init(0.66, 0.62, 0.28), 0.9))))
            }
        }
        if waiting > 0 {
            motion.reefBox = fronds.boundingRect.insetBy(dx: -10, dy: -8)
            motion.reefPods = pods.filter(\.lit).map(\.at)
        } else {
            motion.reefBox = nil
            motion.reefPods = []
        }
    }
}
