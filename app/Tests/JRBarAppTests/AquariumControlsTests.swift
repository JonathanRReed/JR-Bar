import AppKit
import Foundation
import SwiftUI
import Testing
import JRBarCore
@testable import JRBarApp

/// The Aquarium card: it renders folded and open, its Look menu names
/// what the tank wears, a search hit inside Fine-tune names a row the
/// card really draws, and the new day/night modes reach the water.
@Suite("Aquarium controls")
@MainActor
struct AquariumControlsTests {
    private func scratch() -> AquariumSaveFile {
        AquariumSaveFile(url: FileManager.default.temporaryDirectory
            .appending(path: "jrbar-controls-\(UUID().uuidString)")
            .appending(path: "aquarium-save.json"))
    }

    private func makeToy(_ game: AquariumGame? = nil) throws -> (AquariumToy, ToysStore, AquariumSaveFile) {
        let core = CoreModel()
        let store = ToysStore(core: core, settings: SettingsStore(core: core), state: ToysState(),
                              cardModel: makeTestCardModel(), notchRuntimeEnabled: false)
        let file = scratch()
        if let game { try file.save(AquariumSave(game: game)) }
        return (AquariumToy(core: core, store: store, saveFile: file), store, file)
    }

    private func height(of view: some View) throws -> Int {
        let renderer = ImageRenderer(content: view
            .padding(16)
            .frame(width: 560, alignment: .top)
            .fixedSize(horizontal: false, vertical: true))
        renderer.scale = 1
        return try #require(renderer.cgImage).height
    }

    @Test("the card renders with Fine-tune folded and open, and open is taller")
    func rendersBothWays() throws {
        let (toy, store, file) = try makeToy()
        defer { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }
        let folded = try height(of: AquariumControlsView(toy: toy))
        let open = try height(of: AquariumControlsView(toy: toy, fineTune: true))
        #expect(folded > 200)
        #expect(open > folded + 150, "Fine-tune's rows show when it's open")
        withExtendedLifetime(store) {}
    }

    @Test("the Look menu names what the tank wears, or Classic")
    func lookSummary() throws {
        var game = AquariumGame(lifetimePearls: 5000)
        for item in [ShopItem.themeMidnight, .gravelBlack, .rockyBackdrop] {
            game.inventory[item.rawValue] = 1
        }
        game.themeID = "midnight"
        game.substrateID = "black"
        let (toy, store, file) = try makeToy(game)
        defer { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }
        #expect(AquariumLookMenu(toy: toy).summary == "Midnight · Black gravel")
        toy.useSurface(.wall, id: "rocky")
        #expect(AquariumLookMenu(toy: toy).summary == "Midnight · Black gravel · Rocky backdrop")
        toy.useSurface(.water, id: "classic")
        toy.useSurface(.floor, id: "classic")
        toy.useSurface(.wall, id: "classic")
        #expect(AquariumLookMenu(toy: toy).summary == "Classic")
        #expect(toy.game.themeID == "classic")
        // An id nobody owns changes nothing.
        toy.useSurface(.water, id: "abyss")
        #expect(toy.game.themeID == "classic")
        withExtendedLifetime(store) {}
    }

    @Test("every Fine-tune title the reveal opens for is a searchable row, the swim rows included")
    func fineTuneTitles() {
        let listed = Set((ToySearchCatalog.rows["aquarium"] ?? []).map(\.title))
        for title in AquariumControlsView.fineTuneTitles {
            #expect(listed.contains(title), "\(title) is searchable")
        }
    }

    @Test("a search hit inside the aquarium card names its row to the store")
    func revealRow() {
        let core = CoreModel()
        let settings = SettingsStore(core: core)
        let toys = ToysStore(core: core, settings: settings, state: ToysState(),
                             cardModel: makeTestCardModel(), notchRuntimeEnabled: false)
        settings.toys = toys
        #expect(toys.revealRow == nil)
        let hit = SettingsSearch.search("bubbles", in: settings.searchEntries).first
        #expect(hit?.card == "aquarium")
        settings.reveal(hit!)
        #expect(toys.revealRow == "Bubbles")
        #expect(AquariumControlsView.fineTuneTitles.contains(toys.revealRow ?? ""))
        settings.reveal(SettingsSearchEntry(.notifications, "Power", "Lid closed"))
        #expect(toys.revealRow == nil, "a row outside a card opens nothing")
    }

    @Test("Always day and Always night pin the water; Follow Light & Dark eases its flips")
    func dayNightModes() {
        var settings = AquariumSettings()
        settings.dayNight = .alwaysNight
        let night = AquariumView(fixture: .init(fish: [], settings: settings))
        #expect(night.nightFactor(t: 1_800_000_000) == 1)
        settings.dayNight = .alwaysDay
        let day = AquariumView(fixture: .init(fish: [], settings: settings))
        #expect(day.nightFactor(t: 1_800_000_000) == 0)
        AquariumNightEase.reset()
        defer { AquariumNightEase.reset() }
        #expect(AquariumNightEase.value(toward: 0, at: 100, still: false) == 0)
        #expect(AquariumNightEase.value(toward: 1, at: 101, still: false) == 0, "a flip starts from where it was")
        let mid = AquariumNightEase.value(toward: 1, at: 102, still: false)
        #expect(mid > 0.2 && mid < 0.8)
        #expect(AquariumNightEase.value(toward: 1, at: 103.5, still: false) == 1)
        #expect(AquariumNightEase.value(toward: 0, at: 104, still: true) == 0, "Reduce Motion lands at once")
    }

    @Test("a Light & Dark flip quickens the water's still passes until the ease lands")
    func nightEaseTicks() {
        AquariumNightEase.reset()
        defer { AquariumNightEase.reset() }
        _ = AquariumNightEase.value(toward: 0, at: 100, still: false)
        #expect(!AquariumNightEase.isEasing(at: 100))
        #expect(AquariumNightEase.stillTick(flipAt: nil, at: 100) == AquariumNightEase.restingTick)
        _ = AquariumNightEase.value(toward: 1, at: 101, still: false)
        #expect(AquariumNightEase.isEasing(at: 102))
        #expect(AquariumNightEase.stillTick(flipAt: 101, at: 101) == AquariumNightEase.easingTick)
        #expect(AquariumNightEase.easingTick <= 1.0 / 10, "the water eases, not steps")
        #expect(!AquariumNightEase.isEasing(at: 101 + AquariumNightEase.seconds))
        #expect(AquariumNightEase.stillTick(flipAt: 101, at: 110) == AquariumNightEase.restingTick)
    }
}
