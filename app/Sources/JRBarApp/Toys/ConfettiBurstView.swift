import AppKit
import JRBarCore
import JRBarUI
import os
import SwiftUI

/// What the burst looks like on one screen: the pop at the notch's lip
/// (or the icon, or the corners), then every piece of `ConfettiBurst`
/// drawn where the burst puts it — a paper plane tumbling in 3D, lit
/// from the upper left, its back a deeper shade of its front, a far
/// layer smaller and hazier underneath. Or, under Reduce Motion, one
/// soft glow at the lip and nothing else. One Canvas at up to 60 fps.
/// A piece's frame evaluates its position and fills a shape built once,
/// in a colour mixed once when the burst fired, and its glyphs are set
/// as type once a burst (`ConfettiMarks`). Only the pop (for its first
/// third of a second), the Reduce Motion glow and Rain's clip build a
/// shape in a frame.
struct ConfettiView: View {
    let burst: ConfettiBurst
    let look: ConfettiLook
    /// Reduce Motion: a glow at the lip, not a burst.
    let flash: Bool
    /// Rest: which ledges have moved or closed since the burst fired.
    var ledges: ConfettiLedgeWatch?
    /// Where each frame's drawing time goes, for the card's cost line.
    var meter: ConfettiDrawMeter?
    /// The burst's glyphs, kept once they're set as type; nil (a render
    /// proof's single frame) sets them for the frame.
    var marks: ConfettiMarks?
    /// Draw the screen at this size, its top middle centred in the canvas
    /// (the card's preview); nil draws it full size, or shrunk to fit a
    /// narrower canvas.
    var scale: Double?
    /// Render proofs and tests freeze the burst at this many seconds.
    var frozen: TimeInterval?

    /// The Reduce Motion glow's length.
    static let flashLife: TimeInterval = 0.9

    /// When the burst started; set on appear so `t = 0` is the pop.
    @ViewState private var origin = Date()

    var body: some View {
        if let frozen {
            Canvas { canvas, size in draw(&canvas, size: size, time: frozen) }
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 60)) { context in
                Canvas { canvas, size in
                    let time = context.date.timeIntervalSince(origin)
                    if let meter {
                        meter.measure { draw(&canvas, size: size, time: time) }
                    } else {
                        draw(&canvas, size: size, time: time)
                    }
                }
            }
            .onAppear { origin = Date() }
        }
    }

    /// One frame, `time` seconds after the pop. A canvas narrower than the
    /// burst's screen (the card's preview) draws the whole screen scaled
    /// to fit.
    func draw(_ canvas: inout GraphicsContext, size: CGSize, time: Double) {
        if let scale {
            canvas.translateBy(x: size.width / 2 - burst.stage.width / 2 * scale, y: 0)
            canvas.scaleBy(x: scale, y: scale)
        } else {
            let fit = min(1, size.width / max(1, burst.stage.width))
            if fit < 0.999 { canvas.scaleBy(x: fit, y: fit) }
        }
        let width = burst.stage.width, height = burst.stage.height
        if flash {
            drawGlow(&canvas, p: min(1, time / Self.flashLife))
            return
        }
        drawPop(&canvas, age: time, strength: 1)
        if burst.recipe.intensity == .big { drawPop(&canvas, age: time - 0.25, strength: 0.55) }
        if burst.recipe.origin == .rain {
            // Rain is born under the menu bar; a long ribbon turned on end
            // as it fades in is cut there, never laid over the bar's items.
            canvas.clip(to: Path(CGRect(x: 0, y: burst.stage.menuBarBottom, width: width,
                                        height: max(0, height - burst.stage.menuBarBottom))))
        }
        let marks = self.marks?.resolved(look.glyphs, in: canvas) ?? Self.resolve(look.glyphs, in: canvas)
        let gone = ledges?.gone ?? [:]
        for index in burst.pieces.indices {
            guard let frame = burst.frame(of: index, at: time) else { continue }
            let piece = burst.pieces[index]
            var opacity = frame.opacity * (piece.far ? 0.72 : 0.97)
            if frame.resting, let window = piece.landing?.window, let at = gone[window] {
                opacity *= max(0, 1 - (time - at) / 0.3)
            }
            guard opacity > 0.01, frame.x > -60, frame.x < width + 60,
                  frame.y > -60, frame.y < height + 60 else { continue }
            var c = canvas
            c.opacity = opacity
            c.translateBy(x: frame.x, y: frame.y)
            c.concatenate(frame.transform)
            let paper = look.paper(far: piece.far, front: frame.front, slot: piece.slot, shade: frame.shade)
            paint(piece, frame: frame, paper: paper, marks: marks, in: &c)
        }
    }

    // MARK: Pieces

    /// Every shape at size 1, built once.
    private static let unitRect = Path(CGRect(x: -0.5, y: -0.5, width: 1, height: 1))
    private static let unitDot = Path(ellipseIn: CGRect(x: -0.5, y: -0.5, width: 1, height: 1))
    private static let unitDiamond: Path = {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: -0.55))
        p.addLine(to: CGPoint(x: 0.42, y: 0))
        p.addLine(to: CGPoint(x: 0, y: 0.55))
        p.addLine(to: CGPoint(x: -0.42, y: 0))
        p.closeSubpath()
        return p
    }()
    private static let unitStar: Path = {
        var p = Path()
        for i in 0..<10 {
            let r = i % 2 == 0 ? 0.55 : 0.23
            let a = -Double.pi / 2 + Double(i) * .pi / 5
            let point = CGPoint(x: r * cos(a), y: r * sin(a))
            if i == 0 { p.move(to: point) } else { p.addLine(to: point) }
        }
        p.closeSubpath()
        return p
    }()
    private static let unitHeart: Path = {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: 0.42))
        p.addCurve(to: CGPoint(x: -0.5, y: -0.12), control1: CGPoint(x: -0.2, y: 0.25),
                   control2: CGPoint(x: -0.5, y: 0.1))
        p.addArc(center: CGPoint(x: -0.25, y: -0.18), radius: 0.25, startAngle: .degrees(180),
                 endAngle: .degrees(0), clockwise: false)
        p.addArc(center: CGPoint(x: 0.25, y: -0.18), radius: 0.25, startAngle: .degrees(180),
                 endAngle: .degrees(0), clockwise: false)
        p.addCurve(to: CGPoint(x: 0, y: 0.42), control1: CGPoint(x: 0.5, y: 0.1),
                   control2: CGPoint(x: 0.2, y: 0.25))
        p.closeSubpath()
        return p
    }()
    /// A ribbon one unit long and a tenth of a unit wide, curled and
    /// twisted: its width swells and pinches along its length the way a
    /// paper strip does as it turns, and the curl and twist run along it.
    /// Twelve steps of that ripple are built once; a frame picks one, so
    /// a streamer is one fill and no path is built per frame.
    private static let ribbons: [Path] = (0..<12).map { step in
        let shift = Double(step) / 12 * 2 * .pi
        let count = 20
        var top: [CGPoint] = []
        var bottom: [CGPoint] = []
        for i in 0...count {
            let u = Double(i) / Double(count)
            let y = 0.11 * sin(u * .pi * 2.4 + shift)
            let half = 0.05 * (0.25 + 0.75 * abs(cos(u * .pi * 1.7 + shift * 0.5)))
            top.append(CGPoint(x: -0.5 + u, y: y - half))
            bottom.append(CGPoint(x: -0.5 + u, y: y + half))
        }
        var p = Path()
        p.addLines(top + bottom.reversed())
        p.closeSubpath()
        return p
    }

    /// What a glyph fleck draws: a provider's real mark as a path in a
    /// unit square centred on the origin, filled with the paper like any
    /// other piece, or a symbol or letters set as heavy type so a thin one
    /// still reads at fleck size.
    enum Mark {
        case path(Path)
        case text(GraphicsContext.ResolvedText)
    }

    private func paint(_ piece: ConfettiBurst.Piece, frame: ConfettiBurst.Frame, paper: ConfettiLook.Paint,
                       marks: [Mark], in c: inout GraphicsContext) {
        let size = piece.size
        switch piece.shape {
        case .streamer:
            // The unit ribbon is a tenth as wide as it is long; its width
            // in points is the piece's `aspect`.
            c.scaleBy(x: size, y: piece.aspect * 10)
            c.fill(Self.ribbons[min(11, Int(frame.ripple * 12))], with: paper.shading)
            return
        case .glyph:
            guard !marks.isEmpty else {
                c.scaleBy(x: size, y: size)
                c.fill(Self.unitStar, with: paper.shading)
                return
            }
            switch marks[piece.glyph % marks.count] {
            case .path(let mark):
                c.scaleBy(x: size, y: size)
                c.fill(mark, with: paper.shading)
            case .text(var mark):
                mark.shading = paper.shading
                c.scaleBy(x: size / Self.markPoints, y: size / Self.markPoints)
                c.draw(mark, at: .zero, anchor: .center)
            }
            return
        case .rect:
            c.scaleBy(x: size, y: size * piece.aspect)
            c.fill(Self.unitRect, with: paper.shading)
            if frame.glint > 0.04 {
                c.fill(Self.unitRect, with: .color(.white.opacity(min(0.8, frame.glint))))
            }
        case .dot:
            c.scaleBy(x: size, y: size)
            c.fill(Self.unitDot, with: paper.shading)
        case .diamond:
            c.scaleBy(x: size, y: size)
            c.fill(Self.unitDiamond, with: paper.shading)
            if frame.glint > 0.04 {
                c.fill(Self.unitDiamond, with: .color(.white.opacity(min(0.8, frame.glint))))
            }
        case .star:
            c.scaleBy(x: size, y: size)
            c.fill(Self.unitStar, with: paper.shading)
        case .heart:
            c.scaleBy(x: size, y: size)
            c.fill(Self.unitHeart, with: paper.shading)
        }
    }

    /// The point size a letter mark is set at before it's scaled to its piece.
    private static let markPoints = 13.0

    /// How much of a glyph piece's size a provider's mark spans: about
    /// what the heavy type's ink covered.
    static let logoSpan: CGFloat = 0.92

    /// `glyphs` ready to draw: a mark's cached path placed in its unit
    /// square, anything else set as type in `canvas`.
    static func resolve(_ glyphs: [ConfettiLook.Glyph], in canvas: GraphicsContext) -> [Mark] {
        let font = Font.system(size: Self.markPoints, weight: .black, design: .rounded)
        let unit = CGRect(x: -logoSpan / 2, y: -logoSpan / 2, width: logoSpan, height: logoSpan)
        return glyphs.map { glyph in
            switch glyph {
            case .logo(let id):
                if let logo = ProviderLogo.named(id) { return .path(Path(logo.path(in: unit))) }
                return .text(canvas.resolve(Text(String(id.prefix(1)).uppercased()).font(font)))
            case .symbol(let name): return .text(canvas.resolve(Text(Image(systemName: name)).font(font)))
            case .text(let text): return .text(canvas.resolve(Text(text).font(font)))
            }
        }
    }

    // MARK: The pop

    /// The pop, where it can be seen: light spilling out of the notch's
    /// lower lip with a puff at each lower corner (the notch pops, in the
    /// island's own idiom); a ring around the icon; a puff at each bottom
    /// corner. Rain has no cannon, so no pop. Gone in about a third of a
    /// second, under the pieces. The notch is a hole in the screen, so
    /// the lip's glow and its bright edge sit just below it, where they
    /// show.
    private func drawPop(_ canvas: inout GraphicsContext, age: Double, strength: Double) {
        guard age >= 0, age < 0.32 else { return }
        let p = age / 0.32
        let ease = 1 - (1 - p) * (1 - p)
        let fade = (1 - p) * strength
        let stage = burst.stage
        switch ConfettiEmitter.resolved(burst.recipe.origin, on: stage) {
        case .notch:
            let lip = ConfettiEmitter.lip(of: stage)
            glow(&canvas, center: CGPoint(x: lip.midX, y: lip.minY + 4), width: lip.width + 60 * ease,
                 height: 10 + 26 * ease, opacity: 0.75 * fade)
            var edge = Path()
            edge.move(to: CGPoint(x: lip.minX + 8, y: lip.minY + 1.2))
            edge.addLine(to: CGPoint(x: lip.maxX - 8, y: lip.minY + 1.2))
            canvas.stroke(edge, with: .color(look.theme.mix(with: .white, by: 0.5).opacity(0.9 * fade)),
                          style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
            for x in [lip.minX + 4, lip.maxX - 4] {
                puff(&canvas, at: CGPoint(x: x, y: lip.minY + 2), radius: 4 + 16 * ease, opacity: fade)
            }
        case .icon:
            let icon = stage.icon ?? .zero
            let center = CGPoint(x: icon.midX, y: icon.midY)
            let r = max(icon.width, icon.height) / 2 + 2 + 20 * ease
            canvas.stroke(Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)),
                          with: .color(look.theme.opacity(0.7 * fade)), lineWidth: 1.8)
            puff(&canvas, at: CGPoint(x: icon.midX, y: icon.maxY + 2), radius: 5 + 14 * ease, opacity: fade)
        case .corners:
            for x in [0, stage.width] {
                puff(&canvas, at: CGPoint(x: x, y: stage.height), radius: 16 + 70 * ease, opacity: 0.8 * fade)
            }
        case .rain:
            break
        }
    }

    /// Reduce Motion: the lip (or the icon) glows once in the burst's
    /// colour and fades — the whole cue, nothing moving across the screen.
    private func drawGlow(_ canvas: inout GraphicsContext, p: Double) {
        guard p < 1 else { return }
        let rise = min(1, p / 0.25)
        let fade = p < 0.25 ? rise : 1 - (p - 0.25) / 0.75
        let stage = burst.stage
        if ConfettiEmitter.resolved(burst.recipe.origin, on: stage) == .icon, let icon = stage.icon {
            glow(&canvas, center: CGPoint(x: icon.midX, y: icon.maxY), width: icon.width + 70,
                 height: 34, opacity: 0.7 * fade)
            return
        }
        let lip = ConfettiEmitter.lip(of: stage)
        glow(&canvas, center: CGPoint(x: lip.midX, y: lip.minY), width: lip.width + 140 * rise,
             height: 26 + 34 * rise, opacity: 0.9 * fade)
    }

    /// A soft elliptical light, bright at its centre.
    private func glow(_ canvas: inout GraphicsContext, center: CGPoint, width: Double, height: Double,
                      opacity: Double) {
        guard opacity > 0.005 else { return }
        var c = canvas
        c.translateBy(x: center.x, y: center.y)
        c.scaleBy(x: width / 2, y: height / 2)
        let gradient = Gradient(colors: [look.theme.opacity(opacity), look.theme.opacity(opacity * 0.35),
                                         look.theme.opacity(0)])
        c.fill(Path(ellipseIn: CGRect(x: -1, y: -1, width: 2, height: 2)),
               with: .radialGradient(gradient, center: .zero, startRadius: 0, endRadius: 1))
    }

    /// A little round burst of light where a cannon fires.
    private func puff(_ canvas: inout GraphicsContext, at point: CGPoint, radius: Double, opacity: Double) {
        guard opacity > 0.005 else { return }
        let gradient = Gradient(colors: [Color.white.opacity(0.8 * opacity), look.theme.opacity(0.6 * opacity),
                                         look.theme.opacity(0)])
        canvas.fill(Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius,
                                           width: 2 * radius, height: 2 * radius)),
                    with: .radialGradient(gradient, center: point, startRadius: 0, endRadius: radius))
    }
}

/// A burst's glyphs, set as type on its first frame and drawn from then
/// on: setting type is text layout, and a burst draws a few hundred
/// frames of the same few marks. New glyphs (the card's preview after a
/// palette pick) are set again.
@MainActor
final class ConfettiMarks {
    private var glyphs: [ConfettiLook.Glyph]?
    private var marks: [ConfettiView.Mark] = []
    /// How many times the glyphs have been set, for the tests.
    private(set) var resolves = 0

    func resolved(_ glyphs: [ConfettiLook.Glyph], in canvas: GraphicsContext) -> [ConfettiView.Mark] {
        if glyphs != self.glyphs {
            self.glyphs = glyphs
            marks = ConfettiView.resolve(glyphs, in: canvas)
            resolves += 1
        }
        return marks
    }
}

/// Rest's check on the ledges its pieces lie on: which have moved or
/// closed, and when that was seen (burst seconds). The window updates it
/// once a second; a frame reads it.
@MainActor
final class ConfettiLedgeWatch {
    var gone: [Int: Double] = [:]

    /// Folds one reading of which ledges still stand in at `time`.
    func note(standing: [Bool], at time: Double) {
        for (index, stands) in standing.enumerated() where !stands && gone[index] == nil {
            gone[index] = time
        }
    }
}

/// How long the burst's frames take to draw, measured on the live path
/// (with an os_signpost interval around each, for Instruments): the
/// card's cost line quotes the last burst's p50 and p90.
@MainActor
final class ConfettiDrawMeter {
    /// One finished burst: how long it ran and what its frames cost.
    struct Summary: Equatable {
        var seconds: Double
        var frames: Int
        var p50: Double
        var p90: Double
    }

    private static let signposter = OSSignposter(subsystem: "devin.jrbar", category: "confetti")
    private var samples: [Double] = []
    private let started = ProcessInfo.processInfo.systemUptime

    init() {
        samples.reserveCapacity(600)
    }

    /// Times one frame's drawing.
    func measure(_ draw: () -> Void) {
        let state = Self.signposter.beginInterval("draw")
        let start = DispatchTime.now().uptimeNanoseconds
        draw()
        record(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        Self.signposter.endInterval("draw", state)
    }

    /// One frame's milliseconds (the tests feed these by hand).
    func record(_ milliseconds: Double) {
        if samples.count < 4_000 { samples.append(milliseconds) }
    }

    /// The burst so far, or nil before its first frame.
    func summary(at now: Double = ProcessInfo.processInfo.systemUptime) -> Summary? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        func at(_ q: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * q))] }
        return Summary(seconds: now - started, frames: sorted.count, p50: at(0.5), p90: at(0.9))
    }
}
