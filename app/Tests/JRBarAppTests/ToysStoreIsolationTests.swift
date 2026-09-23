import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// The real aquarium save is opt-in: only the app's own store asks for
/// it. Any other store — headless or not, however a suite builds it —
/// must never read or write the user's real tank.
@Suite("Toys store isolation")
@MainActor
struct ToysStoreIsolationTests {
    @Test("a store with the runtime on still keeps a scratch tank unless told otherwise")
    func defaultSaveIsScratch() {
        let core = CoreModel()
        // Built the way the buddy suites build theirs: no runtime flag.
        let store = ToysStore(core: core, settings: SettingsStore(core: core), state: ToysState(),
                              cardModel: makeTestCardModel())
        #expect(store.aquarium?.saveLocation != AquariumSaveFile.defaultURL())
        #expect(store.aquarium?.saveLocation.path.hasPrefix(
            FileManager.default.temporaryDirectory.path) == true)
        let tank = AquariumToy(core: core, store: store)
        #expect(tank.saveLocation != AquariumSaveFile.defaultURL(), "the toy's own default too")
        #expect(tank.saveLocation != store.aquarium?.saveLocation, "each scratch is its own")
        store.notch.shutdown()
    }

    @Test("a headless store's tank never saves to the real state directory")
    func headlessSave() {
        let core = CoreModel()
        let store = ToysStore(core: core, settings: SettingsStore(core: core), state: ToysState(),
                              cardModel: makeTestCardModel(), notchRuntimeEnabled: false)
        #expect(store.aquarium?.saveLocation != AquariumSaveFile.defaultURL())
        #expect(store.aquarium?.saveLocation.path.hasPrefix(
            FileManager.default.temporaryDirectory.path) == true)
    }

    @Test("an explicit save file wins")
    func explicitSave() {
        let core = CoreModel()
        let url = FileManager.default.temporaryDirectory
            .appending(path: "jrbar-explicit-\(UUID().uuidString)")
            .appending(path: "aquarium-save.json")
        let store = ToysStore(core: core, settings: SettingsStore(core: core), state: ToysState(),
                              cardModel: makeTestCardModel(), notchRuntimeEnabled: false,
                              aquariumSave: AquariumSaveFile(url: url))
        #expect(store.aquarium?.saveLocation == url)
    }
}
