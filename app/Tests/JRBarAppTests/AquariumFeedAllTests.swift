import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// "Feed the tank" from outside the window: one pellet round to every
/// fish that can eat, exactly as if each were tapped — the daily cap
/// still counts. The toy saves to a scratch file here, never the real
/// state directory.
@Suite("Aquarium feed from anywhere")
@MainActor
struct AquariumFeedAllTests {
    private func scratch() -> AquariumSaveFile {
        AquariumSaveFile(url: FileManager.default.temporaryDirectory
            .appending(path: "jrbar-feedall-\(UUID().uuidString)")
            .appending(path: "aquarium-save.json"))
    }

    @Test("every fish that can eat gets one pellet; fry and the sinking don't")
    func feedsEveryFish() {
        let core = CoreModel()
        core.apply(.state(CoreState(sessions: [
            CoreSession(id: "a", provider: "claude", mode: "tool_running", lifecycle: "active"),
            CoreSession(id: "b", provider: "codex", mode: "idle_ready", lifecycle: "active"),
            CoreSession(id: "w", provider: "claude", kind: "worker", parent: "a",
                        mode: "tool_running", lifecycle: "active"),
            CoreSession(id: "x", provider: "gemini", lifecycle: "failed"),
        ])))
        let store = ToysStore(core: core, settings: SettingsStore(core: core), state: ToysState(),
                              cardModel: makeTestCardModel(), notchRuntimeEnabled: false)
        let file = scratch()
        defer { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }
        let tank = AquariumToy(core: core, store: store, saveFile: file)
        let now = Date()
        #expect(tank.feedAll(at: now) == 2)
        #expect(tank.game.pets["a"]?.feedings == 1)
        #expect(tank.game.pets["b"]?.feedings == 1)
        #expect(tank.game.pets["w"] == nil, "fry ride with their parent")
        #expect(tank.game.pets["x"] == nil, "a sinking fish isn't hungry")
        #expect(file.exists, "the round is saved")
    }

    @Test("rounds from afar still hit the daily cap")
    func capHolds() {
        let core = CoreModel()
        core.apply(.state(CoreState(sessions: [
            CoreSession(id: "a", provider: "claude", mode: "tool_running", lifecycle: "active"),
        ])))
        let store = ToysStore(core: core, settings: SettingsStore(core: core), state: ToysState(),
                              cardModel: makeTestCardModel(), notchRuntimeEnabled: false)
        let file = scratch()
        defer { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }
        let tank = AquariumToy(core: core, store: store, saveFile: file)
        let now = Date()
        for _ in 0..<(AquariumRules.feedingsPerFishPerDay + 5) { tank.feedAll(at: now) }
        #expect(tank.game.pets["a"]?.feedings == AquariumRules.feedingsPerFishPerDay)
    }

    @Test("an empty tank feeds nobody")
    func emptyTank() {
        let core = CoreModel()
        let store = ToysStore(core: core, settings: SettingsStore(core: core), state: ToysState(),
                              cardModel: makeTestCardModel(), notchRuntimeEnabled: false)
        let file = scratch()
        let tank = AquariumToy(core: core, store: store, saveFile: file)
        let residents = tank.fish.count
        #expect(tank.feedAll() == residents)
        try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent())
    }
}
