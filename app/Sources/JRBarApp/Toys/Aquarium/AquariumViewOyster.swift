import AppKit
import JRBarCore
import SwiftUI

/// The oyster (shop › Pets): a ridged clam on the sand at the front of
/// the bed. It grows a pearl on half an hour of the tank's work; until
/// then it rests shut, lifting its lid a hair now and then. Ready, it
/// opens wide with the pearl glinting inside — a coin in the Arcade tank
/// — and waits for a tap. Its tap box goes into `motion.oysterBox`,
/// first in the tap chain.
extension AquariumView {
    /// Where the oyster sits, 0…1 across the bed — between the anemone
    /// bed and the moon-jelly lamp's slots.
    static let oysterX = 0.485

    func drawOyster(canvas: inout GraphicsContext, size: CGSize, t: Double) {
        guard let game, game.shows(.oyster), size.width > 0 else {
            motion.oysterBox = nil
            return
        }
        let tone = decorTone()
        let ready = game.oysterReady
        let x = size.width * Self.oysterX
        let y = sandTop(atX: x, in: size) - 1
        let w = 36.0, h = 13.0
        let breath = reduceMotion ? 0 : max(0, sin(t * .pi * 2 / 6.5)) * 0.08
        let open = ready ? 0.62 + (reduceMotion ? 0 : 0.04 * sin(t * 1.6)) : breath
        contactShadow(canvas: &canvas, x: x, y: y + 1, halfW: w * 0.55, alpha: 0.32)
        let shellLit = tone(Color(red: 0.93, green: 0.86, blue: 0.80))
        let shellBase = tone(Color(red: 0.66, green: 0.58, blue: 0.62))
        let shellShade = tone(Color(red: 0.34, green: 0.28, blue: 0.34))
        let edge = tone(Color(red: 0.20, green: 0.14, blue: 0.20))
        // The lower shell: a shallow ridged bowl.
        var bowl = Path()
        bowl.move(to: CGPoint(x: x - w / 2, y: y - h * 0.45))
        bowl.addQuadCurve(to: CGPoint(x: x + w / 2, y: y - h * 0.45),
                          control: CGPoint(x: x, y: y + h * 0.55))
        bowl.addQuadCurve(to: CGPoint(x: x - w / 2, y: y - h * 0.45),
                          control: CGPoint(x: x, y: y - h * 0.62))
        bowl.closeSubpath()
        TankPaint.solid(&canvas, bowl, lit: shellLit, base: shellBase, shade: shellShade,
                        outline: edge.opacity(0.7), lineWidth: 1, rim: 0.3)
        // The mantle and the pearl, showing when the lid lifts.
        if open > 0.2 {
            let inside = Path(ellipseIn: CGRect(x: x - w * 0.40, y: y - h * 0.62, width: w * 0.80, height: h * 0.40))
            canvas.fill(inside, with: .color(tone(Color(red: 0.96, green: 0.70, blue: 0.74))))
            if ready {
                let p = CGPoint(x: x + 2, y: y - h * 0.62)
                if themeKey == "arcade" {
                    drawCoin(canvas: &canvas, at: p, spin: reduceMotion ? 1 : abs(cos(t * 0.9)),
                             gem: false, resting: false, radius: 5.5)
                } else {
                    let r = 5.0
                    var halo = canvas
                    halo.blendMode = .plusLighter
                    let pulse = reduceMotion ? 0.5 : 0.5 + 0.5 * sin(t * 2.2)
                    halo.fill(Path(ellipseIn: CGRect(x: p.x - r * 2.6, y: p.y - r * 2.6, width: r * 5.2, height: r * 5.2)),
                              with: .radialGradient(Gradient(colors: [Color(red: 1, green: 0.94, blue: 0.80).opacity(0.25 + 0.2 * pulse), .clear]),
                                                    center: p, startRadius: 0, endRadius: r * 2.6))
                    canvas.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                                with: .radialGradient(Gradient(colors: [.white, Color(red: 0.93, green: 0.88, blue: 0.86)]),
                                                      center: CGPoint(x: p.x - r * 0.3, y: p.y - r * 0.35),
                                                      startRadius: 0, endRadius: r * 1.2))
                    drawSparkle(canvas: &canvas, at: CGPoint(x: p.x - r * 0.4, y: p.y - r * 0.5),
                                size: 4 + 3 * pulse, alpha: 0.6 + 0.4 * pulse, color: .white)
                }
            }
        }
        // The lid, hinged at the back left, lifting by `open`.
        var lid = canvas
        lid.translateBy(x: x - w / 2, y: y - h * 0.45)
        lid.rotate(by: .radians(-open))
        var top = Path()
        top.move(to: .zero)
        top.addQuadCurve(to: CGPoint(x: w, y: 0), control: CGPoint(x: w * 0.5, y: -h * 1.15))
        top.addQuadCurve(to: .zero, control: CGPoint(x: w * 0.5, y: h * 0.18))
        top.closeSubpath()
        TankPaint.solid(&lid, top, lit: shellLit, base: shellBase, shade: shellShade,
                        outline: edge.opacity(0.7), lineWidth: 1, rim: 0.4)
        // Its ridges fan out from the hinge.
        var ridges = Path()
        for k in 1..<6 {
            let f = Double(k) / 6
            ridges.move(to: CGPoint(x: w * 0.04, y: -h * 0.05))
            ridges.addQuadCurve(to: CGPoint(x: w * f, y: -h * 0.52 * sin(.pi * f) - 1),
                                control: CGPoint(x: w * f * 0.55, y: -h * 0.40 * sin(.pi * f)))
        }
        var grooves = lid
        grooves.clip(to: top)
        grooves.stroke(ridges, with: .color(edge.opacity(0.35)), lineWidth: 0.9)
        motion.oysterBox = CGRect(x: x - w * 0.7, y: y - h * 2.8, width: w * 1.4, height: h * 3.2)
    }
}
