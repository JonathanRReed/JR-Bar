import AppKit
import JRBarCore
import SwiftUI

/// The alien (shop › Alien beacon): a failed run calls it, once a day at
/// most. It's a round, one-eyed, cheerful thing that bobs along the upper
/// third of the tank for 25 seconds, peering down at the fish — it never
/// touches one, never takes a pearl, and never touches the failed
/// session. Five taps shoo it: each wobbles it and pops a ring, the
/// fifth sends it zipping off and pays its bounty. Left alone, it just
/// leaves.
extension AquariumView {
    /// How long each visitor's parade lasts.
    static func paradeSeconds(_ visitor: AquariumVisitor) -> Double {
        switch visitor {
        case .whale: return 17
        case .alien: return 25
        case .diver, .submarine: return 14
        }
    }

    /// How long the shooed alien takes to zip out of sight.
    static let alienZipSeconds = 0.8

    /// Where the alien floats at parade point `x` and clock `t`.
    private func alienCenter(size: CGSize, t: Double, x: Double) -> CGPoint {
        let bob = reduceMotion ? 0 : sin(t * 1.6) * 8 + sin(t * 0.7) * 4
        return CGPoint(x: x, y: size.height * 0.26 + bob)
    }

    func drawAlien(canvas: inout GraphicsContext, size: CGSize, t: Double, x: Double,
                   presence: Double) {
        let m = motion
        let now = Date(timeIntervalSince1970: t)
        // A new visit forgets the last one's taps and shoo.
        if let visit = m.activeVisitor, let shooed = m.alienShooedAt, shooed < visit.startedAt {
            m.alienShooedAt = nil
        }
        var center = alienCenter(size: size, t: t, x: x)
        var scale = 1.0
        var alpha = min(1, presence * 1.6)
        if let shooed = m.alienShooedAt, let from = m.alienBox.map({ CGPoint(x: $0.midX, y: $0.midY) }) {
            // Zipping off: up and away, shrinking into the distance.
            let z = min(1, max(0, now.timeIntervalSince(shooed) / Self.alienZipSeconds))
            center = CGPoint(x: from.x + z * z * size.width * 0.55, y: from.y - z * size.height * 0.30)
            scale = 1 - 0.7 * z
            alpha = 1 - z * z
            if z >= 1 { m.alienBox = nil; return }
            drawAlienBody(canvas: &canvas, at: center, t: t, scale: scale, alpha: alpha,
                          wobble: 0, zipping: true)
            return
        }
        let wobble: Double
        if let at = m.alienWobbleAt, now.timeIntervalSince(at) < 0.45, !reduceMotion {
            let q = now.timeIntervalSince(at) / 0.45
            wobble = sin(q * .pi * 5) * 0.28 * (1 - q)
        } else {
            wobble = 0
        }
        drawAlienBody(canvas: &canvas, at: center, t: t, scale: scale, alpha: alpha,
                      wobble: wobble, zipping: false)
        m.alienBox = CGRect(x: center.x - 40, y: center.y - 44, width: 80, height: 84)
    }

    /// A tap on the alien: it wobbles and a ring pops; the fifth tap
    /// shoos it off and pays.
    func tapAlien(at point: CGPoint, visit: Date) {
        let m = motion
        let now = Date()
        let taps = (m.alienTaps?.visit == visit ? m.alienTaps?.count ?? 0 : 0) + 1
        m.alienTaps = (visit, taps)
        m.alienWobbleAt = now
        let size = m.size
        if size.width > 0, size.height > 0 {
            m.puffs.append((x: point.x / size.width, y: point.y / size.height, bornAt: now))
        }
        guard taps >= AquariumRules.alienTaps else { return }
        m.alienShooedAt = now
        m.alienTaps = nil
        // The parade ends as the zip does.
        m.activeVisitor = (.alien, now.addingTimeInterval(Self.alienZipSeconds - Self.paradeSeconds(.alien)))
        toy?.shooAlien()
    }

    /// The alien itself: a round lime body with an ink edge, a glowing
    /// belly, stubby waving arms, two antennae with bobbles, and one big
    /// eye peering down at the fish.
    private func drawAlienBody(canvas: inout GraphicsContext, at c: CGPoint, t: Double, scale: Double,
                               alpha: Double, wobble: Double, zipping: Bool) {
        var a = canvas
        a.opacity = alpha
        a.translateBy(x: c.x, y: c.y)
        a.rotate(by: .radians(wobble))
        a.scaleBy(x: scale, y: scale)
        let still = reduceMotion
        let ink = Color(red: 0.10, green: 0.24, blue: 0.10)
        let lime = Color(red: 0.55, green: 0.90, blue: 0.36)
        let limeDark = Color(red: 0.28, green: 0.62, blue: 0.22)
        // A soft glow under it — it came from somewhere bright.
        var glow = a
        glow.blendMode = .plusLighter
        glow.fill(Path(ellipseIn: CGRect(x: -46, y: -40, width: 92, height: 92)),
                  with: .radialGradient(Gradient(colors: [Color(red: 0.7, green: 1.0, blue: 0.6).opacity(0.22), .clear]),
                                        center: .zero, startRadius: 0, endRadius: 46))
        // Antennae with glowing bobbles.
        for side in [-1.0, 1.0] {
            let sway = still ? 0 : sin(t * 2.2 + side) * 3
            var stalk = Path()
            stalk.move(to: CGPoint(x: side * 8, y: -22))
            stalk.addQuadCurve(to: CGPoint(x: side * 15 + sway, y: -40),
                               control: CGPoint(x: side * 8, y: -34))
            a.stroke(stalk, with: .color(ink), style: StrokeStyle(lineWidth: 3.2, lineCap: .round))
            a.stroke(stalk, with: .color(limeDark), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            let bob = CGRect(x: side * 15 + sway - 4, y: -44, width: 8, height: 8)
            a.fill(Path(ellipseIn: bob), with: .color(Color(red: 1.0, green: 0.55, blue: 0.85)))
            a.stroke(Path(ellipseIn: bob), with: .color(ink), lineWidth: 1.2)
        }
        // Stubby arms, waving.
        for side in [-1.0, 1.0] {
            let wave = still ? 0 : sin(t * 3.4 + (side > 0 ? 0 : 1.7)) * 0.35
            // Each arm reaches outward from its shoulder; the left one
            // is the right one mirrored.
            var arm = a
            arm.translateBy(x: side * 22, y: 4)
            arm.scaleBy(x: side, y: 1)
            arm.rotate(by: .radians(0.5 + wave))
            let limb = Path(roundedRect: CGRect(x: -4, y: -4, width: 16, height: 8), cornerRadius: 4)
            arm.fill(limb, with: .color(lime))
            arm.stroke(limb, with: .color(ink), lineWidth: 1.6)
        }
        // The body.
        let body = Path(ellipseIn: CGRect(x: -26, y: -24, width: 52, height: 50))
        a.fill(body, with: .linearGradient(Gradient(colors: [lime, limeDark]),
                                           startPoint: CGPoint(x: -10, y: -24), endPoint: CGPoint(x: 10, y: 26)))
        // The glowing belly.
        let belly = Path(ellipseIn: CGRect(x: -15, y: 4, width: 30, height: 17))
        a.fill(belly, with: .color(Color(red: 0.86, green: 1.0, blue: 0.70)))
        var bellyGlow = a
        bellyGlow.blendMode = .plusLighter
        let pulse = still ? 0.5 : 0.5 + 0.5 * sin(t * 2.6)
        bellyGlow.fill(belly, with: .radialGradient(
            Gradient(colors: [Color(red: 0.8, green: 1.0, blue: 0.6).opacity(0.25 + 0.25 * pulse), .clear]),
            center: CGPoint(x: 0, y: 12), startRadius: 0, endRadius: 18))
        a.stroke(body, with: .color(ink), lineWidth: 2.4)
        // The hard white highlight blob.
        a.fill(Path(ellipseIn: CGRect(x: -19, y: -19, width: 11, height: 7)), with: .color(.white.opacity(0.85)))
        // One big eye, peering down toward the fish (wide open while
        // zipping off).
        let eye = CGRect(x: -12, y: -17, width: 24, height: 22)
        a.fill(Path(ellipseIn: eye), with: .color(.white))
        a.stroke(Path(ellipseIn: eye), with: .color(ink), lineWidth: 1.8)
        let look = zipping ? CGPoint(x: 0, y: 0)
            : CGPoint(x: still ? -2 : sin(t * 0.8) * 4, y: 3)
        let pupil = CGRect(x: -5.5 + look.x, y: -10 + look.y, width: 11, height: 12)
        a.fill(Path(ellipseIn: pupil), with: .color(Color(red: 0.12, green: 0.08, blue: 0.20)))
        a.fill(Path(ellipseIn: CGRect(x: pupil.minX + 2, y: pupil.minY + 2, width: 3.6, height: 3.6)),
               with: .color(.white))
        // A little smile.
        var smile = Path()
        smile.move(to: CGPoint(x: -6, y: 10))
        smile.addQuadCurve(to: CGPoint(x: 6, y: 10), control: CGPoint(x: 0, y: zipping ? 17 : 15))
        a.stroke(smile, with: .color(ink), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
    }

    /// The alien beacon at the front of the bed, just right of the
    /// castle: a squat rock with a little dish on a mast, its tip light
    /// blinking — on for one of the still pass's two-second ticks, off
    /// for the next — and brighter while an alien is waiting to come.
    func drawBeacon(canvas: inout GraphicsContext, size: CGSize, slot: AquariumModel.DecorSlot,
                    t: Double) {
        let tone = decorTone()
        let x = slot.x * size.width
        let base = ownedBaseY(slot, in: size)
        let s = slot.h * size.height / 60
        contactShadow(canvas: &canvas, x: x, y: base, halfW: 16 * s, alpha: 0.30)
        var c = canvas
        c.translateBy(x: x, y: base)
        c.scaleBy(x: s, y: s)
        let ink = tone(Color(red: 0.12, green: 0.14, blue: 0.20))
        // The rock it's bolted to.
        let rock = stonePath(center: CGPoint(x: 0, y: -6), width: 30, height: 14, seed: 0xBEAC)
        TankPaint.solid(&c, rock, lit: tone(Color(red: 0.62, green: 0.60, blue: 0.64)),
                        base: tone(Color(red: 0.40, green: 0.38, blue: 0.44)),
                        shade: tone(Color(red: 0.18, green: 0.17, blue: 0.22)), outline: ink.opacity(0.6))
        // The mast and the dish.
        var mast = Path()
        mast.move(to: CGPoint(x: 0, y: -10))
        mast.addLine(to: CGPoint(x: 0, y: -46))
        c.stroke(mast, with: .color(ink), style: StrokeStyle(lineWidth: 3.2, lineCap: .round))
        c.stroke(mast, with: .color(tone(Color(red: 0.72, green: 0.76, blue: 0.82))),
                 style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
        var dish = Path()
        dish.move(to: CGPoint(x: -13, y: -38))
        dish.addQuadCurve(to: CGPoint(x: 9, y: -24), control: CGPoint(x: -8, y: -22))
        dish.closeSubpath()
        TankPaint.solid(&c, dish, lit: tone(Color(red: 0.90, green: 0.92, blue: 0.96)),
                        base: tone(Color(red: 0.66, green: 0.70, blue: 0.78)),
                        shade: tone(Color(red: 0.36, green: 0.40, blue: 0.48)), outline: ink.opacity(0.7))
        // The light: a green bulb that blinks, never toned — it's a light.
        let waiting = game?.pendingVisitors.contains(.alien) == true
        let on = reduceMotion || Int((t / 2).rounded(.down)).isMultiple(of: 2) || waiting
        let bulb = CGRect(x: -4, y: -52, width: 8, height: 8)
        c.fill(Path(ellipseIn: bulb), with: .color(on ? Color(red: 0.55, green: 1.0, blue: 0.45)
                                                       : Color(red: 0.20, green: 0.36, blue: 0.20)))
        c.stroke(Path(ellipseIn: bulb), with: .color(ink), lineWidth: 1)
        if on {
            TankPaint.glow(&c, at: CGPoint(x: 0, y: -48), radius: waiting ? 22 : 14,
                           color: Color(red: 0.55, green: 1.0, blue: 0.45).opacity(waiting ? 0.7 : 0.45))
        }
    }
}
