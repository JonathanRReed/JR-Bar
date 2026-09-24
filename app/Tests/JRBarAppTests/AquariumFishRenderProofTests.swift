import AppKit
import Foundation
import SwiftUI
import Testing
import JRBarCore
@testable import JRBarApp

/// Render proof for the Aquarium's creatures: every species in three
/// provider palettes and all three moods, the lineup at the size the
/// tank actually draws, the swim cycle and the turn, every hat and
/// accessory on every body, the six pets, the overlay marks and a
/// meal's pellets. Off by
/// default; set `JRBAR_RENDER_PROOF=1` to write `fish-*.png` into
/// `JRBAR_RENDER_PROOF_DIR` (default `/tmp/jrbar-audit`).
@Suite("Aquarium fish render proof")
@MainActor
struct AquariumFishRenderProofTests {
    private static var outputDir: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF_DIR"]
            ?? "/tmp/jrbar-audit", isDirectory: true)
    }

    /// Classic daytime water, top to bottom, so the fish are judged
    /// against the colour they swim in.
    private static let water = Gradient(colors: [
        Color(red: 0.20, green: 0.56, blue: 0.64),
        Color(red: 0.07, green: 0.33, blue: 0.52),
        Color(red: 0.03, green: 0.17, blue: 0.36),
    ])

    /// The deep lane's floor colour the tank washes toward.
    private static let floorNS = NSColor(srgbRed: 0.015, green: 0.06, blue: 0.22, alpha: 1)

    /// The tank's palette for `provider` at `lane` depth: the same
    /// recipe `drawFish` paints with.
    private static func palette(_ provider: String, lane: Double = 0) -> CartoonFish.Palette {
        CartoonFish.Palette(accent: ProviderStyle.style(for: provider).nsAccent,
                            depth: lane, floor: floorNS)
    }

    /// One fish posed the way `drawFish` poses it: centred on `at`,
    /// `length` long, mid-stroke unless told otherwise.
    private static func pose(_ c: inout GraphicsContext, _ species: FishSpecies,
                             at p: CGPoint, length: Double,
                             palette: CartoonFish.Palette,
                             mouth: CartoonFish.MouthKind = .plain,
                             swim: CartoonFish.Swim = CartoonFish.Swim(phase: 0.9, amplitude: 0.2),
                             blink: Double = 0, facing: Double = 1,
                             dead: Bool = false,
                             variant: AquariumVariant? = nil,
                             hat: ShopItem? = nil, accessory: ShopItem? = nil) {
        var f = c
        f.translateBy(x: p.x, y: p.y)
        f.scaleBy(x: facing * swim.thin * length, y: length)
        CartoonFish.draw(into: &f, species: species, palette: palette, swim: swim,
                         mouth: mouth, blink: blink, dead: dead, pointSize: length, variant: variant)
        let art = CartoonFish.art(for: species)
        let lw = CartoonFish.outlineWidth(length)
        if let hat {
            CartoonFish.drawHat(hat, into: &f, at: art.hatAnchor, scale: art.hatScale,
                                tilt: art.hatTilt, lineWidth: lw)
        }
        if let accessory {
            CartoonFish.drawAccessory(accessory, into: &f, art: art, trail: 0.4, lineWidth: lw)
        }
    }

    private static func label(_ c: inout GraphicsContext, _ text: String, at p: CGPoint) {
        c.draw(Text(text).font(.system(size: 10, weight: .medium))
            .foregroundStyle(.white.opacity(0.75)), at: p, anchor: .center)
    }

    private static func sheet(width: Double, height: Double,
                              draw: @escaping (inout GraphicsContext, CGSize) -> Void) -> some View {
        Canvas { c, size in
            c.fill(Path(CGRect(origin: .zero, size: size)),
                   with: .linearGradient(water, startPoint: .zero,
                                         endPoint: CGPoint(x: 0, y: size.height)))
            draw(&c, size)
        }
        .frame(width: width, height: height)
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

    private static let providers = ["claude", "codex", "gemini"]
    private static let moods: [(String, CartoonFish.MouthKind)] =
        [("plain", .plain), ("smile", .smile), ("hungry", .hungry)]

    @Test(.enabled(if: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1",
                   "set JRBAR_RENDER_PROOF=1 to write fish proof PNGs"))
    func speciesSheets() throws {
        // Every species: a row per provider palette, a column per mood.
        for species in FishSpecies.allCases {
            let cellW = 250.0, cellH = 190.0
            let view = Self.sheet(width: cellW * 3, height: cellH * 3) { c, _ in
                for (row, provider) in Self.providers.enumerated() {
                    for (col, mood) in Self.moods.enumerated() {
                        let centre = CGPoint(x: cellW * (Double(col) + 0.5),
                                             y: cellH * (Double(row) + 0.5))
                        Self.pose(&c, species, at: centre, length: 150,
                                  palette: Self.palette(provider), mouth: mood.1,
                                  swim: CartoonFish.Swim(phase: [0.0, 1.2, 4.2][col], amplitude: 0.2))
                        Self.label(&c, "\(provider) · \(mood.0)",
                                   at: CGPoint(x: centre.x, y: centre.y + cellH * 0.42))
                    }
                }
            }
            try Self.write(view, "fish-species-\(species.rawValue)")
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1",
                   "set JRBAR_RENDER_PROOF=1 to write fish proof PNGs"))
    func overviewAndLineup() throws {
        // The hero sheet: every species big, in the provider it swims for.
        let all = FishSpecies.allCases
        let heroProviders: [FishSpecies: String] = [
            .minnow: "grok", .clownfish: "claude", .angelfish: "gemini", .puffer: "antigravity",
            .shark: "codex", .seahorse: "hermes", .betta: "opencode", .tang: "devin", .tetra: "cursor",
        ]
        let cellW = 300.0, cellH = 230.0
        let hero = Self.sheet(width: cellW * 3, height: cellH * 3) { c, _ in
            for (i, species) in all.enumerated() {
                let centre = CGPoint(x: cellW * (Double(i % 3) + 0.5),
                                     y: cellH * (Double(i / 3) + 0.46))
                let provider = heroProviders[species] ?? "claude"
                Self.pose(&c, species, at: centre, length: 170 * species.sizeScale,
                          palette: Self.palette(provider))
                Self.label(&c, "\(species.displayName) · \(provider)",
                           at: CGPoint(x: centre.x, y: cellH * (Double(i / 3) + 0.93)))
            }
        }
        try Self.write(hero, "fish-overview")

        // The lineup at the size the tank really draws them: a grown
        // fish in a shallow lane, a small one, and a deep-lane one.
        let lineup = Self.sheet(width: 960, height: 330) { c, _ in
            for (i, species) in all.enumerated() {
                let x = 60 + Double(i) * 105
                let provider = heroProviders[species] ?? "claude"
                for (row, (lane, stage)) in [(0.2, 1.12), (0.45, 0.74), (0.9, 0.92)].enumerated() {
                    let length = AquariumView.fishBaseLength * (1.08 - lane * 0.4)
                        * species.sizeScale * stage
                    var d = c
                    d.opacity = 1 - lane * 0.28
                    Self.pose(&d, species, at: CGPoint(x: x, y: 60 + Double(row) * 100),
                              length: length, palette: Self.palette(provider, lane: lane),
                              facing: i % 2 == 0 ? 1 : -1)
                }
            }
        }
        try Self.write(lineup, "fish-lineup-tank-size")

        // The swim cycle and the turn: tail phases, then the head-on
        // squash a wall turn passes through.
        let motion = Self.sheet(width: 960, height: 110 * 4) { c, _ in
            for (row, species) in [FishSpecies.clownfish, .angelfish, .betta, .shark].enumerated() {
                let provider = heroProviders[species] ?? "claude"
                let y = 55 + Double(row) * 110
                for k in 0..<5 {
                    let beat = CartoonFish.Swim(phase: Double(k) * .pi / 4 - .pi / 2, amplitude: 0.25)
                    Self.pose(&c, species, at: CGPoint(x: 60 + Double(k) * 100, y: y),
                              length: 80, palette: Self.palette(provider), swim: beat)
                }
                for (k, thin) in [0.75, 0.45, 0.2].enumerated() {
                    Self.pose(&c, species, at: CGPoint(x: 600 + Double(k) * 100, y: y),
                              length: 80, palette: Self.palette(provider),
                              swim: CartoonFish.Swim(phase: 0.9, amplitude: 0.2, thin: thin))
                }
                Self.pose(&c, species, at: CGPoint(x: 900, y: y), length: 80,
                          palette: Self.palette(provider), blink: 1)
            }
        }
        try Self.write(motion, "fish-motion")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1",
                   "set JRBAR_RENDER_PROOF=1 to write fish proof PNGs"))
    func wearablesSheet() throws {
        // Every hat and accessory on every body, plus the earned marks
        // and the sinking fish's crossed-out eye.
        let items: [ShopItem?] = [nil, .hatBeanie, .hatParty, .hatCrown, .sunglasses, .bowTie,
                                  .monocle, .headphones, .scarf, .topHat, .tinyLaptop]
        let hats: Set<ShopItem> = [.hatBeanie, .hatParty, .hatCrown]
        let cellW = 120.0, cellH = 104.0
        let species = FishSpecies.allCases
        let view = Self.sheet(width: cellW * Double(items.count + 3),
                              height: cellH * Double(species.count)) { c, _ in
            for (row, sp) in species.enumerated() {
                let y = cellH * (Double(row) + 0.5)
                for (col, item) in items.enumerated() {
                    let hat = item.flatMap { hats.contains($0) ? $0 : nil }
                    let accessory = item.flatMap { hats.contains($0) ? nil : $0 }
                    Self.pose(&c, sp, at: CGPoint(x: cellW * (Double(col) + 0.5), y: y),
                              length: 74 * sp.sizeScale, palette: Self.palette("claude"),
                              hat: hat, accessory: accessory)
                }
                let base = Double(items.count)
                Self.pose(&c, sp, at: CGPoint(x: cellW * (base + 0.5), y: y),
                          length: 74 * sp.sizeScale, palette: Self.palette("codex"), variant: .tide)
                Self.pose(&c, sp, at: CGPoint(x: cellW * (base + 1.5), y: y),
                          length: 74 * sp.sizeScale, palette: Self.palette("codex"), variant: .starry)
                Self.pose(&c, sp, at: CGPoint(x: cellW * (base + 2.5), y: y),
                          length: 74 * sp.sizeScale,
                          palette: CartoonFish.Palette(accent: AquariumView.sinkingNS, floor: Self.floorNS),
                          dead: true)
            }
        }
        try Self.write(view, "fish-wearables")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1",
                   "set JRBAR_RENDER_PROOF=1 to write fish proof PNGs"))
    func petsAndMarks() throws {
        let skin = PetArt.OctopusSkin(lit: Color(red: 0.92, green: 0.60, blue: 0.50),
                                      base: Color(red: 0.66, green: 0.38, blue: 0.33),
                                      shade: Color(red: 0.36, green: 0.19, blue: 0.17))
        func placed(_ c: inout GraphicsContext, _ x: Double, _ y: Double, _ s: Double,
                    _ body: (inout GraphicsContext) -> Void) {
            var g = c
            g.translateBy(x: x, y: y)
            g.scaleBy(x: s, y: s)
            body(&g)
        }
        // Every pet at three times its tank size, then at tank size.
        let big = Self.sheet(width: 1200, height: 520) { c, _ in
            placed(&c, 200, 120, 3) { PetArt.seaTurtle(&$0, flap: 0.3) }
            placed(&c, 600, 150, 3) { PetArt.octopus(&$0, skin: skin, crawl: 0.2) }
            placed(&c, 930, 130, 3) { PetArt.axolotl(&$0, swish: 1, step: 0.8, wave: 0.5) }
            placed(&c, 160, 380, 3) { g in
                for i in 0..<3 {
                    var t = g
                    t.translateBy(x: Double(i) * 22 - 22, y: Double(i % 2) * 10)
                    PetArt.neonTetra(&t, length: 15)
                }
            }
            placed(&c, 430, 380, 3) { PetArt.cleanerShrimp(&$0, whisk: 1) }
            placed(&c, 760, 380, 2) { PetArt.manta(&$0, flap: 0.3) }
            placed(&c, 1080, 400, 3) { PetArt.octopusAtHome(&$0, skin: skin, lift: 10, open: 1) }
        }
        try Self.write(big, "fish-pets")
        let tank = Self.sheet(width: 700, height: 150) { c, _ in
            placed(&c, 60, 70, 1) { PetArt.seaTurtle(&$0, flap: 0.3) }
            placed(&c, 170, 90, 1) { PetArt.octopus(&$0, skin: skin, crawl: 0.2) }
            placed(&c, 260, 80, 1) { PetArt.axolotl(&$0, swish: 1, step: 0.8, wave: 0.5) }
            placed(&c, 360, 70, 1) { PetArt.neonTetra(&$0, length: 15) }
            placed(&c, 460, 80, 1) { PetArt.cleanerShrimp(&$0, whisk: 1) }
            placed(&c, 600, 70, 1) { g in
                g.opacity = 0.35
                PetArt.manta(&g, flap: 0.3)
            }
        }
        try Self.write(tank, "fish-pets-tank")

        // The overlay marks over a fish, and a meal's pellets.
        let marks = Self.sheet(width: 600, height: 160) { c, _ in
            for (i, overlay) in FishOverlay.allCases.enumerated() {
                let x = 60 + Double(i) * 110
                Self.pose(&c, .clownfish, at: CGPoint(x: x, y: 100), length: 60,
                          palette: Self.palette("claude"))
                FishOverlayArt.draw(overlay, into: &c, at: CGPoint(x: x + 6, y: 58), r: 6, t: 0.4)
            }
            for k in 0..<4 {
                CreaturePaint.pellet(&c, at: CGPoint(x: 560, y: 30 + Double(k) * 30),
                                     r: 2.4 + Double(k) * 0.4, alpha: 1)
            }
        }
        try Self.write(marks, "fish-marks", scale: 3)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1",
                   "set JRBAR_RENDER_PROOF=1 to write fish proof PNGs"))
    func tankCast() throws {
        // The real tank's fish pass, posed by hand: a dressed working
        // fish, one asking at the glass under its buoy with the hover
        // tag up, a golden one, a hungry one holding a pearl, a sinking
        // one, a crowned resident and a worker's fry.
        let now = Date()
        func fish(_ id: String, _ provider: String, _ species: FishSpecies, _ state: FishState,
                  label: String) -> Fish {
            Fish(id: id, label: label, providerID: provider, state: state, lane: 0.2, speed: 0.1,
                 direction: 1, stateSince: now, enteredAt: .distantPast, species: species)
        }
        let golden = (0..<500).map { "gold-\($0)" }
            .first { AquariumBehavior.isGolden(seed: AquariumModel.stableHash($0)) } ?? "gold-0"
        var asking = fish("ask", "codex", .shark, .surfacing, label: "needs-approval")
        asking.plan = FishPlan(state: .surfacing, action: .attentiveHover, overlay: .attentionBuoy,
                               parallelMarkers: 0, evidence: "ask")
        var hungry = fish("hungry", "gemini", .angelfish, .idling, label: "long-think")
        hungry.plan = FishPlan(state: .idling, action: .idleRest, overlay: .pearl,
                               parallelMarkers: 0, evidence: "done")
        var resident = fish("r-nemo", "antigravity", .puffer, .idling, label: "Nemo")
        resident.isResident = true
        var fry = fish("fry", "claude", .clownfish, .swimming, label: "worker")
        fry.isFry = true
        fry.anchorID = "dressed"
        let cast = [fish("dressed", "claude", .clownfish, .swimming, label: "review-patch"), asking,
                    fish(golden, "opencode", .betta, .swimming, label: "golden"), hungry,
                    fish("sunk", "devin", .tang, .sinking, label: "failed-run"), resident, fry]
        let game = AquariumGame(
            pets: ["dressed": FishCare(stage: 2, feedings: 9),
                   "hungry": FishCare(stage: 1, starvingAt: 1),
                   "r-nemo": FishCare(stage: 2, feedings: 30),
                   golden: FishCare(stage: 2)],
            hats: ["dressed": ShopItem.hatParty.rawValue],
            streakDays: 7,
            accessories: ["dressed": ShopItem.sunglasses.rawValue])
        let tank = AquariumView(fixture: AquariumView.Fixture(fish: cast, game: game, night: 0))
        let view = Self.sheet(width: 1000, height: 320) { c, size in
            let spots: [(Double, Double, Double)] = [(90, 150, 1), (240, 120, -1), (390, 160, 1),
                                                     (540, 150, -1), (690, 190, 1), (840, 150, -1),
                                                     (150, 250, 1)]
            var layouts: [String: AquariumView.Layout] = [:]
            for (f, spot) in zip(cast, spots) {
                var l = AquariumView.Layout()
                l.x = spot.0
                l.y = spot.1
                l.facing = spot.2
                l.scale = 1
                l.wag = f.state == .swimming ? 1.25 : 0.4
                if f.state == .sinking { l.pitch = 0.5 }
                if f.state == .surfacing {
                    // Up at the glass: turned half toward you, ring pulsing.
                    l.tapRing = 0.35
                    l.thin = 0.58
                    l.scale = 1.15
                }
                layouts[f.id] = l
                let parent = f.isFry ? layouts["dressed"].map { (cast[0], $0) } : nil
                tank.drawFish(canvas: &c, size: size, t: 10, now: now, fish: f, layout: l,
                              parent: parent, showLabels: f.id != "ask")
            }
            if let l = layouts["ask"] {
                tank.drawNameplate(canvas: &c, size: size, fish: asking, layout: l)
            }
        }
        try Self.write(view, "fish-tank-cast")
    }
}
