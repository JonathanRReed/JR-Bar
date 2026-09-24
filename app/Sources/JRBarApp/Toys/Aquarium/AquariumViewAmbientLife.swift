import AppKit
import JRBarCore
import SwiftUI

/// The ambient life that drifts through the water.
extension AquariumView {
    // MARK: Ambient life

    /// A jellyfish pulses through the mid-water every ~40 s — or, when
    /// the tank is empty (`resident`), stays on as the standing guest
    /// on a slow figure-eight, so a quiet tank still has one living
    /// thing in it. A translucent bell over four trailing tentacles.
    /// Reduce Motion parks it mid-tank, unpulsed.
    func drawJellyfish(canvas: inout GraphicsContext, size: CGSize, t: Double,
                               resident: Bool) {
        let x: Double
        let y: Double
        let pulse: Double
        let alpha: Double
        if resident {
            if reduceMotion {
                x = size.width * 0.5
                y = size.height * 0.30
                pulse = 0
            } else {
                x = size.width * (0.5 + 0.17 * sin(t * 0.11))
                y = size.height * (0.30 + 0.05 * sin(t * 0.23 + 1.3))
                pulse = sin(t * 1.9) * 0.10
            }
            alpha = 0.62
        } else {
            let progress: Double
            if reduceMotion {
                progress = 0.45
                pulse = 0
                alpha = 0.35
            } else {
                let life = frac(t / 40 + 0.31) * 40
                guard life < 15 else { return }
                progress = life / 15
                pulse = sin(t * 1.9) * 0.10
                alpha = 0.45 * smooth(clamp01(min(progress / 0.18, (1 - progress) / 0.12)))
            }
            x = size.width * (1.08 - 1.24 * progress)
            y = size.height * (0.30 + 0.10 * sin(progress * .pi * 2 + 1))
        }
        var j = canvas
        j.opacity = alpha
        j.translateBy(x: x, y: y)
        j.scaleBy(x: 34 * (1 + pulse), y: 30 * (1 - pulse))
        var bell = Path()
        bell.move(to: CGPoint(x: -0.5, y: 0.12))
        bell.addCurve(to: CGPoint(x: 0.5, y: 0.12),
                      control1: CGPoint(x: -0.52, y: -0.52),
                      control2: CGPoint(x: 0.52, y: -0.52))
        bell.addQuadCurve(to: CGPoint(x: -0.5, y: 0.12), control: CGPoint(x: 0, y: 0.30))
        bell.closeSubpath()
        j.fill(bell, with: .linearGradient(
            Gradient(stops: [
                .init(color: Color(red: 0.97, green: 0.84, blue: 0.93).opacity(0.95), location: 0),
                .init(color: Color(red: 0.90, green: 0.72, blue: 0.85).opacity(0.45), location: 0.7),
                .init(color: Color(red: 0.85, green: 0.65, blue: 0.80).opacity(0.15), location: 1),
            ]),
            startPoint: CGPoint(x: 0, y: -0.5), endPoint: CGPoint(x: 0, y: 0.3)))
        // A rim of light along the bell's lower lip.
        var lip = Path()
        lip.move(to: CGPoint(x: -0.5, y: 0.12))
        lip.addQuadCurve(to: CGPoint(x: 0.5, y: 0.12), control: CGPoint(x: 0, y: 0.30))
        j.stroke(lip, with: .color(Color(red: 0.98, green: 0.88, blue: 0.95).opacity(0.5)),
                 lineWidth: 0.04)
        for k in 0..<4 {
            let tx = -0.30 + Double(k) * 0.20
            var tent = Path()
            tent.move(to: CGPoint(x: tx, y: 0.12))
            tent.addCurve(to: CGPoint(x: tx + sin(t * 1.3 + Double(k) * 1.7) * 0.08, y: 0.85),
                          control1: CGPoint(x: tx - 0.06, y: 0.35),
                          control2: CGPoint(x: tx + 0.06, y: 0.60))
            j.stroke(tent, with: .color(Color(red: 0.9, green: 0.75, blue: 0.85).opacity(0.6)),
                     lineWidth: 0.05)
        }
        j.fill(Path(ellipseIn: CGRect(x: -0.16, y: -0.30, width: 0.32, height: 0.30)),
               with: .color(.white.opacity(0.5)))
    }

    /// Tap-dropped food: small brown pellets sinking toward the sand
    /// with a slow sway. The claim ring under a claimed pellet shows
    /// which fish is coming for it — informational only; the eat
    /// event fires in `stepSwim` when the fish actually arrives.
    func drawFeed(canvas: inout GraphicsContext, size: CGSize, now: Date) {
        let m = motion
        for pellet in m.pellets {
            let age = now.timeIntervalSince(pellet.bornAt)
            let appear = smooth(clamp01(age / 0.25))
            // Fading out over the last few seconds of its life keeps
            // uneaten food from popping.
            let fade = 1 - smooth(clamp01((age - 20) / 4))
            let a = appear * fade
            guard a > 0.01 else { continue }
            let sway = reduceMotion ? 0 : sin(age * 3.1 + Double(pellet.id)) * 4
            let x = pellet.x * size.width + sway
            let y = pellet.y * size.height
            let r = 2.6
            canvas.fill(
                Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                with: .color(Color(red: 0.55, green: 0.38, blue: 0.20).opacity(a)))
            canvas.fill(
                Path(ellipseIn: CGRect(x: x - r * 0.4, y: y - r * 0.55,
                                       width: r * 0.8, height: r * 0.5)),
                with: .color(Color(red: 0.85, green: 0.68, blue: 0.42).opacity(a * 0.5)))
            if m.claims[pellet.id] != nil {
                canvas.stroke(
                    Path(ellipseIn: CGRect(x: x - r - 3, y: y - r - 3,
                                           width: (r + 3) * 2, height: (r + 3) * 2)),
                    with: .color(.white.opacity(a * 0.25)), lineWidth: 0.7)
            }
        }
    }

    /// Purchased decor (docs/TOYS.md shop): each owned decor item
    /// stands on the sand at its own seeded spot — the plant is a
    /// bright leafy tuft, the rock a big smooth lump, the chest a
    /// smaller second treasure box, the castle a tiny spired keep.
    /// Nothing here touches session state; it's pure dressing.
    func drawShopDecor(canvas: inout GraphicsContext, size: CGSize, t: Double) {
        guard let game else { return }
        if game.owns(.plant) {
            let x = size.width * 0.115
            let baseY = sandTop(atX: x, in: size)
            var p = canvas
            p.translateBy(x: x, y: baseY)
            // Three broad leaves fanning up, swaying gently.
            for k in 0..<4 {
                let h = AquariumModel.stableHash("shop-plant-\(k)")
                let lean = (Double(h & 0xFF) / 0xFF - 0.5) * 0.9
                let reach = 30 + Double((h >> 8) & 0xFF) / 0xFF * 26
                let sway = reduceMotion ? 0 : sin(t * 0.9 + Double(k) * 1.4) * 3.5
                var leaf = Path()
                leaf.move(to: .zero)
                leaf.addQuadCurve(
                    to: CGPoint(x: lean * reach + sway, y: -reach),
                    control: CGPoint(x: lean * reach * 0.35 + sway * 0.3, y: -reach * 0.5))
                let tip = CGPoint(x: lean * reach + sway, y: -reach)
                leaf.addQuadCurve(
                    to: .zero,
                    control: CGPoint(x: tip.x * 0.55 + 5.5, y: -reach * 0.45))
                leaf.closeSubpath()
                let shade = 0.45 + Double(k) * 0.12
                p.fill(leaf, with: .color(
                    Color(red: 0.10, green: shade, blue: 0.30).opacity(0.85)))
            }
            // A small crown of pebbles at the root.
            p.fill(Path(ellipseIn: CGRect(x: -9, y: -4, width: 18, height: 6)),
                   with: .color(Color(red: 0.45, green: 0.42, blue: 0.38).opacity(0.8)))
        }
        if game.owns(.rock) {
            let x = size.width * 0.315
            let baseY = sandTop(atX: x, in: size)
            var rock = Path()
            rock.move(to: CGPoint(x: x - 26, y: baseY))
            rock.addCurve(to: CGPoint(x: x - 8, y: baseY - 30),
                          control1: CGPoint(x: x - 24, y: baseY - 22),
                          control2: CGPoint(x: x - 18, y: baseY - 30))
            rock.addCurve(to: CGPoint(x: x + 14, y: baseY - 24),
                          control1: CGPoint(x: x + 2, y: baseY - 32),
                          control2: CGPoint(x: x + 10, y: baseY - 28))
            rock.addCurve(to: CGPoint(x: x + 26, y: baseY),
                          control1: CGPoint(x: x + 22, y: baseY - 16),
                          control2: CGPoint(x: x + 26, y: baseY - 6))
            rock.closeSubpath()
            canvas.fill(rock, with: .linearGradient(
                Gradient(stops: [
                    .init(color: Color(red: 0.48, green: 0.50, blue: 0.52), location: 0),
                    .init(color: Color(red: 0.28, green: 0.30, blue: 0.33), location: 1),
                ]),
                startPoint: CGPoint(x: x, y: baseY - 32),
                endPoint: CGPoint(x: x, y: baseY)))
            canvas.stroke(rock, with: .color(.black.opacity(0.25)), lineWidth: 1)
        }
        if game.owns(.treasureChest) {
            // A second, smaller chest — the seeded one keeps the
            // milestone plume; this one is the player's trophy.
            let x = size.width * 0.68
            let baseY = sandTop(atX: x, in: size)
            var c = canvas
            c.translateBy(x: x, y: baseY)
            c.scaleBy(x: 0.72, y: 0.72)
            let body = Path(roundedRect: CGRect(x: -20, y: -16, width: 40, height: 16),
                            cornerRadius: 2)
            c.fill(body, with: .color(Color(red: 0.42, green: 0.27, blue: 0.13)))
            var lid = Path()
            lid.move(to: CGPoint(x: -20, y: -16))
            lid.addQuadCurve(to: CGPoint(x: 20, y: -16), control: CGPoint(x: 0, y: -34))
            lid.addLine(to: CGPoint(x: 20, y: -13))
            lid.addLine(to: CGPoint(x: -20, y: -13))
            lid.closeSubpath()
            c.fill(lid, with: .color(Color(red: 0.50, green: 0.33, blue: 0.16)))
            c.fill(Path(CGRect(x: -3, y: -18, width: 6, height: 8)),
                   with: .color(Color(red: 0.85, green: 0.70, blue: 0.30)))
            c.stroke(body, with: .color(.black.opacity(0.3)), lineWidth: 1)
            c.stroke(lid, with: .color(.black.opacity(0.3)), lineWidth: 1)
        }
        if game.owns(.castle) {
            let x = size.width * 0.885
            let baseY = sandTop(atX: x, in: size)
            var c = canvas
            c.translateBy(x: x, y: baseY)
            // Sized off the tank like the rest of the owned set —
            // ~110 px tall at 700, the keep a landmark, not a trinket.
            c.scaleBy(x: size.height / 242, y: size.height / 242)
            let stone = Color(red: 0.62, green: 0.60, blue: 0.66)
            let dark = Color(red: 0.40, green: 0.38, blue: 0.44)
            // Keep: a round tower with crenellations and a door.
            var keep = Path()
            keep.move(to: CGPoint(x: -14, y: 0))
            keep.addLine(to: CGPoint(x: -14, y: -34))
            keep.addLine(to: CGPoint(x: -10, y: -34))
            keep.addLine(to: CGPoint(x: -10, y: -38))
            keep.addLine(to: CGPoint(x: -5, y: -38))
            keep.addLine(to: CGPoint(x: -5, y: -34))
            keep.addLine(to: CGPoint(x: 0, y: -34))
            keep.addLine(to: CGPoint(x: 0, y: -38))
            keep.addLine(to: CGPoint(x: 5, y: -38))
            keep.addLine(to: CGPoint(x: 5, y: -34))
            keep.addLine(to: CGPoint(x: 10, y: -34))
            keep.addLine(to: CGPoint(x: 10, y: -38))
            keep.addLine(to: CGPoint(x: 14, y: -38))
            keep.addLine(to: CGPoint(x: 14, y: -34))
            keep.addLine(to: CGPoint(x: 14, y: 0))
            keep.closeSubpath()
            c.fill(keep, with: .color(stone))
            c.stroke(keep, with: .color(dark), lineWidth: 1)
            // Door & window.
            var door = Path()
            door.move(to: CGPoint(x: -4, y: 0))
            door.addLine(to: CGPoint(x: -4, y: -10))
            door.addQuadCurve(to: CGPoint(x: 4, y: -10), control: CGPoint(x: 0, y: -14))
            door.addLine(to: CGPoint(x: 4, y: 0))
            door.closeSubpath()
            c.fill(door, with: .color(dark))
            c.fill(Path(ellipseIn: CGRect(x: -2, y: -26, width: 4, height: 5)),
                   with: .color(dark))
            // Side turret with a little flag.
            c.fill(Path(CGRect(x: -26, y: -20, width: 10, height: 20)),
                   with: .color(stone))
            c.stroke(Path(CGRect(x: -26, y: -20, width: 10, height: 20)),
                     with: .color(dark), lineWidth: 1)
            var pole = Path()
            pole.move(to: CGPoint(x: -21, y: -20))
            pole.addLine(to: CGPoint(x: -21, y: -30))
            c.stroke(pole, with: .color(dark), lineWidth: 1)
            var flag = Path()
            flag.move(to: CGPoint(x: -21, y: -30))
            flag.addLine(to: CGPoint(x: -14, y: -27.5))
            flag.addLine(to: CGPoint(x: -21, y: -25))
            flag.closeSubpath()
            c.fill(flag, with: .color(Color(red: 0.80, green: 0.25, blue: 0.30)))
        }
    }
}
