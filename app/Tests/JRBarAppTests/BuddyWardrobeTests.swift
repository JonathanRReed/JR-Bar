import AppKit
import Foundation
import SwiftUI
import Testing
import JRBarCore
@testable import JRBarApp

/// One purse across toys: the tank shop's buddy shelf sells what the
/// Notch Buddy wears, paid in the tank's pearls. It wears only what the
/// tank owns.
@Suite("Buddy wardrobe")
@MainActor
struct BuddyWardrobeTests {
    private func store(owning items: [ShopItem]) throws -> (ToysStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "jrbar-wardrobe-\(UUID().uuidString)")
        let file = AquariumSaveFile(url: dir.appending(path: "aquarium-save.json"))
        try file.save(AquariumSave(game: AquariumGame(
            inventory: Dictionary(uniqueKeysWithValues: items.map { ($0.rawValue, 1) }))))
        let core = CoreModel()
        var state = ToysState()
        state.notchBuddy.enabled = true
        let store = ToysStore(core: core, settings: SettingsStore(core: core), state: state,
                              cardModel: makeTestCardModel(), notchRuntimeEnabled: false,
                              aquariumSave: file)
        return (store, dir)
    }

    @Test("the buddy shelf: its own category, priced, never on a fish")
    func shelf() {
        let shelf = ShopItem.allCases.filter { $0.category == .buddy }
        #expect(shelf == [.buddyBeanie, .buddyBow, .buddyFlower])
        for item in shelf {
            #expect(item.price > 0)
            #expect(!item.isWearable, "\(item) is the buddy's, not a fish's")
        }
        var game = AquariumGame(pearls: 100)
        let effects = game.apply(.purchase(.buddyBow), now: Date())
        #expect(game.owns(.buddyBow))
        #expect(effects.contains(.pearlsSpent(ShopItem.buddyBow.price)), "the same purse")
        game.apply(.equipHat(.buddyBow, fishID: "f"), now: Date())
        #expect(game.hats.isEmpty, "a fish can't wear the buddy's bow")
    }

    @Test("it wears only what the tank owns")
    func ownership() throws {
        let (store, dir) = try store(owning: [.buddyBow])
        defer { try? FileManager.default.removeItem(at: dir) }
        let buddy = store.notchBuddy
        #expect(buddy.wearing == nil)
        store.state.notchBuddy.wearing = ShopItem.buddyFlower.rawValue
        #expect(buddy.wearing == nil, "not bought yet")
        buddy.wear(.buddyFlower)
        #expect(store.state.notchBuddy.wearing == ShopItem.buddyFlower.rawValue, "unchanged")
        buddy.wear(.buddyBow)
        #expect(buddy.wearing == .buddyBow)
        buddy.wear(.hatCrown)
        #expect(buddy.wearing == .buddyBow, "a fish hat stays in the tank")
        buddy.wear(nil)
        #expect(buddy.wearing == nil)
    }

    @Test("every piece draws something on the figure")
    func outfitsRender() throws {
        func render(_ item: ShopItem?) throws -> Data {
            let figure = BuddyFigure(character: .dot, mood: .pacing, tint: .accentColor, phase: 1,
                                     hopProgress: nil, waveAge: nil, slumpAge: nil, leans: false,
                                     still: true, askCount: 0, care: .content, trick: nil,
                                     treatAge: nil, crumbAge: nil, wearing: item)
                .frame(width: 30, height: 26)
            let renderer = ImageRenderer(content: figure)
            renderer.scale = 2
            let image = try #require(renderer.cgImage)
            let rep = NSBitmapImageRep(cgImage: image)
            return try #require(rep.representation(using: .png, properties: [:]))
        }
        let bare = try render(nil)
        for item in [ShopItem.buddyBeanie, .buddyBow, .buddyFlower] {
            #expect(try render(item) != bare, "\(item) drew nothing")
        }
    }

    @Test("the setting reads tolerantly")
    func setting() throws {
        #expect(NotchBuddySettings().wearing == nil)
        let blank = try JSONDecoder().decode(NotchBuddySettings.self, from: Data(#"{"wearing": ""}"#.utf8))
        #expect(blank.wearing == nil)
        let bow = try JSONDecoder().decode(NotchBuddySettings.self, from: Data(#"{"wearing": "buddyBow"}"#.utf8))
        #expect(bow.wearing == "buddyBow")
    }
}
