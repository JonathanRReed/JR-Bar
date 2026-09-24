import AppKit
import Foundation
import SwiftUI
import Testing
import JRBarCore
@testable import JRBarApp

/// Render proof for the fish turn (docs/TOYS.md §Aquarium, Swimming),
/// driven by the real steering, `layout(of:)` and `drawFish` — never
/// hand poses: every frame of a cruise U-turn for each species, onion
/// skins of a wall turn and a mid-tank change of mind, every head-on
/// frame with the wear on it, a station hold, the ask, the leave, a fry
/// orbit and a pellet chase, and thirty seconds of paths at each pace.
/// Off by default; set `JRBAR_RENDER_PROOF=1` to write `fish-turn-*.png`
/// into `JRBAR_RENDER_PROOF_DIR` (default `/tmp/jrbar-audit`).
@Suite("Aquarium turn render proof")
@MainActor
struct AquariumTurnRenderProofTests {
    private static var outputDir: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF_DIR"]
            ?? "/tmp/jrbar-audit", isDirectory: true)
    }

    private static let water = Gradient(colors: [
        Color(red: 0.20, green: 0.56, blue: 0.64),
        Color(red: 0.07, green: 0.33, blue: 0.52),
        Color(red: 0.03, green: 0.17, blue: 0.36),
    ])

    /// The tank the steering swims in.
    private static let tank = CGSize(width: 900, height: 560)
    private static let dt = 1.0 / 30
    /// The frame clock starts now: a tapped pellet is stamped with the
    /// real date, and the tank drops food older than 24 s.
    private static let t0 = Date().timeIntervalSince1970.rounded()

    private static let providers: [FishSpecies: String] = [
        .minnow: "grok", .clownfish: "claude", .angelfish: "gemini", .puffer: "antigravity",
        .shark: "codex", .seahorse: "hermes", .betta: "opencode", .tang: "devin", .tetra: "cursor",
    ]

    private static func makeFish(_ id: String, _ species: FishSpecies, state: FishState = .swimming,
                                 lane: Double = 0.3, direction: Double = 1, since: Double = t0 - 100) -> Fish {
        Fish(id: id, label: id, providerID: providers[species] ?? "claude", state: state, lane: lane,
             speed: 0.1, direction: direction, stateSince: Date(timeIntervalSince1970: since),
             enteredAt: .distantPast, species: species)
    }

    private static func sheet(width: Double, height: Double,
                              draw: @escaping (inout GraphicsContext, CGSize) -> Void) -> some View {
        Canvas { c, size in
            c.fill(Path(CGRect(origin: .zero, size: size)),
                   with: .linearGradient(water, startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            draw(&c, size)
        }
        .frame(width: width, height: height)
    }

    private static func label(_ c: inout GraphicsContext, _ text: String, at p: CGPoint, size: Double = 10) {
        c.draw(Text(text).font(.system(size: size, weight: .medium, design: .monospaced))
            .foregroundStyle(.white.opacity(0.8)), at: p, anchor: .center)
    }

    private static func write(_ view: some View, _ name: String, scale: Double = 2) throws {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            Issue.record("render failed for \(name)")
            return
        }
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        try png.write(to: outputDir.appendingPathComponent("\(name).png"))
    }

    /// A tank of full-grown fish drawn a size up, so a proof reads.
    private static func grown(_ fish: [Fish]) -> AquariumView {
        var settings = AquariumSettings()
        settings.fishScale = 1.3
        var pets: [String: FishCare] = [:]
        for f in fish where !f.isFry { pets[f.id] = FishCare(stage: 2) }
        return AquariumView(fixture: AquariumView.Fixture(fish: fish, game: AquariumGame(pets: pets),
                                                          night: 0, swimSettings: settings))
    }

    /// One recorded frame: the fish as it was then, its layout, and the
    /// frame clock.
    private struct Shot {
        var fish: Fish
        var layout: AquariumView.Layout
        var t: Double
        var progress: Double?
    }

    /// Step `tank` a frame: the steering, the layout and the bookkeeping
    /// a draw does, without drawing.
    private static func step(_ view: AquariumView, _ roster: [Fish], t: Double) -> [String: AquariumView.Layout] {
        let now = Date(timeIntervalSince1970: t)
        view.stepSwim(roster, in: tank, t: t, now: now)
        var out: [String: AquariumView.Layout] = [:]
        for fish in roster where !fish.isFry {
            let l = view.layout(of: fish, in: tank, at: t, now: now)
            view.motion.swim.record(fish, layout: l, t: t)
            out[fish.id] = l
        }
        return out
    }

    /// Draw `shot` with the tank's own fish pass, moved so its centre
    /// lands on `at` — the fish is drawn where it really was, so its
    /// tail-beat clock sees its real swim.
    private static func draw(_ view: AquariumView, _ shot: Shot, on c: inout GraphicsContext, at p: CGPoint,
                             opacity: Double = 1, parent: (fish: Fish, layout: AquariumView.Layout)? = nil) {
        var g = c
        g.translateBy(x: p.x - shot.layout.x, y: p.y - shot.layout.y)
        // The fish pass sets its own opacity from the layout's.
        var l = shot.layout
        l.opacity *= opacity
        view.drawFish(canvas: &g, size: tank, t: shot.t, now: Date(timeIntervalSince1970: shot.t),
                      fish: shot.fish, layout: l, parent: parent, showLabels: false)
    }

    /// Every frame of a cruise U-turn for `species`, from a few frames
    /// before it to a few after.
    private static func cruiseTurn(_ species: FishSpecies, arc: Double = 1)
        -> (view: AquariumView, shots: [Shot]) {
        let fish = makeFish("turn-\(species.rawValue)", species)
        // Full-grown and at the biggest Fish size, so every frame reads.
        var big = AquariumSettings()
        big.fishScale = AquariumSettings.fishScaleRange.upperBound
        let view = AquariumView(fixture: AquariumView.Fixture(
            fish: [fish], game: AquariumGame(pets: [fish.id: FishCare(stage: 2)]), night: 0,
            swimSettings: big))
        var t = t0
        _ = step(view, [fish], t: t)
        var body = view.motion.bodies[fish.id]!
        body.x = 0.5
        body.dir = 1
        body.climb = 0
        body.pitch = 0
        view.motion.bodies[fish.id] = body
        var shots: [Shot] = []
        for i in 0..<36 {
            t += dt
            if i == 4 {
                var b = view.motion.bodies[fish.id]!
                b.turn = SwimTurn(kind: .cruise, start: t, duration: 0.9, from: 1, arc: arc)
                view.motion.bodies[fish.id] = b
            }
            let l = step(view, [fish], t: t)[fish.id]!
            shots.append(Shot(fish: fish, layout: l, t: t, progress: view.motion.bodies[fish.id]!.turn?.progress))
        }
        return (view, shots)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1",
                   "set JRBAR_RENDER_PROOF=1 to write the turn proof PNGs"))
    func turnSequences() throws {
        for species in FishSpecies.allCases {
            let run = Self.cruiseTurn(species)
            // Cells sized to the fish, fins and all.
            let extent = CartoonFish.art(for: species).extent
            let length = run.view.drawnSize(of: run.shots[0].fish, layout: run.shots[0].layout).length
            let cols = 12
            let cellW = max(110, extent.width * length * 1.05)
            let cellH = max(120, extent.height * length * 1.1 + 26)
            let rows = (run.shots.count + cols - 1) / cols
            let view = Self.sheet(width: cellW * Double(cols), height: cellH * Double(rows) + 24) { c, _ in
                Self.label(&c, "\(species.displayName): every frame of a cruise U-turn at 30 fps",
                           at: CGPoint(x: cellW * Double(cols) / 2, y: 12), size: 11)
                for (i, shot) in run.shots.enumerated() {
                    let centre = CGPoint(x: cellW * (Double(i % cols) + 0.5),
                                         y: 24 + cellH * Double(i / cols)
                                            + (cellH - 26) * (-extent.minY / extent.height) * 0.95 + 4)
                    Self.draw(run.view, shot, on: &c, at: centre)
                    let p = shot.progress.map { String(format: "p %.2f", $0) } ?? "   –  "
                    Self.label(&c, "\(p) c \(String(format: "%+.2f", shot.layout.yawCos))",
                               at: CGPoint(x: centre.x, y: 24 + cellH * Double(i / cols + 1) - 10), size: 8.5)
                }
            }
            try Self.write(view, "fish-turn-sequence-\(species.rawValue)")
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1",
                   "set JRBAR_RENDER_PROOF=1 to write the turn proof PNGs"))
    func onionSkins() throws {
        // A wall turn at the right glass and a mid-tank change of mind,
        // every 0.2 s over six seconds, each skin a step lower than the
        // last so time runs down the sheet: the fish slows into the turn,
        // comes round about where it stopped and swims off the other way.
        let wallFish = Self.makeFish("onion-wall", .clownfish, lane: 0.15)
        let midFish = Self.makeFish("onion-mid", .angelfish, lane: 0.3, direction: -1)
        let view = AquariumView(fixture: AquariumView.Fixture(
            fish: [wallFish, midFish],
            game: AquariumGame(pets: [wallFish.id: FishCare(stage: 2), midFish.id: FishCare(stage: 2)]),
            night: 0))
        var t = Self.t0
        _ = Self.step(view, [wallFish, midFish], t: t)
        var wall = view.motion.bodies[wallFish.id]!
        wall.x = 0.84
        wall.dir = 1
        view.motion.bodies[wallFish.id] = wall
        var mid = view.motion.bodies[midFish.id]!
        mid.x = 0.5
        mid.dir = -1
        view.motion.bodies[midFish.id] = mid
        var wallShots: [Shot] = []
        var midShots: [Shot] = []
        var reach = 0.0
        for i in 0..<(30 * 6) {
            t += Self.dt
            if i == 60 {
                var b = view.motion.bodies[midFish.id]!
                b.turn = SwimTurn(kind: .cruise, start: t, duration: 0.9, from: -1, arc: -1)
                view.motion.bodies[midFish.id] = b
            }
            let layouts = Self.step(view, [wallFish, midFish], t: t)
            let wb = view.motion.bodies[wallFish.id]!
            reach = max(reach, wb.x + 0.55 * wb.length)
            if i % 6 == 0 {
                wallShots.append(Shot(fish: wallFish, layout: layouts[wallFish.id]!, t: t))
                midShots.append(Shot(fish: midFish, layout: layouts[midFish.id]!, t: t))
            }
        }
        let bounds = Self.tank
        let height = 880.0
        let sheet = Self.sheet(width: bounds.width, height: height) { c, _ in
            var glass = Path()
            glass.move(to: CGPoint(x: bounds.width * 0.95, y: 0))
            glass.addLine(to: CGPoint(x: bounds.width * 0.95, y: height))
            c.stroke(glass, with: .color(.white.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            Self.label(&c, String(format: "a wall turn (the nose reaches %.3f; the glass is 0.95)", reach),
                       at: CGPoint(x: bounds.width / 2, y: 14), size: 11)
            Self.label(&c, "a mid-tank change of mind", at: CGPoint(x: bounds.width / 2, y: 452), size: 11)
            for (i, shot) in wallShots.enumerated() {
                Self.draw(view, shot, on: &c, at: CGPoint(x: shot.layout.x, y: 50 + Double(i) * 12.5),
                          opacity: 0.35 + 0.65 * Double(i) / Double(wallShots.count))
            }
            for (i, shot) in midShots.enumerated() {
                Self.draw(view, shot, on: &c, at: CGPoint(x: shot.layout.x, y: 490 + Double(i) * 12.5),
                          opacity: 0.35 + 0.65 * Double(i) / Double(midShots.count))
            }
        }
        try Self.write(sheet, "fish-turn-onion")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1",
                   "set JRBAR_RENDER_PROOF=1 to write the turn proof PNGs"))
    func frontLineup() throws {
        // Every species head-on, bare, then in each piece of wear.
        let wear: [(hat: ShopItem?, accessory: ShopItem?)] = [
            (nil, nil), (.hatCrown, nil), (.hatParty, .sunglasses), (.hatBeanie, .bowTie),
            (nil, .monocle), (nil, .headphones), (nil, .topHat), (nil, .scarf), (nil, .tinyLaptop),
        ]
        let species = FishSpecies.allCases
        let cellW = 104.0, cellH = 118.0
        var cast: [Fish] = []
        var hats: [String: String] = [:]
        var accessories: [String: String] = [:]
        var pets: [String: FishCare] = [:]
        for sp in species {
            for (col, item) in wear.enumerated() {
                let id = "\(col)\(sp.rawValue)-front"
                cast.append(Self.makeFish(id, sp))
                if let hat = item.hat { hats[id] = hat.rawValue }
                if let accessory = item.accessory { accessories[id] = accessory.rawValue }
                pets[id] = FishCare(stage: 2)
            }
        }
        let game = AquariumGame(pets: pets, hats: hats, accessories: accessories)
        let view = AquariumView(fixture: AquariumView.Fixture(fish: cast, game: game, night: 0))
        let sheet = Self.sheet(width: cellW * Double(wear.count), height: cellH * Double(species.count) + 24) { c, _ in
            Self.label(&c, "head-on: bare, crown, party + shades, beanie + bow tie, monocle, headphones, top hat, scarf, laptop (hidden); the seahorse flicks round side-on",
                       at: CGPoint(x: cellW * Double(wear.count) / 2, y: 12), size: 10)
            for (row, sp) in species.enumerated() {
                for col in wear.indices {
                    let fish = cast[row * wear.count + col]
                    var l = AquariumView.Layout()
                    l.x = cellW * (Double(col) + 0.5)
                    l.y = 24 + cellH * (Double(row) + 0.5)
                    // Head-on, a hair round from dead centre.
                    l.yawCos = 0.06
                    l.scale = 1.4
                    l.wag = 0.8
                    view.drawFish(canvas: &c, size: CGSize(width: 2000, height: 5000), t: 10,
                                  now: Date(), fish: fish, layout: l, parent: nil, showLabels: false)
                }
            }
        }
        try Self.write(sheet, "fish-turn-front-lineup")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1",
                   "set JRBAR_RENDER_PROOF=1 to write the turn proof PNGs"))
    func stationHold() throws {
        // Ten seconds holding in the current: an onion every 0.2 s, and
        // the moving point it holds on.
        let fish = Self.makeFish("station", .clownfish, lane: 0.4)
        let view = Self.grown([fish])
        var t = Self.t0
        _ = Self.step(view, [fish], t: t)
        var body = view.motion.bodies[fish.id]!
        body.x = 0.45
        body.y = 0.45
        view.motion.bodies[fish.id] = body
        let anchor = AquariumStations.Anchor(x: 0.5, y: 0.45, spanX: 20 / Self.tank.width, spanY: 0.06)
        var shots: [Shot] = []
        var goals: [CGPoint] = []
        var reversals = 0
        for i in 0..<(30 * 12) {
            t += Self.dt
            let goal = AquariumStations.target(for: .current, anchor: anchor, t: t, seed: fish.seed)
            var b = view.motion.bodies[fish.id]!
            let before = b.dir
            let dist = hypot(goal.x - b.x, goal.y - b.y)
            AquariumSteering.step(&b, dt: Self.dt, t: t, seed: fish.seed,
                                  context: SwimContext(bounds: SwimBounds(minX: 0.05, minY: 30 / 560, maxX: 0.95,
                                                                          maxY: 460 / 560, margin: 0.1),
                                                       wander: 0.35, hunger: AquariumStations.seekHunger,
                                                       effort: AquariumStations.effort(for: .current, distance: dist),
                                                       station: goal))
            if b.dir != before { reversals += 1 }
            view.motion.bodies[fish.id] = b
            let l = view.layout(of: fish, in: Self.tank, at: t, now: Date(timeIntervalSince1970: t))
            view.motion.swim.record(fish, layout: l, t: t)
            if i >= 60, i % 6 == 0 {
                shots.append(Shot(fish: fish, layout: l, t: t))
                goals.append(CGPoint(x: goal.x * Self.tank.width, y: goal.y * Self.tank.height))
            }
        }
        let sheet = Self.sheet(width: 520, height: 300) { c, _ in
            Self.label(&c, "station hold (current), 10 s, every 0.2 s: \(reversals) turns", at: CGPoint(x: 260, y: 14), size: 11)
            var g = c
            g.translateBy(x: 260 - 0.5 * Self.tank.width, y: 150 - 0.45 * Self.tank.height)
            for (i, shot) in shots.enumerated() {
                Self.draw(view, shot, on: &g, at: CGPoint(x: shot.layout.x, y: shot.layout.y),
                          opacity: 0.2 + 0.8 * Double(i) / Double(shots.count))
            }
            for p in goals {
                g.fill(Path(ellipseIn: CGRect(x: p.x - 1.5, y: p.y - 1.5, width: 3, height: 3)),
                       with: .color(.yellow.opacity(0.7)))
            }
        }
        try Self.write(sheet, "fish-turn-station")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1",
                   "set JRBAR_RENDER_PROOF=1 to write the turn proof PNGs"))
    func states() throws {
        let cols = 14, cellW = 104.0, cellH = 130.0
        var rows: [(title: String, view: AquariumView, shots: [Shot], parents: [(Fish, AquariumView.Layout)?])] = []

        // An ask: rise, hold, answer, swim back down.
        do {
            var fish = Self.makeFish("ask", .shark, lane: 0.5)
            let view = Self.grown([fish])
            var t = Self.t0
            var shots: [Shot] = []
            for _ in 0..<20 { t += Self.dt; _ = Self.step(view, [fish], t: t) }
            fish.state = .surfacing
            fish.stateSince = Date(timeIntervalSince1970: t)
            for i in 0..<75 {
                t += Self.dt
                let l = Self.step(view, [fish], t: t)[fish.id]!
                if i % 10 == 0 { shots.append(Shot(fish: fish, layout: l, t: t)) }
            }
            fish.state = .swimming
            fish.stateSince = Date(timeIntervalSince1970: t)
            for i in 0..<60 {
                t += Self.dt
                let l = Self.step(view, [fish], t: t)[fish.id]!
                if i % 9 == 0 { shots.append(Shot(fish: fish, layout: l, t: t)) }
            }
            rows.append(("an ask rises, waits half-turned, is answered and swims down", view, shots,
                         Array(repeating: nil, count: shots.count)))
        }
        // A left-facing fish completes: it turns round and corkscrews out.
        do {
            var fish = Self.makeFish("leave", .clownfish, lane: 0.4, direction: -1)
            let view = Self.grown([fish])
            var t = Self.t0
            _ = Self.step(view, [fish], t: t)
            var body = view.motion.bodies[fish.id]!
            body.dir = -1
            body.x = 0.4
            view.motion.bodies[fish.id] = body
            for _ in 0..<5 { t += Self.dt; _ = Self.step(view, [fish], t: t) }
            fish.state = .leaving
            fish.stateSince = Date(timeIntervalSince1970: t)
            var shots: [Shot] = []
            for i in 0..<42 {
                t += Self.dt
                let l = Self.step(view, [fish], t: t)[fish.id]!
                if i % 3 == 0 { shots.append(Shot(fish: fish, layout: l, t: t)) }
            }
            rows.append(("completion from a left-facing fish: the turn, then out", view, shots,
                         Array(repeating: nil, count: shots.count)))
        }
        // A fry round its parent: every sixth frame of its orbit.
        do {
            let parent = Self.makeFish("parent", .clownfish, lane: 0.4)
            var fry = Self.makeFish("fry-a", .clownfish, lane: 0.4)
            fry.isFry = true
            fry.anchorID = parent.id
            let view = Self.grown([parent, fry])
            var t = Self.t0
            var shots: [Shot] = []
            var parents: [(Fish, AquariumView.Layout)?] = []
            for i in 0..<(30 * 8) {
                t += Self.dt
                let pl = Self.step(view, [parent, fry], t: t)[parent.id]!
                let l = view.layout(of: fry, in: Self.tank, at: t, now: Date(timeIntervalSince1970: t),
                                    parent: (parent, pl))
                if i % 17 == 0, shots.count < cols {
                    shots.append(Shot(fish: fry, layout: l, t: t))
                    parents.append((parent, pl))
                }
            }
            rows.append(("a fry round its parent squashes through each turn", view, shots, parents))
        }
        // A pellet dropped behind a fish: it turns for it and eats.
        do {
            let fish = Self.makeFish("eater", .angelfish, lane: 0.4)
            let view = Self.grown([fish])
            var t = Self.t0
            _ = Self.step(view, [fish], t: t)
            var body = view.motion.bodies[fish.id]!
            body.x = 0.5
            body.y = 0.4
            body.dir = 1
            view.motion.bodies[fish.id] = body
            view.feed(at: CGPoint(x: 0.36 * Self.tank.width, y: 0.38 * Self.tank.height))
            var shots: [Shot] = []
            for i in 0..<(30 * 3) {
                t += Self.dt
                let l = Self.step(view, [fish], t: t)[fish.id]!
                if i % 6 == 0, shots.count < cols { shots.append(Shot(fish: fish, layout: l, t: t)) }
            }
            rows.append(("a pellet behind the fish: a quick turn, then the dart", view, shots,
                         Array(repeating: nil, count: shots.count)))
        }

        let sheet = Self.sheet(width: cellW * Double(cols), height: (cellH + 18) * Double(rows.count)) { c, _ in
            for (r, row) in rows.enumerated() {
                let top = (cellH + 18) * Double(r)
                Self.label(&c, row.title, at: CGPoint(x: cellW * Double(cols) / 2, y: top + 10), size: 11)
                for (i, shot) in row.shots.prefix(cols).enumerated() {
                    let centre = CGPoint(x: cellW * (Double(i) + 0.5), y: top + 18 + cellH * 0.5)
                    if let parent = row.parents[i] {
                        // The fry, drawn with its parent, both moved together.
                        var g = c
                        g.translateBy(x: centre.x - parent.1.x, y: centre.y - parent.1.y)
                        var dim = parent.1
                        dim.opacity *= 0.35
                        row.view.drawFish(canvas: &g, size: Self.tank, t: shot.t,
                                          now: Date(timeIntervalSince1970: shot.t), fish: parent.0,
                                          layout: dim, parent: nil, showLabels: false)
                        row.view.drawFish(canvas: &g, size: Self.tank, t: shot.t,
                                          now: Date(timeIntervalSince1970: shot.t), fish: shot.fish,
                                          layout: shot.layout, parent: parent, showLabels: false)
                    } else {
                        Self.draw(row.view, shot, on: &c, at: centre)
                    }
                }
            }
        }
        try Self.write(sheet, "fish-turn-states")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1",
                   "set JRBAR_RENDER_PROOF=1 to write the turn proof PNGs"))
    func paceTraces() throws {
        // Thirty seconds of four fish at each pace: the path, a dot where
        // each turn began.
        let bounds = SwimBounds(minX: 0.05, minY: 30 / 560, maxX: 0.95, maxY: 460 / 560, margin: 0.1)
        let paces = SwimPace.allCases
        let panelW = 450.0, panelH = 280.0
        let colors: [Color] = [.orange, .pink, .yellow, .mint]
        let sheet = Self.sheet(width: panelW * Double(paces.count), height: panelH + 30) { c, _ in
            for (col, pace) in paces.enumerated() {
                let ox = panelW * Double(col)
                var turnsTotal = 0
                for (k, id) in ["claude-a", "codex-b", "gemini-c", "devin-e"].enumerated() {
                    let h = AquariumModel.stableHash(id)
                    // The model's per-fish speed and first direction, off the same hash.
                    let fishSpeed = 0.05 + 0.09 * Double((h >> 16) & 0xFFFF) / 0xFFFF
                    var b = AquariumSteering.spawn(seed: h, fishSpeed: fishSpeed,
                                                   direction: (h >> 32) & 1 == 0 ? 1 : -1,
                                                   homeY: 0.2 + 0.18 * Double(k), length: 0.07)
                    var path = Path()
                    path.move(to: CGPoint(x: ox + b.x * panelW, y: 30 + b.y * panelH))
                    var t = 500.0
                    for _ in 0..<(30 * 30) {
                        t += Self.dt
                        let wasTurning = b.turn != nil
                        AquariumSteering.step(&b, dt: Self.dt, t: t, seed: h,
                                              context: SwimContext(bounds: bounds, pace: pace))
                        let p = CGPoint(x: ox + b.x * panelW, y: 30 + b.y * panelH)
                        path.addLine(to: p)
                        if b.turn != nil, !wasTurning {
                            turnsTotal += 1
                            c.fill(Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)),
                                   with: .color(.white.opacity(0.9)))
                        }
                    }
                    c.stroke(path, with: .color(colors[k].opacity(0.85)), lineWidth: 1.4)
                }
                Self.label(&c, "\(pace.displayName): \(turnsTotal) turns by 4 fish in 30 s",
                           at: CGPoint(x: ox + panelW / 2, y: 14), size: 11)
                var frame = Path()
                frame.addRect(CGRect(x: ox + 0.05 * panelW, y: 30 + 30 / 560 * panelH,
                                     width: 0.9 * panelW, height: (430 / 560) * panelH))
                c.stroke(frame, with: .color(.white.opacity(0.25)), lineWidth: 0.8)
            }
        }
        try Self.write(sheet, "fish-turn-pace")
    }
}
