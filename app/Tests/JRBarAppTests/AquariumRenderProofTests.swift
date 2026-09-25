import AppKit
import Foundation
import SwiftUI
import Testing
import JRBarCore
@testable import JRBarApp

/// Render proof for the Aquarium: one synthetic tank that owns every
/// shop item — all the decor, all the pets, wearables, a buried
/// treasure, a resident or two — rendered at 1200×700 and 2× under
/// every theme, floor, back wall, visitor and a night, beside a starter
/// tank, the empty tank, a small window, the shop and the card, so a
/// human can eyeball the art the way the review screenshots do. Off by
/// default; set `JRBAR_RENDER_PROOF=1` to write `aquarium-*.png` into
/// `JRBAR_RENDER_PROOF_DIR` (default `/tmp/jrbar-audit`).
@Suite("Aquarium render proof")
@MainActor
struct AquariumRenderProofTests {
    /// The tank everything renders: every item owned, a treasure half
    /// dug at mid-sand, a submarine queued for its pass, four live
    /// fish (one working with the tiny laptop, one wearing a party
    /// hat and sunglasses, one deep to show the depth attenuation)
    /// and two raised residents keeping the bottom.
    private static func fixture(themeID: String, substrateID: String,
                                backdropID: String, night: Double,
                                visitor: AquariumVisitor? = .submarine,
                                visitorProgress: Double? = 0.5) -> AquariumView.Fixture {
        let now = Date()
        // The working fish forage, lap and hold at their stations, so
        // a proof shot shows the tool-level tells (and the parallel
        // motes of a main with three workers).
        var working = Fish(id: "f-working", label: "review-patch",
                           providerID: "claude", state: .swimming,
                           lane: 0.35, speed: 0.10, direction: 1,
                           stateSince: now, enteredAt: .distantPast,
                           species: .betta)
        working.plan = FishPlan(state: .swimming, action: .forage, overlay: nil,
                                parallelMarkers: 3, evidence: "forage ← tool=Read")
        working.cue = FishCue(station: .kelp)
        let dressed = Fish(id: "f-dressed", label: "ship-it",
                           providerID: "codex", state: .idling,
                           lane: 0.45, speed: 0.06, direction: -1,
                           stateSince: now, enteredAt: .distantPast,
                           species: .angelfish)
        var deep = Fish(id: "f-deep", label: "long-think",
                        providerID: "gemini", state: .swimming,
                        lane: 0.9, speed: 0.08, direction: -1,
                        stateSince: now, enteredAt: .distantPast,
                        species: .tang)
        deep.cue = FishCue(station: .current)
        var fourth = Fish(id: "f-fourth", label: "tidy-up",
                          providerID: "jrbar", state: .swimming,
                          lane: 0.6, speed: 0.12, direction: 1,
                          stateSince: now, enteredAt: .distantPast,
                          species: .clownfish)
        fourth.cue = FishCue(station: .wreck, tone: .pass)
        var resident = Fish(id: "r-nemo", label: "Nemo",
                            providerID: "claude", state: .idling,
                            lane: 0.72, speed: 0.04, direction: 1,
                            stateSince: now, enteredAt: .distantPast,
                            species: .puffer)
        resident.isResident = true
        var resident2 = Fish(id: "r-bubbles", label: "Bubbles",
                             providerID: "codex", state: .idling,
                             lane: 0.25, speed: 0.05, direction: -1,
                             stateSince: now, enteredAt: .distantPast,
                             species: .seahorse)
        resident2.isResident = true

        let game = AquariumGame(
            pearls: 2657, lifetimePearls: 5200,
            pets: [
                "r-nemo": FishCare(stage: 2, feedings: 30, workSeconds: 9000,
                                   createdAt: 100, label: "Nemo", provider: "claude"),
                "r-bubbles": FishCare(stage: 2, feedings: 21, workSeconds: 7000,
                                      createdAt: 200, label: "Bubbles", provider: "codex"),
                "f-working": FishCare(stage: 1, feedings: 4, createdAt: 300,
                                      label: "review-patch", provider: "claude"),
                "f-dressed": FishCare(stage: 2, feedings: 18, createdAt: 400,
                                      label: "ship-it", provider: "codex"),
            ],
            inventory: Dictionary(uniqueKeysWithValues:
                ShopItem.allCases.map { ($0.rawValue, 1) }),
            themeID: themeID,
            hats: ["f-dressed": ShopItem.hatParty.rawValue],
            streakDays: 7,
            accessories: ["f-working": ShopItem.tinyLaptop.rawValue,
                          "f-dressed": ShopItem.sunglasses.rawValue],
            substrateID: substrateID,
            backdropID: backdropID,
            treasure: AquariumTreasure(id: "proof-chest", x: 0.55, taps: 1,
                                       buriedAt: 0, value: 40),
            pendingVisitors: visitor == nil ? [] : [visitor!])

        return AquariumView.Fixture(
            fish: [working, dressed, deep, fourth, resident, resident2],
            game: game, night: night,
            visitorProgress: visitor == nil ? nil : visitorProgress)
    }

    /// Always on: the station tells, the parallel motes and the result
    /// bubble all draw through one tank without tripping — the proof
    /// shots below only run on request.
    @Test("a tank with working stations renders")
    func stationsRender() {
        let view = AquariumView(fixture: Self.fixture(
            themeID: "classic", substrateID: "classic", backdropID: "classic",
            night: 0, visitor: nil))
            .frame(width: 900, height: 520)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        #expect(renderer.cgImage != nil)
    }

    /// The earned marks draw through the tank without tripping.
    @Test("fish wearing earned marks render")
    func variantsRender() {
        var fixture = Self.fixture(themeID: "classic", substrateID: "classic",
                                   backdropID: "classic", night: 0, visitor: nil)
        fixture.game?.pets["f-working"]?.variant = AquariumVariant.tide.rawValue
        fixture.game?.pets["f-dressed"]?.variant = AquariumVariant.starry.rawValue
        let renderer = ImageRenderer(content: AquariumView(fixture: fixture)
            .frame(width: 900, height: 520))
        renderer.scale = 1
        #expect(renderer.cgImage != nil)
    }

    /// Mean brightness of a render, 0…1.
    private static func brightness(_ image: CGImage) -> Double {
        let w = 90, h = 52
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let context = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8,
                                bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var sum = 0.0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            sum += (Double(pixels[i]) + Double(pixels[i + 1]) + Double(pixels[i + 2])) / 765
        }
        return sum / Double(w * h)
    }

    /// The fleet's mood reaches the water: a low quota darkens the
    /// column and a reset's shaft brightens it, against the same tank.
    @Test("the water reads the fleet: low quota dims, a reset's shaft brightens")
    func fleetMoodRenders() throws {
        func render(_ mood: AquariumWaterMood?) throws -> Double {
            var fixture = Self.fixture(themeID: "classic", substrateID: "classic",
                                       backdropID: "classic", night: 0, visitor: nil)
            fixture.fish = []
            fixture.mood = mood
            let renderer = ImageRenderer(content: AquariumView(fixture: fixture)
                .frame(width: 450, height: 260))
            renderer.scale = 1
            return Self.brightness(try #require(renderer.cgImage))
        }
        let calm = try render(nil)
        #expect(try render(AquariumWaterMood(low: 1)) < calm - 0.01)
        #expect(try render(AquariumWaterMood(shaft: 1)) > calm + 0.005)
    }

    /// Writes one render into the proof directory at 2× — the scale a
    /// Retina display draws the tank at, so the art is judged as seen.
    private static func writePNG<V: View>(_ view: V, size: CGSize, name: String,
                                          into dir: URL) throws -> Bool {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        renderer.scale = 2
        guard let image = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: image)
                .representation(using: .png, properties: [:]) else {
            Issue.record("render failed for \(name)")
            return false
        }
        try png.write(to: dir.appendingPathComponent("\(name).png"))
        return true
    }

    /// Draws `view` in an offscreen window and returns its layer tree
    /// as a 2× bitmap — AppKit-backed controls (the segmented Labels
    /// picker, the switches) included, which `ImageRenderer` can't draw.
    private static func hostedSnapshot<V: View>(_ view: V, size: CGSize,
                                                dark: Bool) throws -> NSBitmapImageRep {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let hosting = NSHostingView(rootView: view
            .environment(\.colorScheme, dark ? .dark : .light)
            .frame(width: size.width, height: size.height))
        let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: -20000, y: -20000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        hosting.frame = NSRect(origin: .zero, size: size)
        for _ in 0..<6 {
            hosting.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = size
        let context = try #require(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        appearance?.performAsCurrentDrawingAppearance {
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
        }
        NSGraphicsContext.restoreGraphicsState()
        window.contentView = nil
        window.close()
        return rep
    }

    /// The lookbook: every theme, floor, back wall and visitor, a
    /// night, a starter tank that owns nothing, the quiet empty tank,
    /// and the shop — the looks a person actually meets.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1",
                   "set JRBAR_RENDER_PROOF=1 to write /tmp/jrbar-audit PNGs"))
    func snapshots() throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF_DIR"]
                      ?? "/tmp/jrbar-audit", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tank = CGSize(width: 1200, height: 700)
        // name, theme, substrate, backdrop, pinned night, visitor.
        let shots: [(String, String, String, String, Double,
                     AquariumVisitor?)] = [
            ("aquarium-classic-day", "classic", "classic", "classic", 0, .submarine),
            ("aquarium-classic-night", "classic", "classic", "classic", 1, nil),
            ("aquarium-abyss", "abyss", "black", "reefwall", 0, .submarine),
            ("aquarium-sunset", "sunset", "classic", "rocky", 0.35, .submarine),
            ("aquarium-kelp", "kelp", "white", "classic", 0.1, .submarine),
            // The substrate proofs: same classic tank, only the floor
            // changes — bright aragonite vs basalt gravel.
            ("aquarium-classic-white", "classic", "white", "reefwall", 0, nil),
            ("aquarium-classic-black", "classic", "black", "reefwall", 0, nil),
            // The two remaining visitors, each pinned mid-parade.
            ("aquarium-abyss-visitors", "abyss", "black", "reefwall", 0, .whale),
            ("aquarium-diver", "classic", "classic", "reefwall", 0.45, .diver),
            // The rest of the shop's water.
            ("aquarium-reef", "reef", "classic", "classic", 0, nil),
            ("aquarium-lagoon", "lagoon", "white", "classic", 0, nil),
            ("aquarium-twilight", "twilight", "classic", "rocky", 0.2, nil),
            ("aquarium-midnight", "midnight", "black", "reefwall", 0.6, nil),
            ("aquarium-dawn", "dawn", "classic", "classic", 0.1, nil),
            ("aquarium-blackwater", "blackwater", "classic", "rocky", 0, nil),
        ]
        var written = 0
        for (name, theme, substrate, backdrop, night, visitor) in shots {
            let view = AquariumView(fixture: Self.fixture(
                themeID: theme, substrateID: substrate,
                backdropID: backdrop, night: night, visitor: visitor))
            if try Self.writePNG(view, size: tank, name: name, into: dir) { written += 1 }
        }
        // The Arcade tank: each Toy reef act by tank level, candy
        // gravel, then the same at night.
        for (act, lifetime) in [0, 400, 3200, 12000].enumerated() {
            var arcade = Self.fixture(themeID: "arcade", substrateID: "candy",
                                      backdropID: "toyreef", night: 0, visitor: nil)
            arcade.game?.lifetimePearls = lifetime
            if try Self.writePNG(AquariumView(fixture: arcade), size: tank,
                                 name: "aquarium-arcade-act\(act + 1)", into: dir) { written += 1 }
        }
        var arcadeNight = Self.fixture(themeID: "arcade", substrateID: "candy",
                                       backdropID: "toyreef", night: 1, visitor: nil)
        arcadeNight.game?.lifetimePearls = 3200
        if try Self.writePNG(AquariumView(fixture: arcadeNight), size: tank,
                             name: "aquarium-arcade-night", into: dir) { written += 1 }
        // Candy gravel under the classic water.
        let candy = AquariumView(fixture: Self.fixture(themeID: "classic", substrateID: "candy",
                                                       backdropID: "classic", night: 0, visitor: nil))
        if try Self.writePNG(candy, size: tank, name: "aquarium-candy-classic", into: dir) { written += 1 }
        // The card's swatch for it: beads on tan, not a rainbow.
        let swatches = HStack(spacing: 12) {
            TankSwatch(themeID: "classic", substrateID: "classic")
            TankSwatch(themeID: "arcade", substrateID: "candy")
        }
        .padding(10)
        if try Self.writePNG(swatches, size: CGSize(width: 196, height: 66),
                             name: "aquarium-swatch-candy", into: dir) { written += 1 }
        // Coins mid-fall, at rest and a crowned fish's gem.
        if try Self.writePNG(Self.coins(), size: CGSize(width: 640, height: 360),
                             name: "aquarium-coins", into: dir) { written += 1 }
        // The alien, mid-parade, just tapped.
        var alien = Self.fixture(themeID: "arcade", substrateID: "candy",
                                 backdropID: "toyreef", night: 0, visitor: .alien, visitorProgress: 0.42)
        alien.game?.lifetimePearls = 400
        let alienTank = AquariumView(fixture: alien)
        alienTank.motion.puffs = [(x: 0.58, y: 0.24, bornAt: Date().addingTimeInterval(-0.15))]
        if try Self.writePNG(alienTank, size: tank, name: "aquarium-alien", into: dir) { written += 1 }
        // The castle with the volcano and the alien beacon: the crater
        // clears the round tower and the beacon stands in front of the
        // side tower — by day at full size, and at night in the small
        // window a tank first opens at.
        let keepShots: [(name: String, night: Double, size: CGSize)] = [
            ("aquarium-beacon-castle", 0, tank),
            ("aquarium-beacon-castle-night", 1, CGSize(width: 640, height: 400)),
        ]
        for shot in keepShots {
            var keep = Self.fixture(themeID: "classic", substrateID: "classic", backdropID: "classic",
                                    night: shot.night, visitor: nil)
            keep.game?.inventory = ["castle": 1, "alienBeacon": 1, "volcano": 1, "coralGarden": 1,
                                    "ruinedColumns": 1]
            if try Self.writePNG(AquariumView(fixture: keep), size: shot.size, name: shot.name,
                                 into: dir) { written += 1 }
        }
        // The oyster open with its pearl, and the snail at its errands.
        if try Self.writePNG(Self.sandPets(), size: CGSize(width: 640, height: 360),
                             name: "aquarium-oyster-open", into: dir) { written += 1 }
        if try Self.writePNG(Self.sandPets(arcade: true), size: CGSize(width: 640, height: 360),
                             name: "aquarium-snail-hustle", into: dir) { written += 1 }
        // A new tank: the seeded bed only, four sessions swimming.
        var starter = Self.fixture(themeID: "classic", substrateID: "classic",
                                   backdropID: "classic", night: 0, visitor: nil)
        starter.game = AquariumGame(pearls: 12)
        starter.fish.removeAll { $0.isResident }
        if try Self.writePNG(AquariumView(fixture: starter), size: tank,
                             name: "aquarium-starter", into: dir) { written += 1 }
        // Quiet water: nothing swimming, nothing bought.
        let empty = AquariumView.Fixture(fish: [], night: 0)
        if try Self.writePNG(AquariumView(fixture: empty), size: tank,
                             name: "aquarium-empty", into: dir) { written += 1 }
        // A small window, the size a tank first opens at.
        let small = AquariumView(fixture: Self.fixture(
            themeID: "classic", substrateID: "classic", backdropID: "classic",
            night: 0, visitor: nil))
        if try Self.writePNG(small, size: CGSize(width: 640, height: 400),
                             name: "aquarium-small", into: dir) { written += 1 }
        // The tap juice no swim-through catches: the half-dug treasure,
        // a gold burst just popped and one falling, a bubble-ring trick,
        // a bloop and a pearl on its way home to the chip.
        if try Self.writePNG(Self.tapEvents(), size: CGSize(width: 640, height: 360),
                             name: "aquarium-events", into: dir) { written += 1 }
        // The shop's shelves over a rich purse, light and dark — drawn
        // without the popover's scroll view, which the renderer skips.
        var purse = Self.fixture(themeID: "classic", substrateID: "classic",
                                 backdropID: "classic", night: 0, visitor: nil)
        purse.game?.inventory = ["plant": 1, "rock": 1, "castle": 1, "themeReef": 1, "sandWhite": 1]
        let shopTank = AquariumView(fixture: purse)
        // Hosted, so the In tank switches draw as the shop shows them.
        purse.game?.stored = ["rock"]
        for dark in [false, true] {
            let shelves = shopTank.shopShelves(game: purse.game ?? AquariumGame(), adults: purse.fish)
                .padding(16)
                .frame(width: 348, height: 3900, alignment: .top)
                .background(Color(nsColor: .windowBackgroundColor))
            let rep = try Self.hostedSnapshot(shelves, size: CGSize(width: 348, height: 3900), dark: dark)
            if let png = rep.representation(using: .png, properties: [:]) {
                try png.write(to: dir.appendingPathComponent("aquarium-shop-\(dark ? "dark" : "light").png"))
                written += 1
            }
        }
        // The card's controls and the live tank's HUD, from a real toy
        // on a scratch save.
        let core = CoreModel()
        core.apply(.state(CoreState(sessions: (0..<3).map {
            CoreSession(id: "s\($0)", provider: "claude", mode: "idle_ready", lifecycle: "active")
        })))
        let store = ToysStore(core: core, settings: SettingsStore(core: core), state: ToysState(),
                              cardModel: makeTestCardModel(), notchRuntimeEnabled: false)
        let save = AquariumSaveFile(url: FileManager.default.temporaryDirectory
            .appending(path: "jrbar-proof-\(UUID().uuidString)")
            .appending(path: "aquarium-save.json"))
        defer { try? FileManager.default.removeItem(at: save.url.deletingLastPathComponent()) }
        let toy = AquariumToy(core: core, store: store, saveFile: save)
        // The card as its page draws it (the card body's row styles,
        // AppKit controls and all), folded and with Fine-tune open,
        // light and dark.
        for dark in [false, true] {
            for open in [false, true] {
                let card = Form {
                    Section {
                        AquariumControlsView(toy: toy, fineTune: open)
                            .cardBodyStyle()
                    }
                }
                .formStyle(.grouped)
                let name = "aquarium-card-\(dark ? "dark" : "light")\(open ? "-finetune" : "")"
                let size = CGSize(width: 560, height: open ? 1280 : 820)
                let rep = try Self.hostedSnapshot(card, size: size, dark: dark)
                if let png = rep.representation(using: .png, properties: [:]) {
                    try png.write(to: dir.appendingPathComponent("\(name).png"))
                    written += 1
                }
            }
        }
        if try Self.writePNG(AquariumView(toy: toy), size: CGSize(width: 900, height: 520),
                             name: "aquarium-hud", into: dir) { written += 1 }
        // The chrome alone over a flat sea, drawn through a hosting
        // view — the image renderer leaves Liquid Glass out entirely.
        let chrome = AquariumView(toy: toy).gameChrome(fish: [])
            .background(Color(red: 0.06, green: 0.34, blue: 0.52))
        let host = NSHostingView(rootView: chrome.frame(width: 900, height: 200))
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 200)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try png.write(to: dir.appendingPathComponent("aquarium-chrome.png"))
                written += 1
            }
        }
        #expect(written == shots.count + 25)
    }

    // MARK: The Arcade tank

    /// Mean colourfulness of a render, 0…1: each pixel's chroma, how
    /// far its brightest channel stands from its dimmest. (HSV's ratio
    /// would score a near-black navy as vivid as a lit cyan; the loud
    /// tank is the one whose colour you can see.)
    private static func saturation(_ image: CGImage) -> Double {
        let w = 90, h = 52
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let context = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8,
                                bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var sum = 0.0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let rgb = [Double(pixels[i]), Double(pixels[i + 1]), Double(pixels[i + 2])]
            let hi = rgb.max() ?? 0, lo = rgb.min() ?? 0
            sum += (hi - lo) / 255
        }
        return sum / Double(w * h)
    }

    /// Mean colour of a render, per channel 0…1.
    private static func meanColor(_ image: CGImage) -> SIMD3<Double> {
        let w = 90, h = 52
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let context = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8,
                                bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var sum = SIMD3<Double>(0, 0, 0)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            sum += SIMD3(Double(pixels[i]), Double(pixels[i + 1]), Double(pixels[i + 2])) / 255
        }
        return sum / Double(w * h)
    }

    /// A day tank in `theme` with nobody in it.
    private static func quietTank(theme: String, substrate: String = "classic") -> AquariumView.Fixture {
        var fixture = Self.fixture(themeID: theme, substrateID: substrate,
                                   backdropID: "classic", night: 0, visitor: nil)
        fixture.fish = []
        return fixture
    }

    @Test("the Arcade tank renders brighter and more saturated than classic")
    func arcadeIsLoud() throws {
        func render(_ theme: String) throws -> CGImage {
            let renderer = ImageRenderer(content: AquariumView(fixture: Self.quietTank(theme: theme))
                .frame(width: 450, height: 260))
            renderer.scale = 1
            return try #require(renderer.cgImage)
        }
        let classic = try render("classic")
        let arcade = try render("arcade")
        #expect(Self.brightness(arcade) > Self.brightness(classic) + 0.06)
        #expect(Self.saturation(arcade) > Self.saturation(classic) + 0.08)
    }

    @Test("every Toy reef act renders, and each act looks different from the one before")
    func toyReefActs() throws {
        #expect(AquariumView.toyReefAct(level: 0) == 0)
        #expect(AquariumView.toyReefAct(level: 5) == 1)
        #expect(AquariumView.toyReefAct(level: 8) == 2)
        #expect(AquariumView.toyReefAct(level: 9) == 3)
        var means: [SIMD3<Double>] = []
        for lifetime in [0, 400, 3200, 12000] {
            var fixture = Self.quietTank(theme: "classic")
            fixture.game?.backdropID = "toyreef"
            fixture.game?.lifetimePearls = lifetime
            let tank = AquariumView(fixture: fixture)
            let renderer = ImageRenderer(content: Canvas { canvas, size in
                tank.drawWater(canvas: &canvas, size: size, t: 0)
                tank.drawBackdrop(canvas: &canvas, size: size)
                tank.drawToyReefLights(canvas: &canvas, size: size, t: 0)
            }.frame(width: 450, height: 260))
            renderer.scale = 1
            means.append(Self.meanColor(try #require(renderer.cgImage)))
        }
        for (a, b) in zip(means, means.dropFirst()) {
            let d = a - b
            #expect((d * d).sum().squareRoot() > 0.01, "consecutive acts differ")
        }
    }

    // MARK: Put away

    @Test("a piece put away draws nothing: the tank looks as if it were never bought")
    func storedDrawsNothing() throws {
        func render(_ dress: (inout AquariumGame) -> Void) throws -> Data {
            var fixture = Self.quietTank(theme: "classic")
            var game = AquariumGame(lifetimePearls: 5000)
            dress(&game)
            fixture.game = game
            let tank = AquariumView(fixture: fixture)
            let renderer = ImageRenderer(content: Canvas { canvas, size in
                tank.drawWater(canvas: &canvas, size: size, t: 0)
                tank.drawOwnedBackDecor(canvas: &canvas, size: size, t: 0)
                tank.drawOyster(canvas: &canvas, size: size, t: 0)
            }.frame(width: 450, height: 260))
            renderer.scale = 1
            let image = try #require(renderer.cgImage)
            return try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        }
        let bare = try render { _ in }
        let shown = try render { game in
            game.inventory["shipwreck"] = 1
            game.inventory["oyster"] = 1
        }
        let stored = try render { game in
            game.inventory["shipwreck"] = 1
            game.inventory["oyster"] = 1
            game.stored = ["shipwreck", "oyster"]
        }
        #expect(shown != bare)
        #expect(stored == bare)
    }

    // MARK: Pearls that stay put

    /// Draws one drops pass at `time` and returns the first drop's box.
    private static func dropBox(_ tank: AquariumView, layouts: [String: AquariumView.Layout],
                                at time: Double) -> CGRect? {
        let renderer = ImageRenderer(content: Canvas { canvas, size in
            tank.drawDrops(canvas: &canvas, size: size, t: time, layouts: layouts)
        }.frame(width: 900, height: 520))
        renderer.scale = 1
        _ = renderer.cgImage
        return tank.motion.dropBoxes.first?.rect
    }

    @Test("a pearl falls from its fish and its resting spot doesn't move when the fish swims away")
    func dropRestsWhereItFell() throws {
        var fixture = Self.fixture(themeID: "classic", substrateID: "classic",
                                   backdropID: "classic", night: 0, visitor: nil)
        let t = Date().timeIntervalSince1970
        fixture.game?.drops = [PearlDrop(id: "d1", fishID: "f-dressed", at: t, value: 1)]
        let tank = AquariumView(fixture: fixture)
        let first = try #require(Self.dropBox(tank, layouts: ["f-dressed": .init(x: 300, y: 200)], at: t))
        let landed = try #require(Self.dropBox(tank, layouts: ["f-dressed": .init(x: 700, y: 150)],
                                               at: t + 2))
        let later = try #require(Self.dropBox(tank, layouts: [:], at: t + 30))
        #expect(abs(first.midX - 300) < 1, "it starts under its fish")
        #expect(first.midY < landed.midY - 50, "a fresh drop falls to the sand")
        #expect(abs(landed.midX - 300) < 1, "it rests where it fell, not under the fish's new spot")
        #expect(landed.midX == later.midX, "its fish leaving doesn't move it either")
        #expect(landed.midY == later.midY)
    }

    @Test("a drop the tank finds already old rests at once")
    func oldDropRests() throws {
        var fixture = Self.fixture(themeID: "classic", substrateID: "classic",
                                   backdropID: "classic", night: 0, visitor: nil)
        let t = Date().timeIntervalSince1970
        fixture.game?.drops = [PearlDrop(id: "d1", fishID: "f-dressed", at: t - 600, value: 1)]
        let tank = AquariumView(fixture: fixture)
        let first = try #require(Self.dropBox(tank, layouts: ["f-dressed": .init(x: 300, y: 200)], at: t))
        let next = try #require(Self.dropBox(tank, layouts: ["f-dressed": .init(x: 300, y: 200)],
                                             at: t + 0.5))
        #expect(first == next)
        #expect(first.midY > 400, "on the sand, not up with its fish")
    }

    /// A patch of the Arcade tank with four drops: two coins caught 20 %
    /// and 60 % through their fall, one resting, and a crowned fish's
    /// gem beside it.
    private static func coins() -> some View {
        var fixture = Self.quietTank(theme: "arcade", substrate: "candy")
        let now = Date()
        let t = now.timeIntervalSince1970
        fixture.game?.drops = (0..<4).map { PearlDrop(id: "c\($0)", fishID: "gone", at: t - 600, value: 1) }
        let tank = AquariumView(fixture: fixture)
        let fall = AquariumView.dropFallSeconds
        tank.motion.dropSpots = [
            "c0": .init(x: 0.25, fromY: 0.25, seenAt: t - fall * 0.2),
            "c1": .init(x: 0.42, fromY: 0.25, seenAt: t - fall * 0.6),
            "c2": .init(x: 0.60, fromY: nil, seenAt: t),
            "c3": .init(x: 0.75, fromY: nil, seenAt: t, gem: true),
        ]
        return Canvas { canvas, size in
            tank.drawWater(canvas: &canvas, size: size, t: t)
            tank.drawBackdrop(canvas: &canvas, size: size)
            tank.drawFarSand(canvas: &canvas, size: size)
            tank.drawSand(canvas: &canvas, size: size, t: t)
            tank.drawBubbles(canvas: &canvas, size: size, t: t, density: 1)
            tank.drawDrops(canvas: &canvas, size: size, t: t, layouts: [:])
        }
    }

    /// A patch of the bed: the oyster open with its pearl (a coin in the
    /// Arcade tank), one snail hustling toward a resting pearl, dust
    /// behind it, and a second one an hour past its last pearl — shell
    /// warmed red — napping.
    private static func sandPets(arcade: Bool = false) -> some View {
        var fixture = Self.quietTank(theme: arcade ? "arcade" : "classic",
                                     substrate: arcade ? "candy" : "classic")
        let now = Date()
        let t = now.timeIntervalSince1970
        fixture.game?.oysterReady = true
        fixture.game?.drops = [PearlDrop(id: "p0", fishID: "gone", at: t - 600, value: 1)]
        let tank = AquariumView(fixture: fixture)
        tank.motion.dropSpots = ["p0": .init(x: 0.22, fromY: nil, seenAt: t)]
        var hustler = SnailSim(x: 0.62)
        for _ in 0..<30 { hustler.step(dt: 1.0 / 30, pearl: 0.22) }
        var grump = SnailSim(x: 0.86)
        grump.facing = -1
        for _ in 0..<Int((SnailSim.huffAfter + SnailSim.huffRamp) / 0.25) { grump.step(dt: 0.25, pearl: nil) }
        while !grump.napping { grump.step(dt: 0.25, pearl: nil) }
        grump.x = 0.86
        let snails = [hustler, grump]
        return Canvas { canvas, size in
            tank.drawWater(canvas: &canvas, size: size, t: t)
            tank.drawBackdrop(canvas: &canvas, size: size)
            tank.drawFarSand(canvas: &canvas, size: size)
            tank.drawSand(canvas: &canvas, size: size, t: t)
            tank.drawOyster(canvas: &canvas, size: size, t: t)
            tank.drawDrops(canvas: &canvas, size: size, t: t, layouts: [:])
            for snail in snails {
                tank.drawSnailBody(canvas: &canvas, size: size, t: t, sim: snail)
            }
        }
    }

    /// A patch of the classic tank with every tap event caught mid-way,
    /// each drawn by the pass the live canvas uses.
    private static func tapEvents() -> some View {
        var fixture = Self.fixture(themeID: "classic", substrateID: "classic",
                                   backdropID: "classic", night: 0, visitor: nil)
        fixture.fish = []
        let tank = AquariumView(fixture: fixture)
        let now = Date()
        let motion = tank.motion
        motion.goldBursts = [(x: CGPoint(x: 110, y: 250), bornAt: now.addingTimeInterval(-0.22)),
                             (x: CGPoint(x: 250, y: 250), bornAt: now.addingTimeInterval(-0.62))]
        motion.tricks = ["ring": (kind: .ring,
                                  until: now.addingTimeInterval(AquariumBehavior.trickDuration * 0.55))]
        motion.puffs = [(x: 0.62, y: 0.42, bornAt: now.addingTimeInterval(-0.18))]
        motion.flights = [(from: CGPoint(x: 540, y: 280), bornAt: now.addingTimeInterval(-0.3))]
        motion.pearlChip = CGPoint(x: 600, y: 40)
        let ringLayout = AquariumView.Layout(x: 470, y: 200)
        let t = now.timeIntervalSince1970
        return Canvas { canvas, size in
            tank.drawWater(canvas: &canvas, size: size, t: t)
            tank.drawBackdrop(canvas: &canvas, size: size)
            tank.drawFarSand(canvas: &canvas, size: size)
            tank.drawSand(canvas: &canvas, size: size, t: t)
            tank.drawTreasure(canvas: &canvas, size: size, t: t, now: now)
            tank.drawGoldBursts(canvas: &canvas, size: size, now: now)
            tank.drawTrickRings(canvas: &canvas, size: size, layouts: ["ring": ringLayout], now: now)
            tank.drawPuffs(canvas: &canvas, size: size, now: now)
            tank.drawFlights(canvas: &canvas, size: size, now: now)
        }
    }
}
