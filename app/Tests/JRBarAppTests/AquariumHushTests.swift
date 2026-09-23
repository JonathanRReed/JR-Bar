import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// The Toys page's room rule, in the tank: while JR-Bar is quiet, a
/// Focus is on or a call has the mic, no toast, no reward card and no
/// visitor parade — but the game still counts every one, and the card
/// comes out once the room clears. Scratch save file, never the real one.
@Suite("Aquarium hush")
@MainActor
struct AquariumHushTests {
    private func scratch() -> AquariumSaveFile {
        AquariumSaveFile(url: FileManager.default.temporaryDirectory
            .appending(path: "jrbar-hush-\(UUID().uuidString)")
            .appending(path: "aquarium-save.json"))
    }

    private func fixture(fish: Int = 1) -> (AquariumToy, ToysStore, AquariumSaveFile) {
        let core = CoreModel()
        core.apply(.state(CoreState(sessions: (0..<fish).map {
            CoreSession(id: "s\($0)", provider: "claude", mode: "idle_ready", lifecycle: "active")
        })))
        let store = ToysStore(core: core, settings: SettingsStore(core: core), state: ToysState(),
                              cardModel: makeTestCardModel(), notchRuntimeEnabled: false)
        let file = scratch()
        return (AquariumToy(core: core, store: store, saveFile: file), store, file)
    }

    @Test("a queued visitor's toast is dropped while on a call; the visitor still waits")
    func toastDropped() {
        let (tank, store, file) = fixture()
        defer { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }
        store.noteCallPresence(true)
        #expect(tank.hushed)
        tank.noteEvent(CoreEvent(id: "r1", kind: "quota_reset"))
        #expect(tank.toast == nil)
        #expect(tank.game.pendingVisitors.contains(.submarine), "the parade is held, not lost")
    }

    @Test("the same visitor in a clear room gets its toast")
    func toastInAClearRoom() {
        let (tank, _, file) = fixture()
        defer { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }
        #expect(!tank.hushed)
        tank.noteEvent(CoreEvent(id: "r1", kind: "quota_reset"))
        #expect(tank.toast != nil)
    }

    @Test("a reward card waits out the call and comes out when it ends")
    func cardHeld() {
        let (tank, store, file) = fixture(fish: 10)
        defer { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }
        store.noteCallPresence(true)
        let now = Date()
        // Ten rounds to ten fish: a hundred pellets, an achievement.
        for _ in 0..<10 { tank.feedAll(at: now) }
        #expect(tank.game.unlocked[AquariumAchievement.hundredPellets.rawValue] != nil,
                "the game counted it")
        #expect(tank.notice == nil)
        tank.roomChanged(at: now)
        #expect(tank.notice == nil, "still on the call")
        store.noteCallPresence(false)
        tank.roomChanged(at: now)
        #expect(tank.notice != nil)
    }

    @Test("with the page's switch off the room is ignored")
    func switchOff() {
        let (tank, store, file) = fixture()
        defer { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }
        store.state.hushDuringQuiet = false
        store.noteCallPresence(true)
        #expect(!tank.hushed)
        tank.noteEvent(CoreEvent(id: "r1", kind: "quota_reset"))
        #expect(tank.toast != nil)
    }
}
