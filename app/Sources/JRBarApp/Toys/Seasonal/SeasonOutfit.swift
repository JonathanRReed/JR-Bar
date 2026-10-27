import JRBarCore
import SwiftUI

/// The buddy's seasonal outfit: one piece per holiday, drawn in the
/// wardrobe's own box and seated like the beanie, bow and flower
/// (`BuddyFigure.seat`), so it fits every body — centred on the head,
/// clear of the cat's ears and the axolotl's frills.
enum SeasonOutfit {
    typealias Context = GraphicsContext

    /// Where a piece sits: on the crown, or clipped at the side like the
    /// bow.
    enum Placement { case crown, side }

    /// The box every piece draws in, in the figure's points at 1×.
    static let box = CGSize(width: 12, height: 10)

    /// A band worn with something standing up from it — ears, boppers,
    /// a sprout, a crescent, a flower crown. On the crab these balance on
    /// its eye stalks; a hat sits on its shell.
    static func isHeadband(_ holiday: SeasonalHoliday) -> Bool {
        switch holiday {
        case .valentines, .easter, .groundhogDay, .ramadanEid, .earthDay, .diaDeMuertos: return true
        default: return false
        }
    }

    static func placement(_ holiday: SeasonalHoliday) -> Placement {
        switch holiday {
        case .lunarNewYear, .pride: return .side
        default: return .crown
        }
    }

    /// The piece for `holiday`, drawn so its base sits on the bottom
    /// centre of `rect`.
    static func draw(_ c: inout Context, _ holiday: SeasonalHoliday, in rect: CGRect) {
        let base = CGPoint(x: rect.midX, y: rect.maxY)
        let w = rect.width
        switch holiday {
        case .halloween: witchHat(&c, base: base, w: w)
        case .diaDeMuertos: flowerCrown(&c, base: base, w: w)
        case .thanksgiving: pilgrimHat(&c, base: base, w: w)
        case .hanukkah:
            knitHat(&c, base: base, w: w, color: SeasonArt.hanukkahBlue, stripe: .white, pom: .white)
        case .christmas: santaHat(&c, base: base, w: w)
        case .kwanzaa: kufi(&c, base: base, w: w)
        case .newYear:
            SeasonArt.partyHat(&c, base: base, w: w * 0.56, h: w * 0.62, color: SeasonArt.gold, stripe: Color(white: 0.94))
        case .lunarNewYear: chineseKnot(&c, at: CGPoint(x: rect.midX, y: rect.midY), w: w)
        case .ramadanEid: crescentBand(&c, base: base, w: w)
        case .valentines: boppers(&c, base: base, w: w)
        case .stPatricks:
            topHat(&c, base: base, w: w, color: SeasonArt.paint(0.16, 0.56, 0.28), band: SeasonArt.gold,
                   stripes: nil)
            SeasonArt.shamrock(&c, at: CGPoint(x: base.x + w * 0.2, y: base.y - w * 0.3), size: w * 0.26, angle: 0.3)
        case .easter: bunnyEars(&c, base: base, w: w)
        case .earthDay: SeasonArt.sprout(&c, base: CGPoint(x: base.x, y: base.y + w * 0.02), size: w * 0.62)
        case .pride: rainbowBow(&c, at: CGPoint(x: rect.midX, y: rect.midY), w: w)
        case .independenceDay:
            topHat(&c, base: base, w: w, color: .white, band: SeasonArt.usBlue, stripes: SeasonArt.usRed)
        case .groundhogDay: roundEars(&c, base: base, w: w)
        case .birthday:
            SeasonArt.partyHat(&c, base: base, w: w * 0.56, h: w * 0.66, color: SeasonArt.paint(0.55, 0.78, 1),
                               stripe: SeasonArt.paint(1, 0.55, 0.68), dots: true)
        }
    }

    // MARK: Pieces

    private static func witchHat(_ c: inout Context, base: CGPoint, w: Double) {
        let purple = SeasonArt.paint(0.36, 0.22, 0.5)
        let brim = CGRect(x: base.x - w * 0.5, y: base.y - w * 0.12, width: w, height: w * 0.18)
        c.fill(Path(ellipseIn: brim), with: SeasonArt.lit(purple.mix(with: .black, by: 0.2), in: brim))
        var cone = Path()
        cone.move(to: CGPoint(x: base.x - w * 0.27, y: base.y - w * 0.06))
        cone.addQuadCurve(to: CGPoint(x: base.x + w * 0.24, y: base.y - w * 0.78),
                          control: CGPoint(x: base.x - w * 0.12, y: base.y - w * 0.6))
        cone.addQuadCurve(to: CGPoint(x: base.x + w * 0.27, y: base.y - w * 0.06),
                          control: CGPoint(x: base.x + w * 0.12, y: base.y - w * 0.5))
        cone.closeSubpath()
        let rect = CGRect(x: base.x - w * 0.27, y: base.y - w * 0.78, width: w * 0.54, height: w * 0.72)
        c.fill(cone, with: SeasonArt.lit(purple, in: rect))
        var band = c
        band.clip(to: cone)
        band.fill(Path(CGRect(x: base.x - w * 0.4, y: base.y - w * 0.2, width: w * 0.8, height: w * 0.09)),
                  with: .color(SeasonArt.paint(0.98, 0.55, 0.13)))
        let buckle = CGRect(x: base.x - w * 0.06, y: base.y - w * 0.205, width: w * 0.12, height: w * 0.1)
        c.stroke(Path(buckle), with: .color(SeasonArt.gold), lineWidth: max(0.3, w * 0.03))
    }

    private static func flowerCrown(_ c: inout Context, base: CGPoint, w: Double) {
        var vine = Path()
        vine.move(to: CGPoint(x: base.x - w * 0.42, y: base.y - w * 0.02))
        vine.addQuadCurve(to: CGPoint(x: base.x + w * 0.42, y: base.y - w * 0.02),
                          control: CGPoint(x: base.x, y: base.y - w * 0.26))
        c.stroke(vine, with: .color(SeasonArt.paint(0.3, 0.6, 0.3)), lineWidth: max(0.4, w * 0.05))
        let hues = [SeasonArt.paint(0.95, 0.3, 0.6), SeasonArt.paint(1, 0.62, 0.08),
                    SeasonArt.paint(0.98, 0.84, 0.2), SeasonArt.paint(1, 0.62, 0.08),
                    SeasonArt.paint(0.95, 0.3, 0.6)]
        for k in 0..<5 {
            let t = Double(k) / 4
            let x = base.x - w * 0.38 + t * w * 0.76
            let y = base.y - w * 0.04 - sin(t * .pi) * w * 0.13
            SeasonArt.marigold(&c, at: CGPoint(x: x, y: y), size: w * (k == 2 ? 0.3 : 0.24), hue: hues[k])
        }
    }

    private static func pilgrimHat(_ c: inout Context, base: CGPoint, w: Double) {
        let black = Color(white: 0.16)
        let brim = CGRect(x: base.x - w * 0.46, y: base.y - w * 0.1, width: w * 0.92, height: w * 0.16)
        c.fill(Path(ellipseIn: brim), with: SeasonArt.lit(black, in: brim))
        var crown = Path()
        crown.move(to: CGPoint(x: base.x - w * 0.27, y: base.y - w * 0.04))
        crown.addLine(to: CGPoint(x: base.x - w * 0.2, y: base.y - w * 0.56))
        crown.addLine(to: CGPoint(x: base.x + w * 0.2, y: base.y - w * 0.56))
        crown.addLine(to: CGPoint(x: base.x + w * 0.27, y: base.y - w * 0.04))
        crown.closeSubpath()
        c.fill(crown, with: SeasonArt.lit(black, in: CGRect(x: base.x - w * 0.27, y: base.y - w * 0.56,
                                                             width: w * 0.54, height: w * 0.52), light: 0.3))
        let band = CGRect(x: base.x - w * 0.255, y: base.y - w * 0.2, width: w * 0.51, height: w * 0.1)
        c.fill(Path(band), with: .color(SeasonArt.paint(0.5, 0.36, 0.22)))
        let buckle = CGRect(x: base.x - w * 0.08, y: base.y - w * 0.215, width: w * 0.16, height: w * 0.13)
        c.stroke(Path(roundedRect: buckle, cornerRadius: w * 0.01), with: .color(SeasonArt.gold), lineWidth: max(0.4, w * 0.04))
    }

    private static func knitHat(_ c: inout Context, base: CGPoint, w: Double, color: Color, stripe: Color, pom: Color) {
        var dome = Path()
        dome.move(to: CGPoint(x: base.x - w * 0.4, y: base.y - w * 0.06))
        dome.addQuadCurve(to: CGPoint(x: base.x + w * 0.4, y: base.y - w * 0.06), control: CGPoint(x: base.x, y: base.y - w * 0.84))
        dome.closeSubpath()
        let rect = CGRect(x: base.x - w * 0.4, y: base.y - w * 0.46, width: w * 0.8, height: w * 0.42)
        c.fill(dome, with: SeasonArt.lit(color, in: rect))
        var stripes = c
        stripes.clip(to: dome)
        stripes.fill(Path(CGRect(x: rect.minX, y: base.y - w * 0.3, width: rect.width, height: w * 0.07)), with: .color(stripe))
        let cuff = CGRect(x: base.x - w * 0.42, y: base.y - w * 0.16, width: w * 0.84, height: w * 0.16)
        c.fill(Path(roundedRect: cuff, cornerRadius: w * 0.07), with: SeasonArt.lit(color.mix(with: .black, by: 0.1), in: cuff))
        var ribs = Path()
        for k in 0..<6 {
            let x = cuff.minX + w * 0.1 + Double(k) * w * 0.13
            ribs.move(to: CGPoint(x: x, y: cuff.minY + w * 0.03))
            ribs.addLine(to: CGPoint(x: x, y: cuff.maxY - w * 0.03))
        }
        c.stroke(ribs, with: .color(.white.opacity(0.3)), lineWidth: max(0.3, w * 0.025))
        let ball = CGRect(x: base.x - w * 0.1, y: base.y - w * 0.56, width: w * 0.2, height: w * 0.2)
        c.fill(Path(ellipseIn: ball), with: SeasonArt.lit(pom, in: ball, light: 0, dark: 0.15))
    }

    private static func santaHat(_ c: inout Context, base: CGPoint, w: Double) {
        let red = SeasonArt.paint(0.88, 0.16, 0.18)
        var cone = Path()
        cone.move(to: CGPoint(x: base.x - w * 0.38, y: base.y - w * 0.1))
        cone.addQuadCurve(to: CGPoint(x: base.x + w * 0.46, y: base.y - w * 0.36),
                          control: CGPoint(x: base.x - w * 0.12, y: base.y - w * 0.92))
        cone.addQuadCurve(to: CGPoint(x: base.x + w * 0.36, y: base.y - w * 0.1),
                          control: CGPoint(x: base.x + w * 0.2, y: base.y - w * 0.5))
        cone.closeSubpath()
        let rect = CGRect(x: base.x - w * 0.38, y: base.y - w * 0.66, width: w * 0.84, height: w * 0.56)
        c.fill(cone, with: SeasonArt.lit(red, in: rect))
        let fur = CGRect(x: base.x - w * 0.44, y: base.y - w * 0.2, width: w * 0.88, height: w * 0.2)
        c.fill(Path(roundedRect: fur, cornerRadius: w * 0.1), with: SeasonArt.lit(.white, in: fur, light: 0, dark: 0.12))
        let pom = CGRect(x: base.x + w * 0.36, y: base.y - w * 0.46, width: w * 0.2, height: w * 0.2)
        c.fill(Path(ellipseIn: pom), with: SeasonArt.lit(.white, in: pom, light: 0, dark: 0.15))
    }

    private static func kufi(_ c: inout Context, base: CGPoint, w: Double) {
        let rect = CGRect(x: base.x - w * 0.36, y: base.y - w * 0.4, width: w * 0.72, height: w * 0.42)
        var cap = Path()
        cap.move(to: CGPoint(x: rect.minX, y: base.y))
        cap.addLine(to: CGPoint(x: rect.minX, y: base.y - w * 0.18))
        cap.addQuadCurve(to: CGPoint(x: rect.maxX, y: base.y - w * 0.18), control: CGPoint(x: base.x, y: base.y - w * 0.6))
        cap.addLine(to: CGPoint(x: rect.maxX, y: base.y))
        cap.closeSubpath()
        c.fill(cap, with: SeasonArt.lit(SeasonArt.paint(0.86, 0.16, 0.16), in: rect))
        var bands = c
        bands.clip(to: cap)
        bands.fill(Path(CGRect(x: rect.minX, y: base.y - w * 0.14, width: rect.width, height: w * 0.08)),
                   with: .color(Color(white: 0.12)))
        bands.fill(Path(CGRect(x: rect.minX, y: base.y - w * 0.06, width: rect.width, height: w * 0.08)),
                   with: .color(SeasonArt.paint(0.12, 0.6, 0.3)))
        var zig = Path()
        zig.move(to: CGPoint(x: rect.minX, y: base.y - w * 0.27))
        for k in 0..<8 {
            zig.addLine(to: CGPoint(x: rect.minX + Double(k + 1) * rect.width / 8,
                                    y: base.y - w * (k.isMultiple(of: 2) ? 0.32 : 0.24)))
        }
        bands.stroke(zig, with: .color(SeasonArt.gold), lineWidth: max(0.3, w * 0.035))
    }

    private static func chineseKnot(_ c: inout Context, at p: CGPoint, w: Double) {
        let red = SeasonArt.paint(0.88, 0.12, 0.14)
        for k in 0..<4 {
            let a = Double(k) * .pi / 2 + .pi / 4
            let loop = CGRect(x: p.x + cos(a) * w * 0.12 - w * 0.1, y: p.y + sin(a) * w * 0.12 - w * 0.1,
                              width: w * 0.2, height: w * 0.2)
            c.fill(Path(ellipseIn: loop), with: SeasonArt.lit(red, in: loop))
        }
        // A gold edge, so the knot holds on a red body.
        for k in 0..<4 {
            let a = Double(k) * .pi / 2 + .pi / 4
            let loop = CGRect(x: p.x + cos(a) * w * 0.12 - w * 0.1, y: p.y + sin(a) * w * 0.12 - w * 0.1,
                              width: w * 0.2, height: w * 0.2)
            c.stroke(Path(ellipseIn: loop), with: .color(SeasonArt.gold), lineWidth: max(0.35, w * 0.035))
        }
        let centre = CGRect(x: p.x - w * 0.07, y: p.y - w * 0.07, width: w * 0.14, height: w * 0.14)
        c.fill(Path(ellipseIn: centre), with: SeasonArt.lit(SeasonArt.gold, in: centre))
        var tassel = Path()
        for k in -1...1 {
            tassel.move(to: CGPoint(x: p.x, y: p.y + w * 0.18))
            tassel.addLine(to: CGPoint(x: p.x + Double(k) * w * 0.04, y: p.y + w * 0.38))
        }
        c.stroke(tassel, with: .color(SeasonArt.gold), lineWidth: max(0.3, w * 0.035))
    }

    private static func crescentBand(_ c: inout Context, base: CGPoint, w: Double) {
        var band = Path()
        band.move(to: CGPoint(x: base.x - w * 0.42, y: base.y))
        band.addQuadCurve(to: CGPoint(x: base.x + w * 0.42, y: base.y), control: CGPoint(x: base.x, y: base.y - w * 0.28))
        c.stroke(band, with: .color(SeasonArt.gold), lineWidth: max(0.5, w * 0.06))
        SeasonArt.crescent(&c, at: CGPoint(x: base.x - w * 0.03, y: base.y - w * 0.36), size: w * 0.34)
        SeasonArt.star(&c, at: CGPoint(x: base.x + w * 0.13, y: base.y - w * 0.42), size: w * 0.14, color: SeasonArt.gold)
    }

    private static func boppers(_ c: inout Context, base: CGPoint, w: Double) {
        var band = Path()
        band.move(to: CGPoint(x: base.x - w * 0.42, y: base.y))
        band.addQuadCurve(to: CGPoint(x: base.x + w * 0.42, y: base.y), control: CGPoint(x: base.x, y: base.y - w * 0.28))
        c.stroke(band, with: .color(SeasonArt.paint(0.85, 0.2, 0.4)), lineWidth: max(0.5, w * 0.06))
        for side in [-1.0, 1.0] {
            var spring = Path()
            spring.move(to: CGPoint(x: base.x + side * w * 0.16, y: base.y - w * 0.12))
            spring.addQuadCurve(to: CGPoint(x: base.x + side * w * 0.3, y: base.y - w * 0.5),
                                control: CGPoint(x: base.x + side * w * 0.12, y: base.y - w * 0.36))
            c.stroke(spring, with: .color(Color(white: 0.75)), lineWidth: max(0.3, w * 0.03))
            SeasonArt.heart(&c, at: CGPoint(x: base.x + side * w * 0.31, y: base.y - w * 0.6), size: w * 0.26,
                            color: SeasonArt.paint(0.95, 0.25, 0.42))
        }
    }

    private static func topHat(_ c: inout Context, base: CGPoint, w: Double, color: Color, band: Color, stripes: Color?) {
        let brim = CGRect(x: base.x - w * 0.38, y: base.y - w * 0.1, width: w * 0.76, height: w * 0.14)
        c.fill(Path(ellipseIn: brim), with: SeasonArt.lit(color.mix(with: .black, by: 0.08), in: brim))
        let crown = CGRect(x: base.x - w * 0.24, y: base.y - w * 0.66, width: w * 0.48, height: w * 0.62)
        let crownPath = Path(roundedRect: crown, cornerRadius: w * 0.04)
        c.fill(crownPath, with: SeasonArt.lit(color, in: crown, light: 0.2, dark: 0.18))
        if let stripes {
            var inside = c
            inside.clip(to: crownPath)
            for k in 0..<3 {
                let x = crown.minX + w * 0.04 + Double(k) * w * 0.16
                inside.fill(Path(CGRect(x: x, y: crown.minY, width: w * 0.08, height: crown.height)), with: .color(stripes))
            }
        }
        let ribbon = CGRect(x: crown.minX, y: base.y - w * 0.24, width: crown.width, height: w * 0.12)
        c.fill(Path(ribbon), with: .color(band))
        if stripes != nil {
            for k in 0..<3 {
                let at = CGPoint(x: crown.minX + w * 0.1 + Double(k) * w * 0.14, y: ribbon.midY)
                c.fill(SeasonArt.starPath(at, w * 0.045), with: .color(.white))
            }
        }
        SeasonArt.rim(&c, crownPath, color, width: max(0.25, w * 0.02))
    }

    private static func bunnyEars(_ c: inout Context, base: CGPoint, w: Double) {
        var band = Path()
        band.move(to: CGPoint(x: base.x - w * 0.42, y: base.y))
        band.addQuadCurve(to: CGPoint(x: base.x + w * 0.42, y: base.y), control: CGPoint(x: base.x, y: base.y - w * 0.28))
        c.stroke(band, with: .color(SeasonArt.paint(0.98, 0.72, 0.82)), lineWidth: max(0.5, w * 0.06))
        for side in [-1.0, 1.0] {
            var ear = c
            ear.translateBy(x: base.x + side * w * 0.17, y: base.y - w * 0.14)
            ear.rotate(by: .radians(side * 0.22))
            let outer = CGRect(x: -w * 0.1, y: -w * 0.68, width: w * 0.2, height: w * 0.68)
            ear.fill(Path(ellipseIn: outer), with: SeasonArt.lit(.white, in: outer, light: 0, dark: 0.12))
            let inner = outer.insetBy(dx: w * 0.045, dy: w * 0.1)
            ear.fill(Path(ellipseIn: inner), with: .color(SeasonArt.paint(1, 0.7, 0.78)))
        }
    }

    private static func rainbowBow(_ c: inout Context, at p: CGPoint, w: Double) {
        for side in [-1.0, 1.0] {
            var loop = Path()
            loop.move(to: p)
            loop.addQuadCurve(to: CGPoint(x: p.x + side * w * 0.3, y: p.y - w * 0.16),
                              control: CGPoint(x: p.x + side * w * 0.12, y: p.y - w * 0.3))
            loop.addQuadCurve(to: p, control: CGPoint(x: p.x + side * w * 0.36, y: p.y + w * 0.14))
            var inside = c
            inside.clip(to: loop)
            for (k, color) in SeasonArt.rainbow.enumerated() {
                let y = p.y - w * 0.24 + Double(k) * w * 0.07
                inside.fill(Path(CGRect(x: p.x - w * 0.4, y: y, width: w * 0.8, height: w * 0.07)), with: .color(color))
            }
        }
        let knot = CGRect(x: p.x - w * 0.06, y: p.y - w * 0.07, width: w * 0.12, height: w * 0.12)
        c.fill(Path(ellipseIn: knot), with: SeasonArt.lit(SeasonArt.rainbow[4], in: knot))
    }

    private static func roundEars(_ c: inout Context, base: CGPoint, w: Double) {
        let fur = SeasonArt.paint(0.6, 0.42, 0.26)
        var band = Path()
        band.move(to: CGPoint(x: base.x - w * 0.42, y: base.y))
        band.addQuadCurve(to: CGPoint(x: base.x + w * 0.42, y: base.y), control: CGPoint(x: base.x, y: base.y - w * 0.28))
        c.stroke(band, with: .color(fur.mix(with: .black, by: 0.2)), lineWidth: max(0.5, w * 0.06))
        for side in [-1.0, 1.0] {
            let ear = CGRect(x: base.x + side * w * 0.24 - w * 0.13, y: base.y - w * 0.4, width: w * 0.26, height: w * 0.26)
            c.fill(Path(ellipseIn: ear), with: SeasonArt.lit(fur, in: ear))
            c.fill(Path(ellipseIn: ear.insetBy(dx: w * 0.06, dy: w * 0.06)), with: .color(SeasonArt.paint(0.86, 0.68, 0.56)))
        }
    }
}

/// The few slow particles a set drifts through the tank: snow, leaves,
/// petals, hearts rising like bubbles, confetti, bats, twinkling stars,
/// gold coins sinking. A pure function of the clock, so a held clock
/// (Reduce Motion, resting on battery, a hidden window) is a still frame
/// and nothing is stored between frames. At a few points across the
/// shading doesn't show, so each is one flat path: they ride the live
/// pass and cost next to nothing there.
enum SeasonParticles {
    typealias Context = GraphicsContext

    /// How many drift at once: a few, never a blizzard.
    static let count = 9

    static func draw(_ c: inout Context, _ occasion: SeasonalOccasion, in rect: CGRect, t: Double) {
        let holiday = occasion.holiday
        let colors = palette(holiday)
        for i in 0..<count {
            let seed = Double((i * 7919 + holiday.rawValue.count * 104_729) % 1000) / 1000
            let seed2 = Double((i * 3571 + 17) % 997) / 997
            let speed = 6 + seed2 * 7
            let size = 5 + seed * 4
            let span = rect.height + 30
            let fall = (seed2 * span + t * speed).truncatingRemainder(dividingBy: span)
            let x = rect.minX + (Double(i) + seed * 0.8) / Double(count) * rect.width + sin(t * 0.5 + seed * 6) * 14
            let down = CGPoint(x: x, y: rect.minY - 15 + fall)
            let up = CGPoint(x: x, y: rect.maxY + 15 - fall)
            let turn = t * (0.6 + seed) + seed * 6
            let color = colors[i % colors.count]
            switch holiday {
            case .christmas, .groundhogDay:
                SeasonArt.snowflake(&c, at: down, size: size * 1.3, opacity: 0.85)
            case .hanukkah:
                if i.isMultiple(of: 3) {
                    flat(&c, Path(ellipseIn: CGRect(x: down.x - size * 0.5, y: down.y - size * 0.5,
                                                    width: size, height: size)), at: .zero, angle: 0, color: SeasonArt.gold)
                } else {
                    SeasonArt.snowflake(&c, at: down, size: size * 1.3, opacity: 0.85)
                }
            case .halloween:
                if i % 3 == 0 {
                    let across = (seed * (rect.width + 40) + t * speed * 1.4).truncatingRemainder(dividingBy: rect.width + 40)
                    let at = CGPoint(x: rect.minX - 20 + across,
                                     y: rect.minY + seed2 * rect.height * 0.6 + sin(t + seed * 5) * 8)
                    flat(&c, batPath(size * 1.8, flap: sin(t * 6 + seed * 9)), at: at, angle: 0,
                         color: SeasonArt.paint(0.26, 0.18, 0.36))
                } else {
                    flat(&c, leafPath(size * 1.4), at: down, angle: turn, color: color)
                }
            case .thanksgiving, .earthDay:
                flat(&c, leafPath(size * 1.6), at: down, angle: turn, color: color)
            case .diaDeMuertos, .easter:
                flat(&c, Path(ellipseIn: CGRect(x: -size * 0.6, y: -size * 0.36, width: size * 1.2, height: size * 0.72)),
                     at: down, angle: turn, color: color)
            case .valentines:
                flat(&c, SeasonArt.heartPath(.zero, size * 1.4), at: up, angle: sin(t + seed * 4) * 0.2, color: color)
            case .stPatricks:
                flat(&c, cloverPath(size * 1.5), at: down, angle: turn, color: color)
            case .newYear, .birthday, .pride, .kwanzaa:
                let bit = Path(roundedRect: CGRect(x: -size * 0.55, y: -size * 0.24, width: size * 1.1, height: size * 0.48),
                               cornerSize: CGSize(width: size * 0.1, height: size * 0.1))
                flat(&c, bit, at: down, angle: turn, color: color)
            case .lunarNewYear, .ramadanEid, .independenceDay:
                var spark = c
                spark.opacity = 0.45 + 0.55 * abs(sin(t * 0.9 + seed * 7))
                let at = CGPoint(x: x, y: rect.minY + seed2 * rect.height * 0.7)
                flat(&spark, SeasonArt.starPath(.zero, size * 0.65), at: at, angle: 0, color: color)
            }
        }
    }

    /// Each set's particle colours.
    static func palette(_ holiday: SeasonalHoliday) -> [Color] {
        switch holiday {
        case .halloween: return [SeasonArt.paint(0.98, 0.55, 0.13), SeasonArt.paint(0.55, 0.35, 0.7)]
        case .thanksgiving:
            return [SeasonArt.paint(0.86, 0.3, 0.12), SeasonArt.paint(0.95, 0.6, 0.14), SeasonArt.paint(0.7, 0.36, 0.14)]
        case .earthDay: return [SeasonArt.paint(0.36, 0.72, 0.32), SeasonArt.paint(0.5, 0.8, 0.4)]
        case .diaDeMuertos: return [SeasonArt.paint(1, 0.62, 0.08), SeasonArt.paint(1, 0.78, 0.2)]
        case .easter:
            return [SeasonArt.paint(0.98, 0.72, 0.78), SeasonArt.paint(0.7, 0.86, 1), SeasonArt.paint(0.98, 0.92, 0.6)]
        case .valentines: return [SeasonArt.paint(0.95, 0.3, 0.45), SeasonArt.paint(1, 0.6, 0.72)]
        case .stPatricks: return [SeasonArt.paint(0.2, 0.66, 0.3), SeasonArt.paint(0.3, 0.74, 0.36)]
        case .pride: return SeasonArt.rainbow
        case .kwanzaa: return [SeasonArt.paint(0.86, 0.16, 0.16), Color(white: 0.2), SeasonArt.paint(0.12, 0.6, 0.3)]
        case .newYear: return [SeasonArt.gold, Color(white: 0.9), SeasonArt.paint(0.75, 0.6, 1)]
        case .birthday:
            return [SeasonArt.paint(1, 0.5, 0.6), SeasonArt.paint(0.45, 0.75, 1), SeasonArt.paint(1, 0.82, 0.3),
                    SeasonArt.paint(0.6, 0.86, 0.45)]
        case .independenceDay: return [SeasonArt.usRed, .white, SeasonArt.paint(0.45, 0.62, 1)]
        case .lunarNewYear, .ramadanEid: return [SeasonArt.gold, SeasonArt.paint(1, 0.9, 0.6)]
        case .christmas, .groundhogDay, .hanukkah: return [.white]
        }
    }

    /// One flat path at `p`, turned by `angle`.
    private static func flat(_ c: inout Context, _ path: Path, at p: CGPoint, angle: Double, color: Color) {
        var local = c
        local.translateBy(x: p.x, y: p.y)
        if angle != 0 { local.rotate(by: .radians(angle)) }
        local.fill(path, with: .color(color))
    }

    private static func leafPath(_ s: Double) -> Path {
        var blade = Path()
        blade.move(to: CGPoint(x: 0, y: -s * 0.5))
        blade.addCurve(to: CGPoint(x: 0, y: s * 0.4), control1: CGPoint(x: s * 0.5, y: -s * 0.3),
                       control2: CGPoint(x: s * 0.42, y: s * 0.2))
        blade.addCurve(to: CGPoint(x: 0, y: -s * 0.5), control1: CGPoint(x: -s * 0.42, y: s * 0.2),
                       control2: CGPoint(x: -s * 0.5, y: -s * 0.3))
        return blade
    }

    private static func cloverPath(_ s: Double) -> Path {
        var path = Path()
        for k in 0..<3 {
            let a = -Double.pi / 2 + Double(k) * 2 * .pi / 3
            let leaf = CGRect(x: cos(a) * s * 0.22 - s * 0.2, y: sin(a) * s * 0.22 - s * 0.2, width: s * 0.4, height: s * 0.4)
            path.addEllipse(in: leaf)
        }
        return path
    }

    private static func batPath(_ s: Double, flap: Double) -> Path {
        let lift = flap * s * 0.2
        var path = Path()
        path.addEllipse(in: CGRect(x: -s * 0.14, y: -s * 0.2, width: s * 0.28, height: s * 0.4))
        for side in [-1.0, 1.0] {
            path.move(to: CGPoint(x: side * s * 0.1, y: -s * 0.08))
            path.addQuadCurve(to: CGPoint(x: side * s * 0.8, y: -s * 0.26 - lift),
                              control: CGPoint(x: side * s * 0.42, y: -s * 0.5 - lift))
            path.addQuadCurve(to: CGPoint(x: side * s * 0.1, y: s * 0.12),
                              control: CGPoint(x: side * s * 0.6, y: s * 0.05 - lift))
            path.closeSubpath()
        }
        return path
    }
}
