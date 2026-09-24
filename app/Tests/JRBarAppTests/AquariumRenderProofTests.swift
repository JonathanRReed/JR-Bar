import AppKit
import Foundation
import SwiftUI
import Testing
import JRBarCore
@testable import JRBarApp

/// Render proof for the expanded Aquarium: one synthetic tank that
/// owns every shop item — all the new decor, all six pets, wearables,
/// a buried treasure, a resident or two — rendered at 1200×700 under
/// four looks so a human can eyeball the tranche-2B art the way the
/// review screenshots do. Off by default; set `JRBAR_RENDER_PROOF=1`
/// to write `aquarium-*.png` into `JRBAR_RENDER_PROOF_DIR` (default
/// `/tmp/jrbar-audit`).
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
        // The shop's shelves over a rich purse, light and dark — drawn
        // without the popover's scroll view, which the renderer skips.
        var purse = Self.fixture(themeID: "classic", substrateID: "classic",
                                 backdropID: "classic", night: 0, visitor: nil)
        purse.game?.inventory = ["plant": 1, "rock": 1, "castle": 1, "themeReef": 1, "sandWhite": 1]
        let shopTank = AquariumView(fixture: purse)
        for scheme in [ColorScheme.light, .dark] {
            let shelves = shopTank.shopShelves(game: purse.game ?? AquariumGame(), adults: purse.fish)
                .padding(16)
                .frame(width: 348, height: 3400, alignment: .top)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, scheme)
            if try Self.writePNG(shelves, size: CGSize(width: 348, height: 3400),
                                 name: "aquarium-shop-\(scheme == .dark ? "dark" : "light")",
                                 into: dir) { written += 1 }
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
        for scheme in [ColorScheme.light, .dark] {
            let card = toy.controls
                .padding(16)
                .frame(width: 560, alignment: .top)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, scheme)
            if try Self.writePNG(card, size: CGSize(width: 560, height: 520),
                                 name: "aquarium-card-\(scheme == .dark ? "dark" : "light")",
                                 into: dir) { written += 1 }
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
        #expect(written == shots.count + 9)
    }
}
