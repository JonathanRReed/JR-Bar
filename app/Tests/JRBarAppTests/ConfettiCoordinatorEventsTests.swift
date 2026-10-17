import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

@MainActor
@Suite("Confetti through the event coordinator")
struct ConfettiCoordinatorEventsTests {
    @MainActor
    private final class Fixture {
        let core: CoreModel
        let store: ToysStore
        let coordinator: EventCoordinator
        var presentations: [ConfettiPresentation] = []
        var receipts: [ConfettiResetReceipt] = []

        init() throws {
            core = CoreModel()
            let focus = try JSONDecoder().decode(CoreFocus.self, from: Data(
                #"{"mode":"off","source":null,"until":null}"#.utf8))
            core.apply(.state(CoreState(focus: focus)))
            var state = ToysState()
            state.confetti.enabled = true
            state.confetti.sound = false
            state.confetti.triggers.sessionCompleted = false
            state.notchBuddy.enabled = false
            state.notch.enabled = false
            store = ToysStore(core: core, settings: SettingsStore(core: core), state: state,
                              cardModel: makeTestCardModel(), notchRuntimeEnabled: false,
                              nativeSourcesEnabled: false)
            coordinator = EventCoordinator(core: core, hudAnchor: { nil })
            coordinator.toys = store
            coordinator.quietWhenPaneFrontmost = { false }
            coordinator.deliveryRules = { _, _ in .nothing }
            core.onEvent = { [weak coordinator] event in coordinator?.handle(event) }
            store.confetti.clock = { 5_000 }
            store.confetti.screensForBurst = { [nil] }
            store.confetti.mainScreen = { nil }
            store.confetti.presentOverride = { [weak self] in self?.presentations.append($0) }
            store.confetti.receiptSink = { [weak self] in self?.receipts.append($0) }
            store.confetti.logSink = { _ in }
        }

        func shutdown() {
            core.onEvent = nil
            store.shutdown()
        }

        func reset(cursor: String) -> CoreEvent {
            CoreEvent(id: "synthetic-reset", kind: "quota_reset", at: Date().timeIntervalSince1970,
                      provider: "claude", lane: "weekly", cursor: cursor,
                      eventId: "synthetic-weekly-reset")
        }
    }

    @Test("a stable reset presents once across journal replays")
    func resetReplay() throws {
        let fixture = try Fixture()
        defer { fixture.shutdown() }
        let first = fixture.reset(cursor: "synthetic-first:1")
        fixture.core.apply(.event(first))
        fixture.core.apply(.event(first))
        fixture.core.apply(.event(fixture.reset(cursor: "synthetic-restart:1")))
        #expect(fixture.presentations.count == 1)
        #expect(fixture.store.state.confetti.firedKeys.contains("event:synthetic-weekly-reset"))
        #expect(fixture.receipts == [
            ConfettiResetReceipt(eventID: "synthetic-weekly-reset", outcome: .delivered, reason: "presented"),
            ConfettiResetReceipt(eventID: "synthetic-weekly-reset", outcome: .dropped, reason: "already_celebrated"),
        ])
    }

    @Test("completion confetti requires its trigger and does not replay disabled deliveries")
    func completionOptIn() throws {
        let fixture = try Fixture()
        defer { fixture.shutdown() }
        let disabled = CoreEvent(id: "synthetic-disabled", kind: "completed", provider: "codex",
                                 cursor: "synthetic-completion:1")
        fixture.core.apply(.event(disabled))
        #expect(fixture.presentations.isEmpty)
        fixture.store.state.confetti.triggers.sessionCompleted = true
        fixture.core.apply(.event(disabled))
        #expect(fixture.presentations.isEmpty)
        let enabled = CoreEvent(id: "synthetic-enabled", kind: "completed", provider: "codex",
                                cursor: "synthetic-completion:2")
        fixture.core.apply(.event(enabled))
        fixture.core.apply(.event(enabled))
        #expect(fixture.presentations.count == 1)
        #expect(fixture.store.state.confetti.firedKeys.contains("event:synthetic-completion:2"))
        #expect(fixture.receipts.isEmpty)
    }

    @Test("a coordinator reset held during a call presents once when the call ends")
    func heldResetRelease() throws {
        let fixture = try Fixture()
        defer { fixture.shutdown() }
        fixture.store.noteCallPresence(true)
        fixture.core.apply(.event(fixture.reset(cursor: "synthetic-held:1")))
        fixture.core.apply(.event(fixture.reset(cursor: "synthetic-held:2")))
        #expect(fixture.presentations.isEmpty)
        #expect(!fixture.store.state.confetti.firedKeys.contains("event:synthetic-weekly-reset"))
        #expect(fixture.receipts == [
            ConfettiResetReceipt(eventID: "synthetic-weekly-reset", outcome: .held, reason: "call"),
        ])
        fixture.store.noteCallPresence(false)
        #expect(fixture.presentations.count == 1)
        #expect(fixture.store.state.confetti.firedKeys.contains("event:synthetic-weekly-reset"))
        #expect(fixture.receipts.last == ConfettiResetReceipt(
            eventID: "synthetic-weekly-reset", outcome: .delivered, reason: "after_hold"))
        fixture.store.noteCallPresence(false)
        #expect(fixture.presentations.count == 1)
    }
}
