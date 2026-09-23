import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// The tank reads the fleet from every document it sees: a milestone
/// about the work lands as a reward card and saves at once. The store
/// here watches an empty core of its own, so its tank (the real save
/// file) never sees these sessions; the tank under test saves to scratch.
@Suite("Aquarium fleet on the tank")
@MainActor
struct AquariumFleetToyTests {
    @Test("a school of six in the document: the card, the pearls, the save")
    func schoolOnTheTank() {
        let core = CoreModel()
        var sessions = [CoreSession(id: "a", provider: "claude", mode: "tool_running", lifecycle: "active")]
        sessions += (0..<6).map {
            CoreSession(id: "a\($0)", provider: "claude", kind: "worker", parent: "a",
                        mode: "tool_running", lifecycle: "active")
        }
        core.apply(.state(CoreState(sessions: sessions)))
        let quiet = CoreModel()
        let store = ToysStore(core: quiet, settings: SettingsStore(core: quiet), state: ToysState(),
                              cardModel: makeTestCardModel(), notchRuntimeEnabled: false)
        let file = AquariumSaveFile(url: FileManager.default.temporaryDirectory
            .appending(path: "jrbar-fleet-\(UUID().uuidString)")
            .appending(path: "aquarium-save.json"))
        defer { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }
        let tank = AquariumToy(core: core, store: store, saveFile: file)
        #expect(tank.game.unlocked[AquariumAchievement.school.rawValue] != nil)
        #expect(tank.notice?.title == AquariumAchievement.school.title
                || tank.notice?.title == AquariumAchievement.firstPearl.title)
        #expect(tank.game.lifetimePearls >= AquariumAchievement.school.reward)
        #expect(file.exists, "a milestone saves at once")
        #expect(file.load().game.fleet.largestSchool == 6)
    }
}
