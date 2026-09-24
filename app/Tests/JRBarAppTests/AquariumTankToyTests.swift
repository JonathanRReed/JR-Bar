import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// The tank toy's own housekeeping, on a scratch save: the care records
/// stay trimmed even while the window is closed.
@Suite("Aquarium tank toy")
@MainActor
struct AquariumTankToyTests {
    private func scratch() -> AquariumSaveFile {
        AquariumSaveFile(url: FileManager.default.temporaryDirectory
            .appending(path: "jrbar-tank-\(UUID().uuidString)")
            .appending(path: "aquarium-save.json"))
    }

    private func store(_ core: CoreModel) -> ToysStore {
        ToysStore(core: core, settings: SettingsStore(core: core), state: ToysState(),
                  cardModel: makeTestCardModel(), notchRuntimeEnabled: false)
    }

    @Test("a closed tank trims an overgrown save to the cap as the sessions refresh")
    func refreshPrunes() throws {
        let file = scratch()
        defer { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }
        var game = AquariumGame()
        for i in 0..<799 { game.pets["p\(i)"] = FishCare(createdAt: Double(i)) }
        game.pets["raised"] = FishCare(stage: 2, createdAt: 0, label: "Nemo", provider: "claude")
        try file.save(AquariumSave(game: game))
        let core = CoreModel()
        let toys = store(core)
        let tank = AquariumToy(core: core, store: toys, saveFile: file)
        #expect(!tank.isOn)
        #expect(tank.game.pets.count == AquariumRules.maxPets)
        #expect(tank.game.pets["raised"] != nil, "the resident stays")
        #expect(file.load().game.pets.count == AquariumRules.maxPets, "the trim is saved")
        withExtendedLifetime(toys) {}
    }
}
