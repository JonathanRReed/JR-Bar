import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// A headless store — every test builds one — must never write the
/// user's real state: its tank keeps a scratch save of its own.
@Suite("Toys store isolation")
@MainActor
struct ToysStoreIsolationTests {
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
