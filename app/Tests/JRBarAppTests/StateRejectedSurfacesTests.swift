import Foundation
import Testing
@testable import JRBarApp
@testable import JRBarCore

/// What the person sees while the monitor's newest update could not be read:
/// the header count, the status item's tooltip text and the connection chip.
@Suite("State rejected surfaces")
@MainActor
struct StateRejectedSurfacesTests {
    private func store() -> (PanelStore, CoreModel) {
        let core = CoreModel(socketPath: "/tmp/jrbar-test-none.sock")
        core.handle(.connected)
        core.apply(.state(CoreState(
            sessions: [CoreSession(id: "claude:a", provider: "claude", mode: "working")])))
        let store = PanelStore(core: core,
                               draftsDefaults: UserDefaults(suiteName: ScratchDefaults.suiteName("jrbar.tests"))!,
                               screenBarShown: false)
        return (store, core)
    }

    @Test("the header, the dot and the chip say the update could not be read, then recover")
    func surfaces() {
        let (store, core) = store()
        #expect(store.connectionDot == .live)
        #expect(store.headerCounts != PanelStore.stateRejectedDetail)

        core.handle(.stateRejected("frame of 2000000 bytes exceeds 1048576"))
        #expect(store.connectionDot == .fileFeeds)
        #expect(store.headerCounts == PanelStore.stateRejectedDetail)
        #expect(store.connectionDescription.contains("could not be read"))
        // The decoder's own words stay in the log.
        #expect(!store.connectionDescription.contains("2000000"))

        core.apply(.state(CoreState(
            sessions: [CoreSession(id: "claude:a", provider: "claude", mode: "working")])))
        #expect(store.connectionDot == .live)
        #expect(store.headerCounts != PanelStore.stateRejectedDetail)
    }
}
