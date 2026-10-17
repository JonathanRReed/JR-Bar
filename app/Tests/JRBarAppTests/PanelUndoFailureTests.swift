import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

@MainActor
@Suite("Panel Undo failure ownership")
struct PanelUndoFailureTests {
    @Test("an expired or missing batch is not offered for another retry", arguments: ["expired", "not_found"])
    func terminalRefusalRetiresOffer(_ code: String) async {
        let suite = ScratchDefaults.suiteName("panel-undo-terminal")
        defer { ScratchDefaults.remove(suite) }
        let store = PanelStore(core: CoreModel(), draftsDefaults: ScratchDefaults.open(suite), screenBarShown: false)
        store.undoOffer = ("gone", Date(), 1)
        store.sendUndoClear = { _ in
            CoreReply(id: "fixture", ok: false, error: CoreReplyError(code: code, message: "Synthetic terminal refusal"))
        }
        store.undoClear()
        await store.undoTask?.value
        #expect(store.undoOffer == nil)
        #expect(store.toast == "Undo failed: Synthetic terminal refusal")
    }

    @Test("a refused or disconnected Undo keeps the eligible offer for retry", arguments: [false, true])
    func failureKeepsOffer(_ disconnected: Bool) async {
        let suite = ScratchDefaults.suiteName("panel-undo-failure")
        defer { ScratchDefaults.remove(suite) }
        let store = PanelStore(core: CoreModel(), draftsDefaults: ScratchDefaults.open(suite), screenBarShown: false)
        store.undoOffer = ("old", Date(), 3)
        store.sendUndoClear = { batch in
            #expect(batch == "old")
            if disconnected { throw CoreClientError.notConnected }
            return CoreReply(id: "fixture", ok: false)
        }
        store.undoClear()
        #expect(store.undoOffer == nil)
        await store.undoTask?.value
        #expect(store.undoOffer?.batch == "old")
        #expect(store.canUndoClear)
        #expect(store.toast?.hasPrefix("Undo failed:") == true)
        store.sendUndoClear = { _ in CoreReply(id: "fixture-retry", ok: true) }
        store.undoClear()
        await store.undoTask?.value
        #expect(store.undoOffer == nil)
        #expect(store.toast == "Restored 3 sessions")
    }

    @Test("a failed older Undo cannot restore over a newer offer or its retirement",
          .timeLimit(.minutes(1)), arguments: [false, true])
    func newerOfferOwnsSlot(_ retireNewOffer: Bool) async {
        let suite = ScratchDefaults.suiteName("panel-undo-newer")
        defer { ScratchDefaults.remove(suite) }
        let store = PanelStore(core: CoreModel(), draftsDefaults: ScratchDefaults.open(suite), screenBarShown: false)
        store.undoOffer = ("old", Date(), 3)
        var completion: CheckedContinuation<CoreReply, Never>?
        store.sendUndoClear = { _ in await withCheckedContinuation { completion = $0 } }
        store.undoClear()
        while completion == nil { await Task.yield() }
        store.undoOffer = ("new", Date(), 1)
        if retireNewOffer { store.undoOffer = nil }
        store.toast = "Current action feedback"
        completion?.resume(returning: CoreReply(id: "fixture", ok: false))
        await store.undoTask?.value
        #expect(store.undoOffer?.batch == (retireNewOffer ? nil : "new"))
        #expect(store.toast == "Current action feedback")
    }

    @Test("an expired offer is not restored after a failure")
    func expiredOfferStaysGone() async {
        let suite = ScratchDefaults.suiteName("panel-undo-expired")
        defer { ScratchDefaults.remove(suite) }
        let store = PanelStore(core: CoreModel(), draftsDefaults: ScratchDefaults.open(suite), screenBarShown: false)
        let old = Date().addingTimeInterval(-EventPolicy.undoWindow - 1)
        store.now = old
        store.undoOffer = ("expired", old, 1)
        store.sendUndoClear = { _ in CoreReply(id: "fixture", ok: false) }
        store.undoClear()
        await store.undoTask?.value
        #expect(store.undoOffer == nil)
    }

    @Test("starting another Clear retires the older pending Undo even before a new offer lands",
          .timeLimit(.minutes(1)))
    func newerClearRetiresUndo() async {
        let suite = ScratchDefaults.suiteName("panel-undo-new-clear")
        defer { ScratchDefaults.remove(suite) }
        let store = PanelStore(core: CoreModel(), draftsDefaults: ScratchDefaults.open(suite), screenBarShown: false)
        store.undoOffer = ("old", Date(), 1)
        var completion: CheckedContinuation<CoreReply, Never>?
        store.sendUndoClear = { _ in await withCheckedContinuation { completion = $0 } }
        store.sendClearCompleted = { _ in CoreReply(id: "fixture-clear", ok: true) }
        store.undoClear()
        while completion == nil { await Task.yield() }
        let row = SessionRow(session: CoreSession(id: "claude:done", provider: "claude", mode: "done",
                                                  lifecycle: "ended"), pinnedAsk: nil)
        store.clear(row)
        completion?.resume(returning: CoreReply(id: "fixture-old-undo", ok: false))
        await store.undoTask?.value
        #expect(store.undoOffer == nil)
        #expect(store.toast?.hasPrefix("Undo failed:") != true)
    }

    @Test("an older Clear reply cannot replace the newest Undo batch", .timeLimit(.minutes(1)))
    func newestClearOwnsUndoBatch() async {
        let suite = ScratchDefaults.suiteName("panel-clear-order")
        defer { ScratchDefaults.remove(suite) }
        let store = PanelStore(core: CoreModel(), draftsDefaults: ScratchDefaults.open(suite), screenBarShown: false)
        var replies: [CheckedContinuation<CoreReply, Never>] = []
        var finished: CheckedContinuation<Void, Never>?
        store.sendClearCompleted = { _ in
            let reply = await withCheckedContinuation { replies.append($0) }
            finished?.resume()
            return reply
        }
        let row = SessionRow(session: CoreSession(id: "claude:done", provider: "claude", mode: "done",
                                                  lifecycle: "ended"), pinnedAsk: nil)
        store.clear(row)
        while replies.count < 1 { await Task.yield() }
        store.clear(row)
        while replies.count < 2 { await Task.yield() }
        replies[1].resume(returning: CoreReply(id: "fixture-new", ok: true,
                                              result: .object(["batch": .string("new")])))
        while store.undoOffer?.batch != "new" { await Task.yield() }
        await withCheckedContinuation { continuation in
            finished = continuation
            replies[0].resume(returning: CoreReply(id: "fixture-old", ok: true,
                                                  result: .object(["batch": .string("old")])))
        }
        #expect(store.undoOffer?.batch == "new")
    }
}
