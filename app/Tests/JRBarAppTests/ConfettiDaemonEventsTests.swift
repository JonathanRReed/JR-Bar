import AppKit
import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// The daemon's two routes into the burst, end to end through the toy: a
/// `confetti` event (`jrbar confetti`, a hook, CI) is an outside request,
/// and a `milestone` event (the odometer crossing a step) is a trigger
/// under the Milestones switch. Overlays are replaced by a counter.
@Suite("Confetti from the daemon")
@MainActor
struct ConfettiDaemonEventsTests {
    private final class Bursts {
        var fired: [ConfettiPresentation] = []
        /// What the toy told the daemon, and what it logged.
        var receipts: [ConfettiResetReceipt] = []
        var lines: [String] = []
    }

    /// A connected daemon with nothing quiet in effect (`focus.mode` "off").
    private func makeToy(enabled: Bool = true, milestones: Bool = false) throws -> (ConfettiToy, ToysStore, Bursts) {
        let core = CoreModel()
        let off = try JSONDecoder().decode(CoreFocus.self, from: Data(#"{"mode": "off", "source": null, "until": null}"#.utf8))
        core.apply(.state(CoreState(focus: off)))
        var state = ToysState()
        state.confetti.enabled = enabled
        state.confetti.triggers.milestones = milestones
        let store = ToysStore(core: core, settings: SettingsStore(core: core), state: state,
                              cardModel: makeTestCardModel(), notchRuntimeEnabled: false)
        let toy = store.confetti
        let bursts = Bursts()
        toy.screensForBurst = { [nil] }
        toy.presentOverride = { bursts.fired.append($0) }
        toy.receiptSink = { bursts.receipts.append($0) }
        toy.logSink = { bursts.lines.append($0) }
        return (toy, store, bursts)
    }

    private func event(_ json: String) throws -> CoreEvent {
        try JSONDecoder().decode(CoreEvent.self, from: Data(json.utf8))
    }

    @Test("a recovered weekly reset reaches the burst once through the core model")
    func recoveredResetBurstsOnce() throws {
        let (toy, store, bursts) = try makeToy()
        store.core.onEvent = { toy.noteEvent($0) }
        let reset = CoreEvent(id: "ev-1", kind: "quota_reset", provider: "claude",
                              lane: "weekly", cursor: "stream:ev-1")
        store.core.apply(.event(reset))
        store.core.apply(.event(reset))
        #expect(bursts.fired.count == 1)
        #expect(store.state.confetti.firedKeys.contains("event:stream:ev-1"))
    }

    @Test("a journaled confetti request bursts once, and a repeat inside the cooldown does not")
    func requestEvent() throws {
        let (toy, store, bursts) = try makeToy()
        toy.noteEvent(try event(#"{"id":"ev-1","kind":"confetti","provider":"codex","cursor":"s:ev-1"}"#))
        #expect(bursts.fired.count == 1)
        toy.noteEvent(try event(#"{"id":"ev-2","kind":"confetti","cursor":"s:ev-2"}"#))
        #expect(bursts.fired.count == 1, "one burst per cooldown, however eager the script")
        _ = store
    }

    @Test("a request never fires while the toy is off; only the card's test does")
    func requestNeedsTheToy() throws {
        let (toy, store, bursts) = try makeToy(enabled: false)
        toy.noteEvent(try event(#"{"id":"ev-1","kind":"confetti"}"#))
        #expect(bursts.fired.isEmpty)
        _ = store
    }

    @Test("an odometer milestone bursts under the Milestones trigger, once per crossing")
    func milestoneEvent() throws {
        let milestone = try event(#"{"id":"ev-7","kind":"milestone","provider":"claude","count":50,"cursor":"s:ev-7"}"#)
        let (quiet, quietStore, quietBursts) = try makeToy()
        quiet.noteEvent(milestone)
        #expect(quietBursts.fired.isEmpty, "the Milestones trigger is opt-in")
        _ = quietStore

        let (toy, store, bursts) = try makeToy(milestones: true)
        toy.noteEvent(milestone)
        #expect(bursts.fired.count == 1)
        #expect(store.state.confetti.firedKeys.contains("event:s:ev-7"))
        toy.noteEvent(milestone)
        #expect(bursts.fired.count == 1, "a replayed crossing is already in the ring")
    }

    // MARK: A real reset must celebrate exactly once, and never be lost quietly

    /// A weekly reset as the daemon sends it, confirmed `ago` seconds back.
    private func weeklyReset(id: String = "claude:weekly:abc", ago: Double = 30,
                             cursor: String? = nil) -> CoreEvent {
        CoreEvent(id: cursor.map { _ in "ev-3" } ?? id, kind: "quota_reset",
                  at: Date().timeIntervalSince1970 - ago, provider: "claude", lane: "weekly", cursor: cursor, eventId: id)
    }

    @Test("a reset bursts once, tells the daemon it landed, and keys the fact, not the stream")
    func resetBurstsOnceAndSaysSo() throws {
        let (toy, store, bursts) = try makeToy()
        toy.noteEvent(weeklyReset(cursor: "run1:ev-3"))
        #expect(bursts.fired.count == 1)
        #expect(bursts.receipts == [ConfettiResetReceipt(eventID: "claude:weekly:abc",
                                                          outcome: .delivered, reason: "presented")])
        #expect(store.state.confetti.firedKeys.contains("event:claude:weekly:abc"))
        // The daemon restarted and the greet offered the same fact on a
        // new stream: not a second burst, and the daemon hears it is closed.
        toy.noteEvent(weeklyReset(cursor: "run2:ev-1"))
        #expect(bursts.fired.count == 1)
        #expect(bursts.receipts.last == ConfettiResetReceipt(
            eventID: "claude:weekly:abc", outcome: .dropped, reason: "already_celebrated"))
        #expect(bursts.lines.contains { $0.contains("quota_reset claude weekly") && $0.contains("delivered") })
    }

    @Test("overflow reconciles the omitted reset after the room clears")
    func overflowReconciles() async throws {
        let (toy, store, bursts) = try makeToy()
        store.noteCallPresence(true)
        var omitted: CoreEvent?
        for index in 0...ConfettiToy.maximumHeldFacts {
            let reset = try event("{\"id\":\"reset-\(index)\",\"kind\":\"quota_reset\",\"provider\":\"claude\",\"lane\":\"weekly\",\"event_id\":\"fact-\(index)\"}")
            if index == 0 { omitted = reset }
            toy.noteEvent(reset)
        }
        #expect(toy.needsResetReconciliation)
        var reads = 0
        let recovered = try #require(omitted)
        toy.readPendingResets = { reads += 1; return [recovered] }
        toy.reconcileResets()
        #expect(reads == 0, "a full held queue does not churn through daemon pages")
        store.noteCallPresence(false)
        await toy.waitForResetReconciliation()
        #expect(reads == 1)
        #expect(bursts.receipts.contains { $0.eventID == "fact-0" && $0.outcome == .delivered })
    }

    @Test("a reset the room holds is kept, not spent, and plays once the room clears")
    func heldResetIsNotSpent() throws {
        let (toy, store, bursts) = try makeToy()
        store.noteCallPresence(true)
        toy.noteEvent(weeklyReset())
        #expect(bursts.fired.isEmpty)
        #expect(bursts.receipts == [ConfettiResetReceipt(eventID: "claude:weekly:abc",
                                                          outcome: .held, reason: "call")])
        #expect(!store.state.confetti.firedKeys.contains("event:claude:weekly:abc"),
                "a held burst has not been celebrated: a quit now must leave it owed")
        // The same fact arriving again while it waits queues nothing.
        toy.noteEvent(weeklyReset(cursor: "run1:ev-3"))
        #expect(bursts.receipts.count == 1)
        store.noteCallPresence(false)
        #expect(bursts.fired.count == 1)
        #expect(bursts.receipts.last == ConfettiResetReceipt(
            eventID: "claude:weekly:abc", outcome: .delivered, reason: "after_hold"))
        #expect(store.state.confetti.firedKeys.contains("event:claude:weekly:abc"))
    }

    @Test("a dropped replay removes its held reset", arguments: [true, false])
    func droppedReplayCancelsHeldReset(triggerOff: Bool) throws {
        let (toy, store, bursts) = try makeToy()
        store.noteCallPresence(true)
        toy.noteEvent(weeklyReset())
        #expect(toy.isRecheckArmed)
        let reason = triggerOff ? "trigger_off" : "stale"
        if triggerOff { store.state.confetti.triggers.quotaReset = false }
        let age = triggerOff ? 30 : ConfettiTriggerPolicy.eventFreshnessWindow + 1
        toy.noteEvent(weeklyReset(ago: age, cursor: "next-stream:ev-1"))

        #expect(toy.held == nil)
        #expect(!toy.isRecheckArmed)
        #expect(store.state.confetti.firedKeys.contains("event:claude:weekly:abc"))
        #expect(bursts.receipts.last == ConfettiResetReceipt(
            eventID: "claude:weekly:abc", outcome: .dropped, reason: reason))
        #expect(bursts.receipts.count == 2)
        store.noteCallPresence(false)
        #expect(bursts.fired.isEmpty)
        #expect(bursts.receipts.count == 2, "a terminal drop cannot become a delivery")
    }

    @Test("dropping another reset preserves the held fact")
    func unrelatedDropPreservesHeldReset() throws {
        let (toy, store, bursts) = try makeToy()
        store.noteCallPresence(true)
        toy.noteEvent(weeklyReset())
        toy.noteEvent(weeklyReset(id: "claude:weekly:old", ago: ConfettiTriggerPolicy.eventFreshnessWindow + 1))
        #expect(toy.held?.facts.first?.key == "event:claude:weekly:abc")
        #expect(toy.isRecheckArmed)

        store.noteCallPresence(false)
        #expect(bursts.fired.count == 1)
        #expect(bursts.receipts.last == ConfettiResetReceipt(
            eventID: "claude:weekly:abc", outcome: .delivered, reason: "after_hold"))
    }

    @Test("a newer burst on a free screen also settles the fullscreen hold")
    func freshBurstReplacesFullscreenHold() throws {
        let (toy, store, bursts) = try makeToy()
        toy.screensForBurst = { [] }
        toy.noteEvent(weeklyReset())
        #expect(toy.held?.why == .fullscreen)
        #expect(toy.isRecheckArmed)

        toy.screensForBurst = { [nil] }
        toy.noteEvent(weeklyReset(id: "claude:weekly:new"))
        #expect(toy.held == nil)
        #expect(!toy.isRecheckArmed)
        #expect(bursts.fired.count == 1)
        #expect(bursts.fired.first?.densityScale == 1)
        #expect(bursts.receipts.suffix(2) == [
            ConfettiResetReceipt(eventID: "claude:weekly:abc", outcome: .delivered, reason: "after_hold"),
            ConfettiResetReceipt(eventID: "claude:weekly:new", outcome: .delivered, reason: "presented")
        ])
        #expect(store.state.confetti.firedKeys.contains("event:claude:weekly:abc"))
        #expect(store.state.confetti.firedKeys.contains("event:claude:weekly:new"))
        toy.roomChanged()
        #expect(bursts.fired.count == 1, "the older hold cannot replay after the new burst")
    }

    @Test("held provider resets merge into one burst and every receipt settles once")
    func heldProviderResetsMerge() throws {
        let (toy, store, bursts) = try makeToy()
        store.noteCallPresence(true)
        let events = [
            CoreEvent(id: "a", kind: "quota_reset", provider: "codex", lane: "five-hour", eventId: "codex:session:1"),
            CoreEvent(id: "b", kind: "quota_reset", provider: "copilot", lane: "monthly", eventId: "copilot:monthly:1")
        ]
        for event in events { toy.noteEvent(event) }
        for event in events { toy.noteEvent(event) }
        #expect(bursts.fired.isEmpty)
        #expect(bursts.receipts.filter { $0.outcome == .held }.count == 2)
        store.noteCallPresence(false)
        toy.roomChanged()
        #expect(bursts.fired.count == 1)
        let delivered = bursts.receipts.filter { $0.outcome == .delivered }
        #expect(Set(delivered.map(\.eventID)) == ["codex:session:1", "copilot:monthly:1"])
        #expect(delivered.count == 2)
        for event in events { toy.noteEvent(event) }
        toy.roomChanged()
        #expect(bursts.fired.count == 1)
        #expect(toy.held == nil)
    }

    @Test("held resets respect trigger changes without needing another daemon event")
    func heldResetOptOut() throws {
        let (toy, store, bursts) = try makeToy()
        store.noteCallPresence(true)
        toy.noteEvent(weeklyReset())
        store.state.confetti.triggers.quotaReset = false
        toy.roomChanged()
        #expect(toy.held == nil)
        #expect(bursts.receipts.last == ConfettiResetReceipt(
            eventID: "claude:weekly:abc", outcome: .dropped, reason: "trigger_off"))
        store.noteCallPresence(false)
        #expect(bursts.fired.isEmpty)
    }

    @Test("disabling a held reset preserves a separate explicit confetti request")
    func heldRequestSurvivesResetOptOut() throws {
        let (toy, store, bursts) = try makeToy()
        store.noteCallPresence(true)
        toy.noteEvent(weeklyReset())
        #expect(toy.fire(reason: .request, provider: "kimi"))
        store.state.confetti.triggers.quotaReset = false
        toy.roomChanged()
        #expect(toy.held?.facts.isEmpty == true)
        #expect(toy.held?.request != nil)
        store.noteCallPresence(false)
        #expect(bursts.fired.count == 1)
        #expect(bursts.receipts.last == ConfettiResetReceipt(
            eventID: "claude:weekly:abc", outcome: .dropped, reason: "trigger_off"))
    }

    @Test("changing provider overrides removes only ineligible held resets")
    func heldResetProviderOptOut() throws {
        let (toy, store, bursts) = try makeToy()
        store.noteCallPresence(true)
        toy.noteEvent(weeklyReset())
        toy.noteEvent(CoreEvent(id: "kilo", kind: "quota_reset", provider: "kilo",
                                lane: "monthly", eventId: "kilo:monthly:1"))
        store.state.confetti.triggers.quotaReset = false
        store.state.confetti.triggers.perProviderReset = ["kilo"]
        toy.roomChanged()
        #expect(toy.held?.facts.map(\.eventID) == ["kilo:monthly:1"])
        store.noteCallPresence(false)
        #expect(bursts.fired.count == 1)
        #expect(bursts.receipts.filter { $0.outcome == .delivered }.map(\.eventID) == ["kilo:monthly:1"])
    }

    @Test("a newer held reset keeps its own age when an earlier hold expires")
    func heldResetAgesIndependently() throws {
        let (toy, store, bursts) = try makeToy()
        store.noteCallPresence(true)
        @Captured var seconds: TimeInterval = 5_000
        toy.clock = { seconds }
        toy.noteEvent(weeklyReset())
        seconds += ConfettiRoom.holdLimit - 60
        toy.noteEvent(weeklyReset(id: "claude:weekly:new"))
        seconds += 120
        store.noteCallPresence(false)
        #expect(bursts.fired.count == 1)
        #expect(bursts.receipts.contains(ConfettiResetReceipt(
            eventID: "claude:weekly:abc", outcome: .expired, reason: "held_too_long")))
        #expect(bursts.receipts.last == ConfettiResetReceipt(
            eventID: "claude:weekly:new", outcome: .delivered, reason: "after_hold"))
    }

    @Test("a reset remains settled after completion bursts evict the shared recent-key ring")
    func resetSurvivesCompletionRingEviction() throws {
        let (toy, store, bursts) = try makeToy()
        toy.noteEvent(weeklyReset())
        store.state.confetti.triggers.sessionCompleted = true
        for index in 0..<ConfettiSettings.firedKeyLimit {
            toy.noteEvent(CoreEvent(id: "completed-\(index)", kind: "completed"))
        }
        #expect(!store.state.confetti.firedKeys.contains("event:claude:weekly:abc"))
        store.state = try JSONDecoder().decode(ToysState.self, from: JSONEncoder().encode(store.state))
        let count = bursts.fired.count
        toy.noteEvent(weeklyReset(cursor: "next-stream:ev-1"))
        #expect(bursts.fired.count == count)
        #expect(bursts.receipts.last?.reason == "already_celebrated")
    }

    @Test("held fact retention is bounded and overflow stays replayable")
    func heldFactsAreBounded() throws {
        let (toy, store, bursts) = try makeToy()
        store.noteCallPresence(true)
        for index in 0...ConfettiToy.maximumHeldFacts {
            toy.noteEvent(weeklyReset(id: "claude:weekly:\(index)"))
        }
        #expect(toy.held?.facts.count == ConfettiToy.maximumHeldFacts)
        #expect(bursts.receipts.contains(ConfettiResetReceipt(
            eventID: "claude:weekly:0", outcome: .expired, reason: "hold_capacity")))
        #expect(!store.state.confetti.firedKeys.contains("event:claude:weekly:0"))
        store.noteCallPresence(false)
        #expect(bursts.fired.count == 1)
        #expect(bursts.receipts.filter { $0.outcome == .delivered }.count == ConfettiToy.maximumHeldFacts)
    }

    @Test("a hold that lapses leaves the reset owed, so a later connection can offer it again")
    func lapsedHoldStaysOwed() throws {
        let (toy, store, bursts) = try makeToy()
        store.noteCallPresence(true)
        @Captured var seconds: TimeInterval = 5_000
        toy.clock = { seconds }
        toy.noteEvent(weeklyReset())
        seconds += ConfettiRoom.holdLimit + 1
        toy.roomChanged()
        #expect(toy.held == nil)
        #expect(bursts.receipts.last == ConfettiResetReceipt(
            eventID: "claude:weekly:abc", outcome: .expired, reason: "held_too_long"))
        #expect(!store.state.confetti.firedKeys.contains("event:claude:weekly:abc"))
        // The call is over; the greet offers it again and it celebrates.
        store.noteCallPresence(false)
        toy.noteEvent(weeklyReset())
        #expect(bursts.fired.count == 1)
        #expect(bursts.receipts.last?.outcome == .delivered)
    }

    @Test("an expired durable reoffer reaches confetti again through the same core stream")
    func expiredResetReofferThroughCore() throws {
        let (toy, store, bursts) = try makeToy()
        store.core.onEvent = { toy.noteEvent($0) }
        store.core.onResetReplay = { toy.noteEvent($0) }
        let hello = CoreHello(stream: "synthetic-stream", cursor: "synthetic-stream:ev-0")
        store.core.apply(.hello(hello))
        let reset = CoreEvent(id: "claude:weekly:abc", kind: "quota_reset", notify: false,
                              provider: "claude", lane: "weekly", eventId: "claude:weekly:abc")
        @Captured var seconds: TimeInterval = 5_000
        toy.clock = { seconds }
        store.noteCallPresence(true)
        store.core.apply(.event(reset))
        seconds += ConfettiRoom.holdLimit + 1
        toy.roomChanged()
        #expect(bursts.receipts.last?.outcome == .expired)
        store.noteCallPresence(false)
        store.core.apply(.hello(hello))
        store.core.apply(.event(reset))
        #expect(bursts.fired.count == 1)
        #expect(bursts.receipts.last?.outcome == .delivered)
        store.core.apply(.event(reset))
        #expect(bursts.fired.count == 1)
        #expect(bursts.receipts.last?.reason == "already_celebrated")
    }

    @Test("a reset the room is told to let go is closed, with its reason")
    func letGoResetIsClosed() throws {
        let (toy, store, bursts) = try makeToy()
        store.state.confetti.whenHeld = .drop
        store.noteCallPresence(true)
        toy.noteEvent(weeklyReset())
        #expect(bursts.fired.isEmpty)
        #expect(bursts.receipts == [ConfettiResetReceipt(eventID: "claude:weekly:abc",
                                                          outcome: .dropped, reason: "call")])
        #expect(store.state.confetti.firedKeys.contains("event:claude:weekly:abc"))
    }

    @Test("a reset received while Confetti is off stays closed after reconnect", arguments: [true, false])
    func resetWhileOffIsClosed(stableID: Bool) throws {
        let (toy, store, bursts) = try makeToy(enabled: false)
        var reset = weeklyReset(cursor: "run1:ev-3")
        if !stableID { reset.eventId = nil }
        let key = ConfettiTriggerPolicy.eventKey(reset)
        toy.noteEvent(reset)
        #expect(bursts.fired.isEmpty)
        if stableID {
            #expect(bursts.receipts == [ConfettiResetReceipt(eventID: "claude:weekly:abc",
                                                          outcome: .dropped, reason: "toy_off")])
        } else {
            #expect(bursts.receipts.isEmpty)
        }
        #expect(store.state.confetti.firedKeys.contains(key))
        let saved = try JSONEncoder().encode(store.state)
        let restored = try JSONDecoder().decode(ToysState.self, from: saved)
        #expect(restored.confetti.firedKeys.contains(key))
        toy.isOn = true
        toy.noteConnectionLost()
        if stableID { reset.cursor = "run2:ev-4" }
        toy.noteEvent(reset)
        #expect(bursts.fired.isEmpty)
        toy.noteEvent(weeklyReset(id: "claude:weekly:next", cursor: "run2:ev-5"))
        #expect(bursts.fired.count == 1)
    }

    @Test("a reset older than the freshness window never celebrates, and says it was history")
    func staleResetIsHistory() throws {
        let (toy, store, bursts) = try makeToy()
        let old = weeklyReset(ago: ConfettiTriggerPolicy.eventFreshnessWindow + 60)
        toy.noteEvent(old)
        #expect(bursts.fired.isEmpty)
        #expect(bursts.receipts == [ConfettiResetReceipt(eventID: "claude:weekly:abc",
                                                          outcome: .dropped, reason: "stale")])
        #expect(bursts.lines.contains { $0.contains("stale") })
        _ = store
    }

    @Test("a reset with its trigger off stays closed after reconnect", arguments: [true, false])
    func triggerOffResetIsClosed(stableID: Bool) throws {
        let (toy, store, bursts) = try makeToy()
        store.state.confetti.triggers.quotaReset = false
        var reset = weeklyReset(cursor: "run1:ev-3")
        if !stableID { reset.eventId = nil }
        let key = ConfettiTriggerPolicy.eventKey(reset)
        toy.noteEvent(reset)
        #expect(bursts.fired.isEmpty)
        if stableID {
            #expect(bursts.receipts.last == ConfettiResetReceipt(
                eventID: "claude:weekly:abc", outcome: .dropped, reason: "trigger_off"))
        } else {
            #expect(bursts.receipts.isEmpty)
        }
        #expect(bursts.lines.contains { $0.contains("trigger_off") })
        #expect(store.state.confetti.firedKeys.contains(key))
        let saved = try JSONEncoder().encode(store.state)
        let restored = try JSONDecoder().decode(ToysState.self, from: saved)
        #expect(restored.confetti.firedKeys.contains(key))
        store.state.confetti.triggers.quotaReset = true
        toy.noteConnectionLost()
        if stableID { reset.cursor = "run2:ev-4" }
        toy.noteEvent(reset)
        #expect(bursts.fired.isEmpty)
        toy.noteEvent(weeklyReset(id: "claude:weekly:next", cursor: "run2:ev-5"))
        #expect(bursts.fired.count == 1)
    }
}
