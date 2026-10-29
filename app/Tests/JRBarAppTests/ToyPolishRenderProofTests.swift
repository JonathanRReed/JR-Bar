import AppKit
import Foundation
import JRBarCore
import JRBarTestSupport
import JRBarUI
import SwiftUI
import Testing
@testable import JRBarApp

@MainActor
@Suite("Toy polish render proof", .temporaryDirectory, .renderProofAppearance)
struct ToyPolishRenderProofTests {
    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func reopenAndStatus() throws {
        let core = CoreModel()
        let owner = ToysStore(core: core, settings: SettingsStore(core: core), state: ToysState(),
                              cardModel: makeTestCardModel(), notchRuntimeEnabled: false,
                              nativeSourcesEnabled: false, aquariumSave: AquariumToy.scratchSave())
        defer { owner.shutdown() }
        let tank = try #require(owner.aquarium)
        owner.state.aquarium.enabled = true
        tank.windowDidClose()
        let card = Form {
            HStack {
                Text("Aquarium").jrbarType(.headline)
                StatusBadge(tank.status.text, tint: tank.status.tint)
            }
            AquariumControlsView(toy: tank)
        }.formStyle(.grouped)
        try ProofRender.write(card, size: CGSize(width: 720, height: 680), name: "t1-aquarium-closed-card")
        try ProofRender.write(AquariumView(toy: tank), size: CGSize(width: 900, height: 520), name: "t1-aquarium-hud")
        let verbs = AquariumPaletteVerbs(feed: { nil }, setOpen: { _ in })
        let item = try #require(AquariumPaletteRows.items(fishCount: 0, isOn: true, verbs: verbs).first)
        let actions = HStack {
            Text(item.title).jrbarType(.headline)
            Spacer()
            ForEach(item.actions) { action in
                Button(action.title) { _ = action.run() }
            }
        }.padding(20).background(Color(nsColor: .windowBackgroundColor))
        try ProofRender.write(actions, size: CGSize(width: 580, height: 90), name: "t1-aquarium-palette-actions")
        let chips = VStack(alignment: .leading, spacing: 16) {
            ForEach(0..<3) { index in
                let wallpaper = index == 0 ? "Display" : nil
                let status = AquariumToy.closedStatus(wallpaper: wallpaper, connected: ["Display"],
                                                       saverMinutes: index == 1 ? 10 : 0)
                StatusBadge(status.text, tint: status.tint)
            }
        }.padding(20).background(Color(nsColor: .windowBackgroundColor))
        try ProofRender.write(chips, size: CGSize(width: 580, height: 170), name: "t1-aquarium-closed-chips")
    }

    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func snailSleepGrowsAsItRises() throws {
        let tank = AquariumView(fixture: AquariumView.Fixture(fish: [], night: 1))
        var snail = SnailSim(x: 0.5)
        snail.napLeft = 30
        let sleeping = snail
        let phases: [Double] = [0.15, 0.5, 0.8]
        let image = HStack(spacing: 4) {
            ForEach(phases, id: \.self) { phase in
                Canvas { canvas, size in
                    let t = phase * 2.6
                    tank.drawWater(canvas: &canvas, size: size, t: t)
                    tank.drawSand(canvas: &canvas, size: size, t: t)
                    tank.drawSnailBody(canvas: &canvas, size: size, t: t, sim: sleeping)
                }
                .frame(width: 160, height: 200)
            }
        }
        let renderer = ImageRenderer(content: image)
        renderer.scale = 4
        let rendered = try #require(renderer.cgImage)
        let bitmap = NSBitmapImageRep(cgImage: rendered)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(at: ProofRender.directory, withIntermediateDirectories: true)
        try data.write(to: ProofRender.directory.appendingPathComponent("t1-snail-sleep-phases.png"))
    }

    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func fishMenuRendersWithoutAPlaceholder() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fish = Fish(id: "sample", label: "Review", providerID: "codex", state: .idling,
                        lane: 0.5, speed: 0.1, direction: 1, stateSince: now)
        let tank = AquariumView(fixture: AquariumView.Fixture(fish: [fish], night: 0))
        let buttons = HStack(spacing: 28) {
            tank.fishMenu([fish])
            tank.fishMenu([])
        }.padding(24).background(Color(red: 0.02, green: 0.12, blue: 0.22))
        let bitmap = try ProofRender.render(buttons, size: CGSize(width: 180, height: 90), scale: 2)
        var placeholderYellow = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.redComponent > 0.8 && color.greenComponent > 0.7 && color.blueComponent < 0.3 {
                    placeholderYellow += 1
                }
            }
        }
        #expect(placeholderYellow == 0)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(at: ProofRender.directory, withIntermediateDirectories: true)
        try data.write(to: ProofRender.directory.appendingPathComponent("t1-fish-menu-live-empty.png"))
    }

    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func shopCategoriesAndGoals() throws {
        var game = AquariumGame()
        game.pearls = 900
        game.lifetimePearls = 5200
        game.inventory[ShopItem.plant.rawValue] = 1
        let tank = AquariumView(fixture: AquariumView.Fixture(fish: [], game: game, night: 0))
        try ProofRender.write(tank.shopPanel(fish: []).background(Color(nsColor: .windowBackgroundColor)), size: CGSize(width: 380, height: 480), name: "t1-shop-decor")
        try ProofRender.write(tank.goalsShelf(game: game).padding(16).background(Color(nsColor: .windowBackgroundColor)), size: CGSize(width: 380, height: 480), name: "t1-shop-goals")
    }
}
