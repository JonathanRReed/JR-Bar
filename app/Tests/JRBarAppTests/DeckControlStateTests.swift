import Foundation
import Testing
@testable import JRBarCore
@testable import JRBarApp

@Suite("Deck control state")
@MainActor
struct DeckControlStateTests {
    static let layer = DeckKeymapLayer(profile: 0, layer: 0, scope: "automatic")

    static func store() -> DeckStore {
        let core = CoreModel(socketPath: NSTemporaryDirectory() + "jrbar-deck-control-test.sock")
        core.handle(.connected)
        let deck = DeckState(
            device: DeckDevice(connected: true, approved: true),
            keymap: DeckKeymap(layers: [layer]), scopes: ["claude", "codex"])
        core.apply(.state(CoreState(deck: deck)))
        return DeckStore(core: core)
    }

    static func reviewedPlan() -> DeckKeymapPlan? {
        DeckKeymapPlan(.object(["preview": .string("Synthetic review"), "changes": .array([])]))
    }

    @Test("changing a layer scope retires the previous review immediately")
    func scopeInvalidatesReview() {
        let store = Self.store()
        store.sheet = .apply
        store.applyLayer = Self.layer
        store.plan = Self.reviewedPlan()
        #expect(store.canApplyKeymap)
        store.setApplyScope("codex", for: Self.layer)
        #expect(store.applyScope(for: Self.layer) == "codex")
        #expect(store.plan == nil)
        #expect(store.planLoading)
        #expect(!store.canApplyKeymap)
        store.confirmSheet()
        #expect(!store.sheetBusy, "an unreviewed selection sends nothing")
        store.closeSheet()
    }

    @Test("closing the window cancels its pending review")
    func closedWindowCancelsReview() {
        let store = Self.store()
        store.sheet = .apply
        store.applyLayer = Self.layer
        store.loadPlan()
        #expect(store.planLoading)
        store.windowDidClose()
        #expect(store.sheet == nil)
        #expect(!store.planLoading)
        #expect(store.plan == nil)
    }

    @Test("Apply cannot repeat a transfer or use a disconnected pad")
    func applyGates() {
        let store = Self.store()
        store.sheet = .apply
        store.plan = Self.reviewedPlan()
        #expect(store.canApplyKeymap)
        store.sheetBusy = true
        #expect(!store.canApplyKeymap)
        store.confirmSheet()
        #expect(store.sheetBusy)
        #expect(store.core.inFlightCommands == 0)
        store.sheetBusy = false
        store.core.handle(.disconnected(reason: "Synthetic disconnect"))
        #expect(!store.canApplyKeymap)
        store.confirmSheet()
        #expect(!store.sheetBusy)
    }

    @Test("dial edits keep analog mappings while analog input is paused")
    func dormantAnalogBindings() {
        let saved = [DeckBinding(index: 20, action: "open_usage"), DeckBinding(index: 23, action: "next_bank")]
        let payload = DeckStore.auxBindings(
            controls: [DeckAuxControl(index: 13, label: "Dial", mapping: "previous_bank")], analog: [],
            changing: 13, to: "next_bank", saved: saved)
        #expect(payload.map(\.index) == [13, 20, 23])
        #expect(payload.first { $0.index == 13 }?.action == "next_bank")
        #expect(payload.first { $0.index == 20 }?.action == "open_usage")
        #expect(payload.first { $0.index == 23 }?.action == "next_bank")
    }

    @Test("closing a transferring window keeps the transfer busy when reopened")
    func closingKeepsTransferBusy() {
        let store = Self.store()
        store.sheet = .apply
        store.sheetBusy = true
        store.windowDidClose()
        #expect(store.sheet == nil)
        #expect(store.sheetBusy)
        store.openApplySheet()
        store.openRestoreSheet()
        store.openClearAbsentSheet()
        #expect(store.sheet == nil, "the pending transfer cannot start another sheet")
    }

    @Test("visible analog rows win without duplicating saved bindings")
    func visibleAnalogBindings() {
        let payload = DeckStore.auxBindings(controls: [],
            analog: [DeckAuxControl(index: 20, label: "Analog", mapping: "open_usage")],
            changing: 20, to: nil, saved: [DeckBinding(index: 20, action: "next_bank")])
        #expect(payload.count == 1)
        #expect(payload.first?.index == 20)
        #expect(payload.first?.action == nil)
    }

    @Test("a held rail pill follows a replaced ask and then the cleared slot")
    func railPillUsesCurrentAsk() {
        let core = CoreModel()
        let slot = DeckSlot(index: 0, session: "claude:synthetic", label: "Synthetic session", state: .inputRequired)
        let deck = DeckState(slots: [slot])
        core.apply(.state(CoreState(asks: [CoreAsk(session: "claude:synthetic", summary: "First ask", request: "first")], deck: deck)))
        let store = DeckStore(core: core)
        let first = DeckRailPillContent(store: store, cell: 0)
        #expect(first.ask?.request == "first")
        core.apply(.state(CoreState(asks: [CoreAsk(session: "claude:synthetic", summary: "Next ask", request: "next")], deck: deck)))
        let next = DeckRailPillContent(store: store, cell: 0)
        #expect(next != first)
        #expect(next.ask?.request == "next")
        #expect(next.detail == "Next ask")
        core.apply(.state(CoreState(deck: DeckState())))
        let cleared = DeckRailPillContent(store: store, cell: 0)
        #expect(cleared.ask == nil)
        #expect(cleared.detail == nil)
    }
}
