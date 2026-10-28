import JRBarCore
import SwiftUI

/// What each holiday wears on each surface: what hangs on its garland,
/// its centrepiece, its props on the tank's sand, the particles that
/// drift through the water, and the small accent in Settings. Drawn with
/// `SeasonArt`; every drawing takes the occasion, so Hanukkah lights the
/// night's candles and Kwanzaa the day's.
enum SeasonLook {
    typealias Context = GraphicsContext

    // MARK: Garland

    /// The string's colour.
    static func string(_ holiday: SeasonalHoliday) -> Color {
        switch holiday {
        case .christmas, .stPatricks, .earthDay: return SeasonArt.paint(0.2, 0.36, 0.22)
        case .halloween: return SeasonArt.paint(0.3, 0.22, 0.36)
        case .lunarNewYear, .ramadanEid, .newYear, .hanukkah: return SeasonArt.gold.mix(with: .black, by: 0.15)
        default: return Color(white: 0.82)
        }
    }

    /// How many pieces hang on a garland `width` points long.
    static func count(for width: Double, holiday: SeasonalHoliday) -> Int {
        let pitch: Double
        switch holiday {
        case .christmas: pitch = 13
        case .lunarNewYear, .ramadanEid: pitch = 26
        case .halloween, .groundhogDay, .thanksgiving: pitch = 17
        default: pitch = 14
        }
        return max(3, Int((width / pitch).rounded()))
    }

    /// The `index`th piece on the garland, hanging from `top`, `s` tall.
    static func garlandPiece(_ c: inout Context, _ occasion: SeasonalOccasion, index i: Int, top: CGPoint,
                             size s: Double, phase: Double) {
        let p = CGPoint(x: top.x, y: top.y + s * 0.5)
        switch occasion.holiday {
        case .halloween:
            if i % 3 == 1 {
                SeasonArt.bat(&c, at: CGPoint(x: p.x, y: p.y + s * 0.05), size: s * 0.7, flap: sin(phase * 3 + Double(i)) * 0.4)
            } else {
                hangString(&c, from: top, length: s * 0.2)
                SeasonArt.pumpkin(&c, at: CGPoint(x: p.x, y: p.y + s * 0.12), size: s * 0.72, carved: true,
                                  glow: 0.5)
            }
        case .diaDeMuertos:
            let colors = [SeasonArt.paint(0.95, 0.3, 0.6), SeasonArt.paint(1, 0.6, 0.12),
                          SeasonArt.paint(0.98, 0.84, 0.2), SeasonArt.paint(0.3, 0.78, 0.5),
                          SeasonArt.paint(0.25, 0.6, 0.95), SeasonArt.paint(0.62, 0.38, 0.9)]
            SeasonArt.papelPicado(&c, top: top, w: s * 0.92, h: s * 1.05, color: colors[i % colors.count])
        case .thanksgiving:
            let colors = [SeasonArt.paint(0.86, 0.3, 0.12), SeasonArt.paint(0.95, 0.6, 0.14),
                          SeasonArt.paint(0.7, 0.36, 0.14), SeasonArt.paint(0.9, 0.75, 0.25)]
            if i % 4 == 3 {
                SeasonArt.acorn(&c, at: CGPoint(x: p.x, y: p.y), size: s * 0.7)
            } else {
                SeasonArt.leaf(&c, at: CGPoint(x: p.x, y: p.y + s * 0.05), size: s * 0.95,
                               angle: .pi + (i.isMultiple(of: 2) ? 0.3 : -0.3), color: colors[i % colors.count])
            }
        case .hanukkah:
            if i.isMultiple(of: 2) {
                let color = i % 4 == 0 ? SeasonArt.hanukkahBlue : SeasonArt.paint(0.92, 0.95, 1)
                let flag = SeasonArt.pennantPath(top: top, w: s * 0.82, h: s)
                c.fill(flag, with: SeasonArt.fall(color, in: CGRect(x: top.x - s * 0.4, y: top.y, width: s * 0.8, height: s)))
                let mark = i % 4 == 0 ? Color.white : SeasonArt.hanukkahBlue
                SeasonArt.hexagram(&c, at: CGPoint(x: top.x, y: top.y + s * 0.33), size: s * 0.36, color: mark)
            } else {
                hangString(&c, from: top, length: s * 0.15)
                SeasonArt.dreidel(&c, at: CGPoint(x: p.x, y: p.y + s * 0.08), size: s * 0.72,
                                  tilt: i % 4 == 1 ? 0.25 : -0.25)
            }
        case .christmas:
            let colors = [SeasonArt.paint(0.95, 0.25, 0.25), SeasonArt.paint(0.3, 0.8, 0.4),
                          SeasonArt.paint(1, 0.78, 0.25), SeasonArt.paint(0.35, 0.6, 1)]
            let on = 0.65 + 0.35 * sin(phase * 1.6 + Double(i) * 1.3)
            SeasonArt.bulb(&c, top: top, size: s * 0.82, color: colors[i % colors.count], glowing: on)
        case .kwanzaa:
            let colors = [SeasonArt.paint(0.86, 0.16, 0.16), Color(white: 0.14), SeasonArt.paint(0.12, 0.6, 0.3)]
            pennant(&c, top: top, s: s, color: colors[i % 3])
        case .newYear:
            if i.isMultiple(of: 2) {
                let color = i % 4 == 0 ? SeasonArt.gold : Color(white: 0.86)
                pennant(&c, top: top, s: s, color: color)
                SeasonArt.star(&c, at: CGPoint(x: top.x, y: top.y + s * 0.33), size: s * 0.34,
                               color: i % 4 == 0 ? .white : SeasonArt.gold)
            } else {
                curl(&c, top: top, s: s, color: SeasonArt.rainbow[(i / 2) % SeasonArt.rainbow.count])
            }
        case .lunarNewYear:
            hangString(&c, from: top, length: s * 0.15)
            SeasonArt.redLantern(&c, top: CGPoint(x: top.x, y: top.y + s * 0.12), size: s * 0.9, glowing: 0.6)
        case .ramadanEid:
            hangString(&c, from: top, length: s * (i.isMultiple(of: 2) ? 0.2 : 0.4))
            if i.isMultiple(of: 2) {
                SeasonArt.fanous(&c, top: CGPoint(x: top.x, y: top.y + s * 0.18), size: s, glowing: 0.7)
            } else {
                SeasonArt.crescent(&c, at: CGPoint(x: top.x, y: top.y + s * 0.62), size: s * 0.46)
                SeasonArt.star(&c, at: CGPoint(x: top.x + s * 0.2, y: top.y + s * 0.5), size: s * 0.2, color: SeasonArt.gold)
            }
        case .valentines:
            let colors = [SeasonArt.paint(0.95, 0.25, 0.4), SeasonArt.paint(1, 0.55, 0.7),
                          SeasonArt.paint(0.85, 0.12, 0.3)]
            hangString(&c, from: top, length: s * 0.15)
            SeasonArt.heart(&c, at: CGPoint(x: p.x, y: p.y + s * 0.08), size: s * 0.72, color: colors[i % 3])
        case .stPatricks:
            if i % 3 == 2 {
                pennant(&c, top: top, s: s * 0.9, color: SeasonArt.gold)
            } else {
                SeasonArt.shamrock(&c, at: CGPoint(x: p.x, y: p.y - s * 0.04), size: s * 0.82,
                                   angle: i.isMultiple(of: 2) ? 0.2 : -0.2)
            }
        case .easter:
            let pastels = [SeasonArt.paint(0.98, 0.72, 0.78), SeasonArt.paint(0.7, 0.86, 1),
                           SeasonArt.paint(0.98, 0.92, 0.6), SeasonArt.paint(0.75, 0.93, 0.72),
                           SeasonArt.paint(0.86, 0.76, 0.98)]
            hangString(&c, from: top, length: s * 0.12)
            SeasonArt.egg(&c, at: CGPoint(x: p.x, y: p.y + s * 0.1), size: s * 0.8, color: pastels[i % pastels.count],
                          band: pastels[(i + 2) % pastels.count].mix(with: .black, by: 0.2),
                          tilt: i.isMultiple(of: 2) ? 0.15 : -0.15)
        case .earthDay:
            let green = SeasonArt.paint(0.36, 0.72, 0.32)
            if i % 4 == 2 {
                SeasonArt.marigold(&c, at: CGPoint(x: p.x, y: p.y - s * 0.1), size: s * 0.55,
                                   hue: SeasonArt.paint(0.98, 0.85, 0.3))
            } else {
                SeasonArt.leaf(&c, at: CGPoint(x: p.x, y: p.y), size: s * 0.85,
                               angle: .pi + (i.isMultiple(of: 2) ? 0.5 : -0.5),
                               color: green.mix(with: i.isMultiple(of: 2) ? .white : .black, by: 0.1))
            }
        case .pride:
            pennant(&c, top: top, s: s, color: SeasonArt.rainbow[i % SeasonArt.rainbow.count])
        case .independenceDay:
            if i % 3 == 1 {
                hangString(&c, from: top, length: s * 0.15)
                SeasonArt.star(&c, at: CGPoint(x: p.x, y: p.y + s * 0.05), size: s * 0.75, color: SeasonArt.usBlue)
            } else {
                pennant(&c, top: top, s: s, color: i % 3 == 0 ? SeasonArt.usRed : .white)
            }
        case .groundhogDay:
            if i.isMultiple(of: 2) {
                SeasonArt.snowflake(&c, at: CGPoint(x: p.x, y: p.y), size: s * 0.7)
            } else {
                hangString(&c, from: top, length: s * 0.2)
                SeasonArt.sun(&c, at: CGPoint(x: p.x, y: p.y + s * 0.1), size: s * 0.72)
            }
        case .birthday:
            let colors = [SeasonArt.paint(1, 0.5, 0.6), SeasonArt.paint(0.45, 0.75, 1),
                          SeasonArt.paint(1, 0.82, 0.3), SeasonArt.paint(0.6, 0.86, 0.45),
                          SeasonArt.paint(0.76, 0.55, 1)]
            pennant(&c, top: top, s: s, color: colors[i % colors.count], dots: true)
        }
    }

    private static func hangString(_ c: inout Context, from top: CGPoint, length: Double) {
        var line = Path()
        line.move(to: top)
        line.addLine(to: CGPoint(x: top.x, y: top.y + length))
        c.stroke(line, with: .color(Color(white: 0.75).opacity(0.7)), lineWidth: 0.5)
    }

    private static func pennant(_ c: inout Context, top: CGPoint, s: Double, color: Color, dots: Bool = false) {
        let flag = SeasonArt.pennantPath(top: top, w: s * 0.82, h: s)
        let rect = CGRect(x: top.x - s * 0.41, y: top.y, width: s * 0.82, height: s)
        c.fill(flag, with: SeasonArt.fall(color, in: rect, light: 0.22, dark: 0.18))
        SeasonArt.rim(&c, flag, color, width: 0.35)
        guard dots else { return }
        var inside = c
        inside.clip(to: flag)
        for (dx, dy) in [(-0.16, 0.18), (0.14, 0.2), (0.0, 0.48)] {
            let r = s * 0.07
            inside.fill(Path(ellipseIn: CGRect(x: top.x + dx * s - r, y: top.y + dy * s - r, width: r * 2, height: r * 2)),
                        with: .color(.white.opacity(0.8)))
        }
    }

    private static func curl(_ c: inout Context, top: CGPoint, s: Double, color: Color) {
        var ribbon = Path()
        ribbon.move(to: top)
        for k in 0..<3 {
            let y = top.y + Double(k + 1) * s * 0.3
            ribbon.addQuadCurve(to: CGPoint(x: top.x, y: y),
                                control: CGPoint(x: top.x + (k.isMultiple(of: 2) ? s * 0.3 : -s * 0.3), y: y - s * 0.15))
        }
        c.stroke(ribbon, with: .color(color), style: StrokeStyle(lineWidth: max(0.6, s * 0.1), lineCap: .round))
    }

    /// Half the widest piece a set hangs, as a share of the piece's size:
    /// a bat's wings, a turned leaf, a sheet of papel picado. The first
    /// and last pieces sit this far inside the string's ends.
    static func pieceHalfWidth(_ holiday: SeasonalHoliday) -> Double {
        switch holiday {
        case .halloween: return 0.68
        case .thanksgiving, .earthDay: return 0.52
        case .diaDeMuertos: return 0.47
        case .lunarNewYear: return 0.42
        case .hanukkah, .kwanzaa, .newYear, .pride, .independenceDay, .birthday, .valentines: return 0.42
        case .stPatricks: return 0.4
        case .groundhogDay: return 0.38
        case .christmas, .easter, .ramadanEid: return 0.32
        }
    }

    /// A garland along `span`, its string from one end to the other at
    /// height `y`, sagging `sag` points at its middle, with pieces `size`
    /// tall hung inside the span. `keepClear` is a stretch of the string
    /// that carries no pieces (the card's caption and centrepiece).
    static func garland(_ c: inout Context, _ occasion: SeasonalOccasion, span: SeasonalGarlandSpan, y: Double,
                        sag: Double, size: Double, phase: Double = 0, keepClear: ClosedRange<Double>? = nil) {
        let from = CGPoint(x: span.start, y: y)
        let to = CGPoint(x: span.end, y: y)
        let control = CGPoint(x: (from.x + to.x) / 2, y: y + sag * 2)
        var line = Path()
        line.move(to: from)
        line.addQuadCurve(to: to, control: control)
        c.stroke(line, with: .color(string(occasion.holiday)), style: StrokeStyle(lineWidth: 0.8, lineCap: .round))
        let half = pieceHalfWidth(occasion.holiday) * size
        let count = SeasonLook.count(for: span.length, holiday: occasion.holiday)
        for (i, x) in span.centres(count: count, halfWidth: half).enumerated() {
            if let keepClear, x + half > keepClear.lowerBound, x - half < keepClear.upperBound { continue }
            // The control point sits over the middle, so x runs straight
            // along t and the string's height at x is one quadratic.
            let t = span.length > 0 ? (x - span.start) / span.length : 0.5
            let u = 1 - t
            let top = CGPoint(x: x, y: u * u * from.y + 2 * u * t * control.y + t * t * to.y)
            garlandPiece(&c, occasion, index: i, top: top, size: size, phase: phase)
        }
    }

    // MARK: Centrepiece

    /// The set's centrepiece, `s` tall, standing on `base` (its bottom
    /// centre).
    static func centerpiece(_ c: inout Context, _ occasion: SeasonalOccasion, base: CGPoint, size s: Double,
                            phase: Double = 0, ground: Color = SeasonArt.paint(0.5, 0.38, 0.26)) {
        let p = CGPoint(x: base.x, y: base.y - s * 0.5)
        let flicker = sin(phase * 7)
        switch occasion.holiday {
        case .halloween:
            SeasonArt.pumpkin(&c, at: CGPoint(x: p.x, y: p.y + s * 0.08), size: s * 0.8, carved: true, glow: 1)
            SeasonArt.bat(&c, at: CGPoint(x: p.x + s * 0.5, y: p.y - s * 0.38), size: s * 0.3, flap: sin(phase * 3) * 0.5)
        case .diaDeMuertos:
            SeasonArt.sugarSkull(&c, at: CGPoint(x: p.x, y: p.y + s * 0.02), size: s * 0.82)
            SeasonArt.marigold(&c, at: CGPoint(x: p.x - s * 0.42, y: p.y + s * 0.34), size: s * 0.3)
            SeasonArt.marigold(&c, at: CGPoint(x: p.x + s * 0.42, y: p.y + s * 0.36), size: s * 0.26)
        case .thanksgiving:
            SeasonArt.leaf(&c, at: CGPoint(x: p.x - s * 0.38, y: p.y + s * 0.18), size: s * 0.36, angle: -1.2,
                           color: SeasonArt.paint(0.86, 0.3, 0.12))
            SeasonArt.leaf(&c, at: CGPoint(x: p.x + s * 0.4, y: p.y + s * 0.2), size: s * 0.32, angle: 1.1,
                           color: SeasonArt.paint(0.95, 0.62, 0.14))
            SeasonArt.pie(&c, at: CGPoint(x: p.x, y: p.y + s * 0.2), size: s * 0.6)
        case .hanukkah:
            SeasonArt.menorah(&c, at: CGPoint(x: p.x, y: p.y + s * 0.0), size: s * 0.9, nights: occasion.day,
                              flicker: flicker)
        case .christmas:
            SeasonArt.tree(&c, at: CGPoint(x: p.x, y: p.y), size: s, twinkle: phase)
            SeasonArt.gift(&c, at: CGPoint(x: p.x + s * 0.38, y: p.y + s * 0.36), size: s * 0.24,
                           color: SeasonArt.paint(0.86, 0.2, 0.24))
        case .kwanzaa:
            SeasonArt.kinara(&c, at: CGPoint(x: p.x, y: p.y + s * 0.05), size: s * 0.9, days: occasion.day,
                             flicker: flicker)
        case .newYear:
            SeasonArt.firework(&c, at: CGPoint(x: p.x - s * 0.18, y: p.y - s * 0.22), r: s * 0.26, color: SeasonArt.gold)
            SeasonArt.firework(&c, at: CGPoint(x: p.x + s * 0.3, y: p.y - s * 0.34), r: s * 0.17,
                               color: SeasonArt.paint(0.75, 0.6, 1))
            SeasonArt.partyPopper(&c, at: CGPoint(x: p.x + s * 0.1, y: p.y + s * 0.18), size: s * 0.6)
        case .lunarNewYear:
            SeasonArt.redLantern(&c, top: CGPoint(x: p.x - s * 0.24, y: p.y - s * 0.5), size: s * 0.62)
            SeasonArt.redLantern(&c, top: CGPoint(x: p.x + s * 0.26, y: p.y - s * 0.36), size: s * 0.52)
            SeasonArt.redEnvelope(&c, at: CGPoint(x: p.x + s * 0.02, y: p.y + s * 0.3), size: s * 0.36)
        case .ramadanEid:
            if occasion.phase == .eid {
                SeasonArt.crescent(&c, at: CGPoint(x: p.x - s * 0.06, y: p.y - s * 0.08), size: s * 0.66)
                SeasonArt.star(&c, at: CGPoint(x: p.x + s * 0.28, y: p.y - s * 0.22), size: s * 0.22, color: SeasonArt.gold)
                SeasonArt.gift(&c, at: CGPoint(x: p.x + s * 0.24, y: p.y + s * 0.32), size: s * 0.3,
                               color: SeasonArt.paint(0.22, 0.6, 0.55))
            } else {
                SeasonArt.fanous(&c, top: CGPoint(x: p.x - s * 0.08, y: p.y - s * 0.46), size: s * 0.9)
                SeasonArt.crescent(&c, at: CGPoint(x: p.x + s * 0.34, y: p.y - s * 0.3), size: s * 0.3)
            }
        case .valentines:
            SeasonArt.heart(&c, at: CGPoint(x: p.x - s * 0.06, y: p.y + s * 0.06), size: s * 0.7,
                            color: SeasonArt.paint(0.92, 0.2, 0.36))
            SeasonArt.heart(&c, at: CGPoint(x: p.x + s * 0.34, y: p.y - s * 0.3), size: s * 0.28,
                            color: SeasonArt.paint(1, 0.55, 0.7))
        case .stPatricks:
            SeasonArt.potOfGold(&c, at: CGPoint(x: p.x, y: p.y + s * 0.08), size: s * 0.8)
        case .easter:
            let pastels = [SeasonArt.paint(0.98, 0.72, 0.78), SeasonArt.paint(0.7, 0.86, 1),
                           SeasonArt.paint(0.98, 0.92, 0.6)]
            grass(&c, base: base, width: s * 1.1, height: s * 0.22)
            SeasonArt.egg(&c, at: CGPoint(x: p.x - s * 0.28, y: p.y + s * 0.2), size: s * 0.5, color: pastels[0],
                          band: pastels[1].mix(with: .black, by: 0.2), tilt: -0.2)
            SeasonArt.egg(&c, at: CGPoint(x: p.x + s * 0.06, y: p.y + s * 0.08), size: s * 0.66, color: pastels[1],
                          band: pastels[2].mix(with: .black, by: 0.25))
            SeasonArt.egg(&c, at: CGPoint(x: p.x + s * 0.36, y: p.y + s * 0.24), size: s * 0.44, color: pastels[2],
                          band: pastels[0].mix(with: .black, by: 0.2), tilt: 0.25)
        case .earthDay:
            SeasonArt.globe(&c, at: CGPoint(x: p.x, y: p.y + s * 0.06), size: s * 0.82)
        case .pride:
            SeasonArt.rainbowArc(&c, at: CGPoint(x: p.x, y: p.y), size: s)
        case .independenceDay:
            SeasonArt.firework(&c, at: CGPoint(x: p.x + s * 0.24, y: p.y - s * 0.28), r: s * 0.22, color: SeasonArt.usRed)
            SeasonArt.firework(&c, at: CGPoint(x: p.x - s * 0.3, y: p.y - s * 0.12), r: s * 0.16,
                               color: SeasonArt.paint(0.4, 0.6, 1))
            SeasonArt.flag(&c, base: CGPoint(x: p.x - s * 0.12, y: base.y), size: s * 0.8, wave: sin(phase))
        case .groundhogDay:
            SeasonArt.sun(&c, at: CGPoint(x: p.x + s * 0.34, y: p.y - s * 0.3), size: s * 0.3)
            SeasonArt.groundhog(&c, at: CGPoint(x: p.x, y: p.y + s * 0.2), size: s * 0.82, ground: ground)
        case .birthday:
            SeasonArt.cake(&c, at: CGPoint(x: p.x, y: p.y + s * 0.04), size: s * 0.82, candles: 3, flicker: flicker)
        }
    }

    private static func grass(_ c: inout Context, base: CGPoint, width: Double, height: Double) {
        let green = SeasonArt.paint(0.42, 0.75, 0.34)
        for k in 0..<14 {
            let x = base.x - width / 2 + Double(k) / 13 * width
            var blade = Path()
            blade.move(to: CGPoint(x: x - 1, y: base.y))
            blade.addQuadCurve(to: CGPoint(x: x + (k.isMultiple(of: 2) ? 1.5 : -1.5), y: base.y - height * (0.6 + Double(k % 3) * 0.2)),
                               control: CGPoint(x: x, y: base.y - height * 0.5))
            blade.addLine(to: CGPoint(x: x + 1, y: base.y))
            blade.closeSubpath()
            c.fill(blade, with: .color(green.mix(with: .black, by: Double(k % 3) * 0.1)))
        }
    }

    // MARK: The tank's sand

    /// One or two props on the tank's sand, standing on `base`, `s` tall.
    /// The groundhog peeks out of the sand itself.
    static func sandProps(_ c: inout Context, _ occasion: SeasonalOccasion, base: CGPoint, size s: Double,
                          sand: Color, night: Double, phase: Double) {
        switch occasion.holiday {
        case .halloween:
            SeasonArt.pumpkin(&c, at: CGPoint(x: base.x, y: base.y - s * 0.32), size: s * 0.72, carved: true,
                              glow: 0.35 + 0.65 * night)
            SeasonArt.pumpkin(&c, at: CGPoint(x: base.x + s * 0.68, y: base.y - s * 0.2), size: s * 0.42)
        case .lunarNewYear:
            // Lanterns bob on their strings, tied to a stone on the sand.
            let stone = CGRect(x: base.x - s * 0.18, y: base.y - s * 0.12, width: s * 0.36, height: s * 0.16)
            c.fill(Path(ellipseIn: stone), with: SeasonArt.lit(Color(white: 0.5), in: stone))
            for (k, dx) in [-0.16, 0.2].enumerated() {
                let bob = sin(phase * 0.6 + Double(k) * 2) * s * 0.04
                let top = CGPoint(x: base.x + dx * s, y: base.y - s * (1.05 - Double(k) * 0.18) + bob)
                var tether = Path()
                tether.move(to: CGPoint(x: base.x, y: base.y - s * 0.08))
                tether.addLine(to: CGPoint(x: top.x, y: top.y + s * 0.5))
                c.stroke(tether, with: .color(Color(white: 0.85).opacity(0.6)), lineWidth: 0.6)
                SeasonArt.redLantern(&c, top: top, size: s * (0.48 - Double(k) * 0.08), glowing: 0.4 + 0.5 * night)
            }
        case .independenceDay:
            SeasonArt.flag(&c, base: base, size: s * 0.95, wave: sin(phase * 0.8))
            SeasonArt.star(&c, at: CGPoint(x: base.x + s * 0.7, y: base.y - s * 0.14), size: s * 0.26,
                           color: SeasonArt.paint(0.98, 0.92, 0.75))
        case .groundhogDay:
            SeasonArt.groundhog(&c, at: CGPoint(x: base.x, y: base.y - s * 0.16), size: s, ground: sand,
                                peek: 0.75 + 0.25 * sin(phase * 0.4))
        case .pride:
            // A rainbow of six flags staked in the sand.
            for (k, color) in SeasonArt.rainbow.enumerated() {
                let x = base.x - s * 0.5 + Double(k) * s * 0.2
                var stake = Path()
                stake.move(to: CGPoint(x: x, y: base.y))
                stake.addLine(to: CGPoint(x: x, y: base.y - s * 0.62))
                c.stroke(stake, with: .color(Color(white: 0.8)), lineWidth: 0.7)
                let flag = Path(roundedRect: CGRect(x: x, y: base.y - s * 0.62, width: s * 0.17, height: s * 0.13),
                                cornerSize: CGSize(width: s * 0.02, height: s * 0.02))
                c.fill(flag, with: .color(color))
            }
        default:
            centerpiece(&c, occasion, base: base, size: s, phase: phase, ground: sand)
        }
    }

    // MARK: Accent

    /// The small mark beside the Utilities & Toys header and in the
    /// holiday list: the set's one motif, `s` tall, centred.
    static func accent(_ c: inout Context, _ holiday: SeasonalHoliday, at p: CGPoint, size s: Double, day: Int = 3) {
        switch holiday {
        case .halloween: SeasonArt.pumpkin(&c, at: CGPoint(x: p.x, y: p.y + s * 0.06), size: s * 0.72, carved: true, glow: 0.4)
        case .diaDeMuertos: SeasonArt.marigold(&c, at: p, size: s * 0.86)
        case .thanksgiving:
            SeasonArt.leaf(&c, at: p, size: s * 0.9, angle: 0.5, color: SeasonArt.paint(0.9, 0.42, 0.12))
        case .hanukkah: SeasonArt.menorah(&c, at: CGPoint(x: p.x, y: p.y), size: s * 0.8, nights: day)
        case .christmas: SeasonArt.tree(&c, at: p, size: s * 0.92)
        case .kwanzaa: SeasonArt.kinara(&c, at: p, size: s * 0.8, days: day)
        case .newYear: SeasonArt.partyPopper(&c, at: p, size: s * 0.8)
        case .lunarNewYear: SeasonArt.redLantern(&c, top: CGPoint(x: p.x, y: p.y - s * 0.46), size: s * 0.82, glowing: 0.3)
        case .ramadanEid:
            SeasonArt.crescent(&c, at: CGPoint(x: p.x - s * 0.06, y: p.y), size: s * 0.7)
            SeasonArt.star(&c, at: CGPoint(x: p.x + s * 0.26, y: p.y - s * 0.12), size: s * 0.24, color: SeasonArt.gold)
        case .valentines: SeasonArt.heart(&c, at: p, size: s * 0.8, color: SeasonArt.paint(0.92, 0.2, 0.36))
        case .stPatricks: SeasonArt.shamrock(&c, at: CGPoint(x: p.x, y: p.y - s * 0.08), size: s * 0.9)
        case .easter:
            SeasonArt.egg(&c, at: p, size: s * 0.8, color: SeasonArt.paint(0.7, 0.86, 1),
                          band: SeasonArt.paint(0.9, 0.5, 0.6), tilt: 0.2)
        case .earthDay: SeasonArt.globe(&c, at: CGPoint(x: p.x, y: p.y + s * 0.04), size: s * 0.82)
        case .pride: SeasonArt.rainbowArc(&c, at: CGPoint(x: p.x, y: p.y - s * 0.02), size: s * 0.9)
        case .independenceDay: SeasonArt.rosette(&c, at: CGPoint(x: p.x, y: p.y - s * 0.2), size: s * 0.9)
        case .groundhogDay:
            SeasonArt.groundhog(&c, at: CGPoint(x: p.x, y: p.y + s * 0.06), size: s * 0.8,
                                ground: SeasonArt.paint(0.55, 0.42, 0.3))
        case .birthday: SeasonArt.cake(&c, at: CGPoint(x: p.x, y: p.y + s * 0.02), size: s * 0.82, candles: 1)
        }
    }
}
