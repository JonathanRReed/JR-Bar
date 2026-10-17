import AppKit
import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// The tank toy's own housekeeping, on a scratch save: the care records
/// stay trimmed even while the window is closed.
@Suite("Aquarium tank toy")
@MainActor
struct AquariumTankToyTests {
    @Test("terminal shutdown saves current state and ignores later events or reactivation")
    func shutdownRetiresToy() throws {
        let file = scratch()
        defer { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }
        let core = CoreModel()
        let toys = store(core)
        let tank = AquariumToy(core: core, store: toys, saveFile: file)
        tank.shutdown()
        let saved = try Data(contentsOf: file.url)
        let game = tank.game
        #expect(tank.isShutdown)
        #expect(!tank.isOn && !tank.economyRunning)
        tank.noteEvent(CoreEvent(id: "after-shutdown", kind: "quota_reset", provider: "claude"))
        tank.isOn = true
        tank.stateReplaced()
        tank.syncGameTimer()
        tank.shutdown()
        #expect(tank.game == game)
        #expect(!tank.isOn && !tank.economyRunning)
        let persisted = try Data(contentsOf: file.url)
        #expect(persisted == saved)
        withExtendedLifetime(toys) {}
    }

    @Test("shutdown also retires observation changes already queued by the core", .timeLimit(.minutes(1)))
    func shutdownRejectsQueuedRoster() async {
        let file = scratch()
        defer { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }
        let core = CoreModel()
        let toys = store(core)
        let tank = AquariumToy(core: core, store: toys, saveFile: file)
        core.apply(.state(CoreState(sessions: [CoreSession(id: "queued", provider: "claude", mode: "working")],
                                   asks: [])))
        tank.shutdown()
        let fish = tank.fish
        let game = tank.game
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { done.resume() }
        }
        #expect(tank.fish == fish)
        #expect(tank.game == game)
        #expect(!tank.economyRunning)
        withExtendedLifetime(toys) {}
    }
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
        game.hats["p3"] = ShopItem.hatCrown.rawValue
        try file.save(AquariumSave(game: game))
        let core = CoreModel()
        // "p3" is an old, small record, first in line — but its session
        // is listed, so it stays, hat and all.
        core.apply(.state(CoreState(sessions: [CoreSession(id: "p3", provider: "claude", mode: "working")],
                                    asks: [])))
        let toys = store(core)
        let tank = AquariumToy(core: core, store: toys, saveFile: file)
        #expect(!tank.isOn)
        #expect(tank.game.pets.count == AquariumRules.maxPets)
        #expect(tank.game.pets["raised"] != nil, "the resident stays")
        #expect(tank.game.pets["p3"] != nil, "a live session's record stays")
        #expect(tank.game.hats["p3"] == ShopItem.hatCrown.rawValue, "and so does its hat")
        #expect(tank.game.pets["p0"] == nil, "the oldest passer-by goes")
        tank.flushSave()
        #expect(file.load().game.pets.count == AquariumRules.maxPets, "the trim is saved")
        withExtendedLifetime(toys) {}
    }

    @Test("before the core sends its first session list, nothing is trimmed")
    func noTrimBeforeTheCore() throws {
        let file = scratch()
        defer { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }
        var game = AquariumGame()
        for i in 0..<799 { game.pets["p\(i)"] = FishCare(createdAt: Double(i)) }
        game.hats["p0"] = ShopItem.hatCrown.rawValue
        try file.save(AquariumSave(game: game))
        let core = CoreModel()
        let toys = store(core)
        let tank = AquariumToy(core: core, store: toys, saveFile: file)
        #expect(tank.game.pets.count == 799, "every session looks gone without a list")
        #expect(tank.game.hats["p0"] == ShopItem.hatCrown.rawValue)
        tank.flushSave()
        #expect(file.load().game.pets.count == 799)
        withExtendedLifetime(toys) {}
    }

    @Test("quitting saves a game change still waiting for the next batch")
    func quitSavesCurrentGame() throws {
        let file = scratch()
        defer { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }
        var saved = AquariumGame()
        _ = saved.apply(.setWindowOpen(true), now: Date(timeIntervalSince1970: 1_000))
        try file.save(AquariumSave(game: saved))

        let core = CoreModel()
        let toys = store(core)
        let tank = AquariumToy(core: core, store: toys, saveFile: file)
        #expect(!tank.game.windowOpen)
        #expect(file.load().game.windowOpen)

        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
        #expect(!file.load().game.windowOpen)
        withExtendedLifetime(toys) {}
    }

    @Test("the work tick that opens the oyster says so, not just \"+1 pearl\"")
    func oysterToastWins() {
        let file = scratch()
        defer { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }
        let core = CoreModel()
        let toys = store(core)
        let tank = AquariumToy(core: core, store: toys, saveFile: file)
        let now = Date()
        // The work tick's own order, then the other way round.
        for batch: [AquariumGameEffect] in [[.pearlsEarned(1), .oysterReady],
                                            [.oysterReady, .pearlsEarned(2)]] {
            tank.dismissToast()
            tank.note(batch, now: now)
            #expect(tank.toast?.text == "The oyster opened — there's a pearl inside")
        }
        // A batch without the oyster still counts its pearls.
        tank.note([.pearlsEarned(3)], now: now)
        #expect(tank.toast?.text == "+3 pearls")
        withExtendedLifetime(toys) {}
    }

    @Test("a settings import that turns the tank off stops its economy")
    func importedOffStopsTheEconomy() throws {
        let toys = store(CoreModel())
        let tank = try #require(toys.aquarium)
        // On without a window: the tick runs, as it does after the switch.
        toys.state.aquarium.enabled = true
        tank.syncGameTimer()
        #expect(tank.economyRunning)
        var imported = toys.state
        imported.aquarium.enabled = false
        toys.replaceState(imported)
        #expect(!tank.isOn)
        #expect(!tank.economyRunning, "the imported off reached the toy, not just the state")
    }

    @Test("a toast's own timer clears that toast and never a newer one")
    func toastTimerClearsOnlyItsToast() throws {
        let file = scratch()
        defer { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }
        let toys = store(CoreModel())
        let tank = AquariumToy(core: CoreModel(), store: toys, saveFile: file)
        let first = Date(timeIntervalSince1970: 1_800_000_000)
        tank.note([.pearlsEarned(1)], now: first)
        tank.note([.pearlsEarned(2)], now: first.addingTimeInterval(4))
        tank.dismissToast(shownAt: first)
        #expect(tank.toast?.text == "+2 pearls", "the first toast's timer must not take the newer one")
        tank.dismissToast(shownAt: first.addingTimeInterval(4))
        #expect(tank.toast == nil)
        withExtendedLifetime(toys) {}
    }
}
