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
/// to write `/tmp/jrbar-audit/aquarium-*.png`.
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

    @Test(.enabled(if: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1",
                   "set JRBAR_RENDER_PROOF=1 to write /tmp/jrbar-audit PNGs"))
    func snapshots() throws {
        let dir = URL(fileURLWithPath: "/tmp/jrbar-audit", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // name, theme, substrate, backdrop, pinned night, visitor.
        let shots: [(String, String, String, String, Double,
                     AquariumVisitor?)] = [
            ("aquarium-abyss", "abyss", "black", "reefwall", 0, .submarine),
            ("aquarium-classic-day", "classic", "classic", "classic", 0, .submarine),
            ("aquarium-sunset", "sunset", "classic", "rocky", 0.35, .submarine),
            ("aquarium-kelp", "kelp", "white", "classic", 0.1, .submarine),
            // The substrate proofs: same classic tank, only the floor
            // changes — bright aragonite vs basalt gravel.
            ("aquarium-classic-white", "classic", "white", "reefwall", 0, nil),
            ("aquarium-classic-black", "classic", "black", "reefwall", 0, nil),
            // The two remaining visitors, each pinned mid-parade.
            ("aquarium-abyss-visitors", "abyss", "black", "reefwall", 0, .whale),
            ("aquarium-diver", "classic", "classic", "reefwall", 0.45, .diver),
        ]
        var written: [String] = []
        for (name, theme, substrate, backdrop, night, visitor) in shots {
            let view = AquariumView(fixture: Self.fixture(
                themeID: theme, substrateID: substrate,
                backdropID: backdrop, night: night, visitor: visitor))
                .frame(width: 1200, height: 700)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 1
            guard let image = renderer.nsImage,
                  let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else {
                Issue.record("render failed for \(name)")
                continue
            }
            try png.write(to: dir.appendingPathComponent("\(name).png"))
            written.append("\(name).png")
        }
        #expect(written.count == 8)
    }
}
