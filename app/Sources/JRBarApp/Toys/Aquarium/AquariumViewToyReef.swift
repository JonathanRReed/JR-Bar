import AppKit
import JRBarCore
import SwiftUI

/// The Toy reef back wall (shop › Toy reef): a painted stage set that
/// changes as the tank climbs — flat, saturated shapes with a dark ink
/// edge, like a toy's cardboard backdrop rather than distant water. It
/// has four acts, one for every three tank levels: a bubble cave, pink
/// ruins, a coral city whose windows light up at night, and a star
/// cavern. Everything bakes on the far still pass; the lights (the
/// city's windows, the cavern's crystals) draw after the night wash so
/// they glow through it.
extension AquariumView {
    /// Which act the wall is on: levels 0–2, 3–5, 6–8, and 9.
    static func toyReefAct(level: Int) -> Int {
        min(3, max(0, level / 3))
    }

    var toyReefAct: Int { Self.toyReefAct(level: game?.tankLevel ?? 0) }

    /// The painted wall, in the band between the surface light and the
    /// far bank.
    func drawToyReef(canvas: inout GraphicsContext, size: CGSize) {
        switch toyReefAct {
        case 0: drawBubbleCave(canvas: &canvas, size: size)
        case 1: drawPinkRuins(canvas: &canvas, size: size)
        case 2: drawCoralCity(canvas: &canvas, size: size)
        default: drawStarCavern(canvas: &canvas, size: size)
        }
    }

    /// What shines on the wall, drawn after the night wash: the coral
    /// city's windows and the cavern's crystals, brighter as the night
    /// deepens. The first two acts have no lights of their own.
    func drawToyReefLights(canvas: inout GraphicsContext, size: CGSize, t: Double) {
        guard backdropKey == "toyreef", size.height >= 8, size.width > 0 else { return }
        let night = nightFactor(t: t)
        switch toyReefAct {
        case 2:
            let glow = 0.25 + 0.75 * night
            for window in coralCityWindows(in: size) {
                TankPaint.glow(&canvas, at: window.center, radius: window.r * 3.2,
                               color: Color(red: 1.0, green: 0.84, blue: 0.40).opacity(0.55 * glow))
            }
        case 3:
            let glow = 0.55 + 0.45 * night
            for crystal in starCavernCrystals(in: size) {
                TankPaint.glow(&canvas, at: crystal.tip, radius: crystal.h * 0.9,
                               color: crystal.color.opacity(0.45 * glow))
            }
        default:
            break
        }
    }

    // MARK: Paint

    /// A painted piece: a flat fill nudged a little toward the water so
    /// it stays behind the fish, a lighter band along its top edge and
    /// a dark ink outline.
    private func paintPainted(_ shape: Path, canvas: inout GraphicsContext, size: CGSize,
                              fill: TankPaint.RGB, ink: Double = 1, sink: Double = 0.18) {
        let water = waterRGB(at: 0.62)
        // A hazy theme sinks the set further into its water; Arcade's
        // clear water keeps the paint loud.
        let body = TankPaint.mix(fill, water, sink * (0.4 + 0.6 * self.water.style.haze))
        let top = TankPaint.mix(body, TankPaint.RGB(1, 1, 1), 0.28)
        let edge = TankPaint.mix(body, TankPaint.RGB(0.06, 0.04, 0.12), 0.72)
        canvas.fill(shape, with: .color(TankPaint.color(top)))
        var inner = canvas
        inner.clip(to: shape)
        inner.fill(shape.offsetBy(dx: 0, dy: 3), with: .color(TankPaint.color(body)))
        canvas.stroke(shape, with: .color(TankPaint.color(edge, 0.85)),
                      style: StrokeStyle(lineWidth: 1.6 * ink, lineJoin: .round))
    }

    /// The painted paths, built once per window size and act.
    private static var toyReefPaths: [String: Path] = [:]
    /// Room for the busiest act (about twenty paths) at three sizes at
    /// once — the window, a wallpaper and a screensaver — so one never
    /// empties the cache under another every two seconds.
    private static let toyReefPathLimit = 64

    private func reefPath(_ name: String, _ size: CGSize, build: () -> Path) -> Path {
        let key = "\(name)-\(toyReefAct)-\(Int(size.width))x\(Int(size.height))"
        if let hit = Self.toyReefPaths[key] { return hit }
        if Self.toyReefPaths.count >= Self.toyReefPathLimit {
            Self.toyReefPaths.removeAll(keepingCapacity: true)
        }
        let path = build()
        Self.toyReefPaths[key] = path
        return path
    }

    /// A lumpy line of rounded heads along `base` (fractions of height),
    /// closed down past the floor — the painted sets' back ridge.
    private func lumpRidge(in size: CGSize, base: Double, lump: Double, seed: UInt64) -> Path {
        var rng = TankPaint.Seeded(seed)
        var ridge = Path(CGRect(x: -4, y: size.height * base, width: size.width + 8,
                                height: size.height * (1 - base) + 4))
        var x = -10.0
        while x < size.width + 10 {
            let r = size.height * lump * rng.next(0.6, 1.3)
            ridge = ridge.union(Path(ellipseIn: CGRect(x: x - r, y: size.height * base - r * 0.7,
                                                       width: r * 2, height: r * 2)))
            x += r * rng.next(1.1, 1.7)
        }
        return ridge
    }

    // MARK: Act 1 — the bubble cave

    private func drawBubbleCave(canvas: inout GraphicsContext, size: CGSize) {
        let w = size.width, h = size.height
        let ridge = reefPath("cave-ridge", size) { lumpRidge(in: size, base: 0.74, lump: 0.045, seed: 3) }
        paintPainted(ridge, canvas: &canvas, size: size, fill: TankPaint.RGB(0.26, 0.54, 0.76))
        // The arch: a rounded rock with a cave right through it, left of
        // centre, standing on the far bank.
        let arch = reefPath("cave-arch", size) {
            var mass = Path(roundedRect: CGRect(x: w * 0.20, y: h * 0.60, width: w * 0.19, height: h * 0.34),
                            cornerRadius: h * 0.10)
            mass = mass.union(Path(ellipseIn: CGRect(x: w * 0.18, y: h * 0.66, width: w * 0.07, height: h * 0.14)))
            mass = mass.union(Path(ellipseIn: CGRect(x: w * 0.34, y: h * 0.64, width: w * 0.07, height: h * 0.13)))
            let hole = Path(ellipseIn: CGRect(x: w * 0.255, y: h * 0.71, width: w * 0.08, height: h * 0.24))
            return mass.subtracting(hole)
        }
        paintPainted(arch, canvas: &canvas, size: size, fill: TankPaint.RGB(0.34, 0.40, 0.72))
        shadeArch(arch, canvas: &canvas, size: size)
        // Bubble coral: clusters of glossy round heads, each its own
        // bubble, coral pink and orange.
        let clusters: [(x: Double, y: Double, s: Double, rgb: TankPaint.RGB)] = [
            (0.54, 0.80, 1.0, TankPaint.RGB(1.0, 0.46, 0.56)),
            (0.64, 0.82, 0.8, TankPaint.RGB(1.0, 0.62, 0.22)),
            (0.09, 0.82, 0.8, TankPaint.RGB(1.0, 0.62, 0.22)),
            (0.47, 0.84, 0.6, TankPaint.RGB(0.98, 0.40, 0.72)),
        ]
        for (i, cluster) in clusters.enumerated() {
            drawBubbleCoral(canvas: &canvas, size: size,
                            center: CGPoint(x: w * cluster.x, y: h * cluster.y),
                            unit: h * 0.018 * cluster.s, seed: UInt64(11 + i), fill: cluster.rgb)
        }
        // Ribbon weed on the right: tall wavy strips.
        for i in 0..<5 {
            let weed = reefPath("cave-weed-\(i)", size) {
                ribbon(root: CGPoint(x: w * (0.78 + Double(i) * 0.04), y: h * 0.90),
                       height: h * (0.20 + 0.05 * Double(i % 3)), width: h * 0.014, seed: UInt64(40 + i))
            }
            paintPainted(weed, canvas: &canvas, size: size,
                         fill: i.isMultiple(of: 2) ? TankPaint.RGB(0.36, 0.82, 0.40) : TankPaint.RGB(0.20, 0.68, 0.46))
        }
    }

    /// The arch's toy shading: a hard shadow along its foot, the cave's
    /// depth as a dark rim round the hole, and a few light lumps on its
    /// crown, so it reads as a rock rather than a flat cut-out.
    private func shadeArch(_ arch: Path, canvas: inout GraphicsContext, size: CGSize) {
        let w = size.width, h = size.height
        var inside = canvas
        inside.clip(to: arch)
        let shade = TankPaint.color(TankPaint.RGB(0.14, 0.12, 0.40), 0.5)
        var foot = Path()
        foot.move(to: CGPoint(x: w * 0.16, y: h * 0.85))
        foot.addQuadCurve(to: CGPoint(x: w * 0.43, y: h * 0.80), control: CGPoint(x: w * 0.30, y: h * 0.90))
        foot.addLine(to: CGPoint(x: w * 0.43, y: h))
        foot.addLine(to: CGPoint(x: w * 0.16, y: h))
        foot.closeSubpath()
        inside.fill(foot, with: .color(shade))
        let hole = Path(ellipseIn: CGRect(x: w * 0.255, y: h * 0.71, width: w * 0.08, height: h * 0.24))
        inside.stroke(hole, with: .color(shade), lineWidth: h * 0.04)
        let lumps: [(x: Double, y: Double, r: Double)] = [(0.235, 0.64, 0.028), (0.29, 0.625, 0.02),
                                                          (0.345, 0.66, 0.018), (0.205, 0.70, 0.014)]
        for lump in lumps {
            let r = h * lump.r
            let rect = CGRect(x: w * lump.x - r, y: h * lump.y - r * 0.7, width: r * 2, height: r * 1.4)
            inside.fill(Path(ellipseIn: rect), with: .color(.white.opacity(0.24)))
        }
    }

    /// One bubble-coral head: a mound of separate round bubbles, back
    /// ones first, each with an ink edge and a glint.
    private func drawBubbleCoral(canvas: inout GraphicsContext, size: CGSize, center c: CGPoint,
                                 unit: Double, seed: UInt64, fill: TankPaint.RGB) {
        var rng = TankPaint.Seeded(seed)
        var bubbles: [(p: CGPoint, r: Double)] = []
        for k in 0..<11 {
            let row = Double(k % 3)
            let r = unit * rng.next(0.8, 1.25) * (1 - row * 0.12)
            let x = c.x + rng.next(-2.4, 2.4) * unit * (1 - row * 0.25)
            let y = c.y - row * unit * 1.3 - rng.next(0, 0.6) * unit
            bubbles.append((CGPoint(x: x, y: y), r))
        }
        bubbles.sort { $0.p.y < $1.p.y }
        let water = waterRGB(at: 0.62)
        let body = TankPaint.mix(fill, water, 0.12 * (0.4 + 0.6 * self.water.style.haze))
        let edge = TankPaint.mix(body, TankPaint.RGB(0.08, 0.03, 0.10), 0.68)
        for bubble in bubbles {
            let rect = CGRect(x: bubble.p.x - bubble.r, y: bubble.p.y - bubble.r,
                              width: bubble.r * 2, height: bubble.r * 2)
            canvas.fill(Path(ellipseIn: rect), with: .radialGradient(
                Gradient(colors: [TankPaint.color(TankPaint.mix(body, TankPaint.RGB(1, 1, 1), 0.35)),
                                  TankPaint.color(body)]),
                center: CGPoint(x: rect.midX - bubble.r * 0.3, y: rect.midY - bubble.r * 0.35),
                startRadius: 0, endRadius: bubble.r * 1.1))
            canvas.stroke(Path(ellipseIn: rect), with: .color(TankPaint.color(edge, 0.85)), lineWidth: 1.2)
            canvas.fill(Path(ellipseIn: CGRect(x: rect.midX - bubble.r * 0.55, y: rect.midY - bubble.r * 0.6,
                                               width: bubble.r * 0.45, height: bubble.r * 0.32)),
                        with: .color(.white.opacity(0.8)))
        }
    }

    /// A ribbon of weed from `root`, swaying in a fixed S.
    private func ribbon(root: CGPoint, height: Double, width: Double, seed: UInt64) -> Path {
        var rng = TankPaint.Seeded(seed)
        let phase = rng.next(0, .pi * 2)
        var left: [CGPoint] = []
        var right: [CGPoint] = []
        let steps = 14
        for k in 0...steps {
            let f = Double(k) / Double(steps)
            let x = root.x + sin(f * .pi * 2.2 + phase) * width * 2.6
            let y = root.y - f * height
            let half = width * (1 - f * 0.55)
            left.append(CGPoint(x: x - half, y: y))
            right.append(CGPoint(x: x + half, y: y))
        }
        var p = Path()
        p.move(to: left[0])
        for point in left.dropFirst() { p.addLine(to: point) }
        for point in right.reversed() { p.addLine(to: point) }
        p.closeSubpath()
        return p
    }

    // MARK: Act 2 — pink ruins

    private func drawPinkRuins(canvas: inout GraphicsContext, size: CGSize) {
        let w = size.width, h = size.height
        // The rose wash on the back wall.
        canvas.fill(Path(CGRect(x: 0, y: h * 0.36, width: w, height: h * 0.64)), with: .linearGradient(
            Gradient(colors: [TankPaint.color(TankPaint.RGB(1.0, 0.60, 0.74), 0), TankPaint.color(TankPaint.RGB(1.0, 0.60, 0.74), 0.42)]),
            startPoint: CGPoint(x: 0, y: h * 0.36), endPoint: CGPoint(x: 0, y: h * 0.80)))
        let ridge = reefPath("ruins-ridge", size) { lumpRidge(in: size, base: 0.76, lump: 0.04, seed: 5) }
        paintPainted(ridge, canvas: &canvas, size: size, fill: TankPaint.RGB(0.86, 0.46, 0.60))
        // Three stubby fluted columns, the middle one broken off.
        let columns: [(x: Double, top: Double, broken: Bool)] = [(0.20, 0.63, false), (0.47, 0.70, true), (0.84, 0.61, false)]
        for (i, column) in columns.enumerated() {
            let shape = reefPath("ruins-column-\(i)", size) {
                fluteColumn(x: w * column.x, top: h * column.top, foot: h * 0.88,
                            width: h * 0.062, broken: column.broken)
            }
            paintPainted(shape, canvas: &canvas, size: size, fill: TankPaint.RGB(0.99, 0.88, 0.86))
            // The flutes: a few dark grooves down the shaft.
            var flutes = Path()
            let colW = h * 0.062
            for k in 1..<4 {
                let fx = w * column.x - colW / 2 + colW * Double(k) / 4
                flutes.move(to: CGPoint(x: fx, y: h * column.top + h * 0.04))
                flutes.addLine(to: CGPoint(x: fx, y: h * 0.86))
            }
            var grooves = canvas
            grooves.clip(to: shape)
            grooves.stroke(flutes, with: .color(TankPaint.color(TankPaint.RGB(0.70, 0.42, 0.50), 0.55)), lineWidth: 1.4)
        }
        // A giant clam, open, with a pearl.
        let clam = reefPath("ruins-clam", size) {
            scallop(center: CGPoint(x: w * 0.66, y: h * 0.84), width: h * 0.16, height: h * 0.09)
        }
        paintPainted(clam, canvas: &canvas, size: size, fill: TankPaint.RGB(0.96, 0.66, 0.78))
        let pearl = CGPoint(x: w * 0.66, y: h * 0.828)
        let r = h * 0.015
        canvas.fill(Path(ellipseIn: CGRect(x: pearl.x - r, y: pearl.y - r, width: r * 2, height: r * 2)),
                    with: .radialGradient(Gradient(colors: [.white, Color(red: 0.95, green: 0.88, blue: 0.92)]),
                                          center: CGPoint(x: pearl.x - r * 0.3, y: pearl.y - r * 0.3),
                                          startRadius: 0, endRadius: r))
        drawSparkle(canvas: &canvas, at: CGPoint(x: pearl.x - r * 0.4, y: pearl.y - r * 0.5),
                    size: r * 1.6, alpha: 0.9, color: .white)
    }

    /// A fluted column with a capital and a base; a broken one ends in
    /// a jagged snap instead of a capital.
    private func fluteColumn(x: Double, top: Double, foot: Double, width: Double, broken: Bool) -> Path {
        var p = Path(roundedRect: CGRect(x: x - width / 2, y: top + width * 0.3, width: width,
                                         height: foot - top - width * 0.3), cornerRadius: width * 0.12)
        p = p.union(Path(roundedRect: CGRect(x: x - width * 0.72, y: foot - width * 0.34,
                                             width: width * 1.44, height: width * 0.40), cornerRadius: width * 0.1))
        if broken {
            var snap = Path()
            snap.move(to: CGPoint(x: x - width, y: top - width))
            snap.addLine(to: CGPoint(x: x + width, y: top - width))
            snap.addLine(to: CGPoint(x: x + width, y: top + width * 0.55))
            snap.addLine(to: CGPoint(x: x + width * 0.2, y: top + width * 0.25))
            snap.addLine(to: CGPoint(x: x - width * 0.15, y: top + width * 0.7))
            snap.addLine(to: CGPoint(x: x - width, y: top + width * 0.35))
            snap.closeSubpath()
            return p.subtracting(snap)
        }
        return p.union(Path(roundedRect: CGRect(x: x - width * 0.75, y: top, width: width * 1.5,
                                                height: width * 0.36), cornerRadius: width * 0.12))
    }

    /// A scallop shell's open halves: a fanned upper shell over a
    /// shallow lower one.
    private func scallop(center c: CGPoint, width: Double, height: Double) -> Path {
        var upper = Path()
        upper.move(to: CGPoint(x: c.x - width / 2, y: c.y))
        let lobes = 5
        for k in 0..<lobes {
            let a0 = Double(k) / Double(lobes), a1 = Double(k + 1) / Double(lobes)
            let p1 = CGPoint(x: c.x - width / 2 + width * a1, y: c.y - height * sin(.pi * a1) * 0.9)
            let ctl = CGPoint(x: c.x - width / 2 + width * (a0 + a1) / 2,
                              y: c.y - height * sin(.pi * (a0 + a1) / 2) * 1.12)
            upper.addQuadCurve(to: p1, control: ctl)
        }
        upper.addLine(to: CGPoint(x: c.x + width / 2, y: c.y))
        upper.closeSubpath()
        let lower = Path(ellipseIn: CGRect(x: c.x - width / 2, y: c.y - height * 0.15,
                                           width: width, height: height * 0.5))
        return upper.union(lower)
    }

    // MARK: Act 3 — the coral city

    /// The city's towers: x, width and a stack of storeys (height and
    /// colour), all fractions of the tank.
    private var coralCityTowers: [(x: Double, w: Double, storeys: [(h: Double, rgb: TankPaint.RGB)])] {
        let orange = TankPaint.RGB(1.0, 0.56, 0.30), magenta = TankPaint.RGB(0.92, 0.36, 0.66)
        let teal = TankPaint.RGB(0.22, 0.74, 0.74), yellow = TankPaint.RGB(1.0, 0.82, 0.30)
        let violet = TankPaint.RGB(0.60, 0.46, 0.92)
        return [
            (0.09, 0.06, [(0.07, teal), (0.06, orange), (0.045, magenta)]),
            (0.22, 0.075, [(0.08, magenta), (0.07, yellow), (0.06, teal), (0.045, orange)]),
            (0.36, 0.05, [(0.065, orange), (0.05, violet)]),
            (0.57, 0.085, [(0.075, yellow), (0.07, magenta), (0.06, teal)]),
            (0.72, 0.06, [(0.07, violet), (0.06, orange), (0.05, yellow), (0.04, magenta)]),
            (0.88, 0.07, [(0.08, teal), (0.065, magenta)]),
        ]
    }

    /// One storey's box, stacked from the city's floor line.
    private func coralCityStoreys(in size: CGSize) -> [(rect: CGRect, rgb: TankPaint.RGB, tower: Int)] {
        let floor = size.height * 0.88
        var out: [(rect: CGRect, rgb: TankPaint.RGB, tower: Int)] = []
        for (i, tower) in coralCityTowers.enumerated() {
            var y = floor
            for (k, storey) in tower.storeys.enumerated() {
                let taper = 1 - Double(k) * 0.12
                let width = size.width * tower.w * taper
                let height = size.height * storey.h
                y -= height
                out.append((CGRect(x: size.width * tower.x - width / 2, y: y, width: width, height: height + 2),
                            storey.rgb, i))
            }
        }
        return out
    }

    /// The round windows, three to a storey where they fit.
    private func coralCityWindows(in size: CGSize) -> [(center: CGPoint, r: Double)] {
        var out: [(center: CGPoint, r: Double)] = []
        for storey in coralCityStoreys(in: size) {
            let r = min(storey.rect.width * 0.07, storey.rect.height * 0.14)
            guard r > 1.0 else { continue }
            let count = storey.rect.width > r * 12 ? 4 : 3
            for k in 0..<count {
                let fx = storey.rect.minX + storey.rect.width * Double(k + 1) / Double(count + 1)
                out.append((CGPoint(x: fx, y: storey.rect.midY), r))
            }
        }
        return out
    }

    private func drawCoralCity(canvas: inout GraphicsContext, size: CGSize) {
        let ridge = reefPath("city-ridge", size) { lumpRidge(in: size, base: 0.80, lump: 0.035, seed: 9) }
        paintPainted(ridge, canvas: &canvas, size: size, fill: TankPaint.RGB(0.30, 0.56, 0.78))
        let storeys = coralCityStoreys(in: size)
        for (i, storey) in storeys.enumerated() {
            // The top storey of each tower wears a round dome.
            let isTop = i + 1 == storeys.count || storeys[i + 1].tower != storey.tower
            let shape = reefPath("city-storey-\(i)", size) {
                var box = Path(roundedRect: storey.rect,
                               cornerRadius: min(storey.rect.width, storey.rect.height) * 0.22)
                if isTop {
                    let d = storey.rect.width * 0.62
                    box = box.union(Path(ellipseIn: CGRect(x: storey.rect.midX - d / 2, y: storey.rect.minY - d * 0.42,
                                                           width: d, height: d * 0.84)))
                }
                return box
            }
            paintPainted(shape, canvas: &canvas, size: size, fill: storey.rgb)
        }
        // The windows: dark by day, a warm pane that the light pass
        // makes glow at night.
        var panes = Path()
        var rims = Path()
        for window in coralCityWindows(in: size) {
            let rect = CGRect(x: window.center.x - window.r, y: window.center.y - window.r,
                              width: window.r * 2, height: window.r * 2)
            panes.addEllipse(in: rect)
            rims.addEllipse(in: rect)
        }
        canvas.fill(panes, with: .color(Color(red: 1.0, green: 0.86, blue: 0.48)))
        canvas.stroke(rims, with: .color(Color(red: 0.24, green: 0.12, blue: 0.20).opacity(0.8)), lineWidth: 1.2)
    }

    // MARK: Act 4 — the star cavern

    /// The cavern's crystal clusters: where each spike stands, how tall,
    /// its lean and its colour.
    private func starCavernCrystals(in size: CGSize) -> [(tip: CGPoint, base: CGPoint, h: Double, color: Color)] {
        let clusters: [(x: Double, y: Double, s: Double)] = [(0.14, 0.82, 1.0), (0.41, 0.84, 0.7),
                                                             (0.63, 0.80, 1.2), (0.90, 0.83, 0.8)]
        let colors = [Color(red: 0.45, green: 0.95, blue: 1.0), Color(red: 0.95, green: 0.55, blue: 1.0),
                      Color(red: 0.70, green: 0.75, blue: 1.0)]
        var out: [(tip: CGPoint, base: CGPoint, h: Double, color: Color)] = []
        for (i, cluster) in clusters.enumerated() {
            var rng = TankPaint.Seeded(UInt64(70 + i))
            for k in 0..<5 {
                let lean = rng.next(-0.45, 0.45)
                let height = size.height * 0.09 * cluster.s * rng.next(0.55, 1.1)
                let base = CGPoint(x: size.width * cluster.x + rng.next(-1, 1) * size.height * 0.03,
                                   y: size.height * cluster.y)
                let tip = CGPoint(x: base.x + sin(lean) * height, y: base.y - cos(lean) * height)
                out.append((tip, base, height, colors[(i + k) % colors.count]))
            }
        }
        return out
    }

    private func drawStarCavern(canvas: inout GraphicsContext, size: CGSize) {
        let w = size.width, h = size.height
        // The cavern is the one dark act: a violet dusk over the wall's
        // band, whatever the water above.
        canvas.fill(Path(CGRect(x: 0, y: h * 0.30, width: w, height: h * 0.70)), with: .linearGradient(
            Gradient(colors: [TankPaint.color(TankPaint.RGB(0.12, 0.06, 0.26), 0),
                              TankPaint.color(TankPaint.RGB(0.12, 0.06, 0.26), 0.70)]),
            startPoint: CGPoint(x: 0, y: h * 0.30), endPoint: CGPoint(x: 0, y: h * 0.70)))
        // Star specks in the dusk.
        var rng = TankPaint.Seeded(0x57A2)
        for _ in 0..<26 {
            let p = CGPoint(x: rng.next(0, w), y: rng.next(h * 0.40, h * 0.68))
            drawSparkle(canvas: &canvas, at: p, size: rng.next(2.0, 4.5), alpha: rng.next(0.5, 0.95),
                        color: Color(red: 1.0, green: 0.96, blue: 0.80))
        }
        // Violet rock, jagged along its top.
        let rock = reefPath("cavern-rock", size) {
            var r = TankPaint.Seeded(0xCA7E)
            var p = Path()
            p.move(to: CGPoint(x: -4, y: h + 4))
            var x = -4.0
            while x < w + 4 {
                p.addLine(to: CGPoint(x: x, y: h * r.next(0.66, 0.76)))
                x += h * r.next(0.03, 0.07)
            }
            p.addLine(to: CGPoint(x: w + 4, y: h * 0.72))
            p.addLine(to: CGPoint(x: w + 4, y: h + 4))
            p.closeSubpath()
            return p
        }
        paintPainted(rock, canvas: &canvas, size: size, fill: TankPaint.RGB(0.36, 0.22, 0.58), sink: 0.05)
        // The crystals: tall faceted spikes, lit on one face.
        for crystal in starCavernCrystals(in: size) {
            let half = crystal.h * 0.16
            let dx = crystal.tip.x - crystal.base.x, dy = crystal.tip.y - crystal.base.y
            let len = max(1, (dx * dx + dy * dy).squareRoot())
            let nx = -dy / len * half, ny = dx / len * half
            var spike = Path()
            spike.move(to: CGPoint(x: crystal.base.x - nx, y: crystal.base.y - ny))
            spike.addLine(to: CGPoint(x: crystal.base.x - nx + dx * 0.8, y: crystal.base.y - ny + dy * 0.8))
            spike.addLine(to: crystal.tip)
            spike.addLine(to: CGPoint(x: crystal.base.x + nx + dx * 0.8, y: crystal.base.y + ny + dy * 0.8))
            spike.addLine(to: CGPoint(x: crystal.base.x + nx, y: crystal.base.y + ny))
            spike.closeSubpath()
            canvas.fill(spike, with: .linearGradient(
                Gradient(colors: [crystal.color, crystal.color.opacity(0.55)]),
                startPoint: crystal.tip, endPoint: crystal.base))
            var face = Path()
            face.move(to: CGPoint(x: crystal.base.x - nx * 0.2, y: crystal.base.y - ny * 0.2))
            face.addLine(to: crystal.tip)
            face.addLine(to: CGPoint(x: crystal.base.x + nx, y: crystal.base.y + ny))
            face.closeSubpath()
            canvas.fill(face, with: .color(.white.opacity(0.28)))
            canvas.stroke(spike, with: .color(Color(red: 0.10, green: 0.04, blue: 0.22).opacity(0.8)),
                          style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
        }
    }
}
