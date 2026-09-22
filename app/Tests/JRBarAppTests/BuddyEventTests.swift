import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

@MainActor
@Suite("Buddy event lifecycle")
struct BuddyEventTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func fixture(enabled: Bool, sessions: [CoreSession] = [])
        -> (core: CoreModel, store: ToysStore, buddy: NotchBuddyToy) {
        let core = CoreModel()
        core.apply(.state(CoreState(sessions: sessions)))
        var state = ToysState()
        state.notchBuddy.enabled = enabled
        let store = ToysStore(
            core: core,
            settings: SettingsStore(core: core),
            state: state,
            cardModel: makeTestCardModel(), notchRuntimeEnabled: false)
        let buddy = store.notchBuddy
        let eventDate = now
        core.onEvent = { [weak buddy] event in buddy?.noteEvent(event, at: eventDate) }
        return (core, store, buddy)
    }

    private func session(
        _ id: String = "session-1",
        mode: String? = "idle_ready",
        lifecycle: String? = "active",
        nextActor: String? = nil
    ) -> CoreSession {
        CoreSession(
            id: id,
            provider: "codex",
            mode: mode,
            lifecycle: lifecycle,
            nextActor: nextActor)
    }

    @Test("disabled Buddy ignores events and state documents")
    func disabledBuddyIsImmutable() async throws {
        let fixture = fixture(enabled: false)
        let before = fixture.store.state.notchBuddy

        fixture.core.apply(.event(CoreEvent(
            id: "completion-disabled",
            kind: "completed",
            session: "session-1")))
        fixture.buddy.noteState(CoreState(sessions: [
            session(mode: nil, lifecycle: "completed"),
        ]))
        // Drive the old permanent observer's path too, not only the new event API.
        fixture.core.apply(.state(CoreState(generation: 2, sessions: [])))
        try await Task.sleep(for: .milliseconds(30))
        fixture.core.apply(.state(CoreState(generation: 3, sessions: [
            session(mode: nil, lifecycle: "completed"),
        ])))
        try await Task.sleep(for: .milliseconds(30))

        #expect(fixture.store.state.notchBuddy == before)
        #expect(fixture.buddy.hopUntil == nil)
    }

    @Test("the coordinator forwards events without bypassing disabled state or deduplication")
    func coordinatorForwardsBuddyEvents() {
        let fixture = fixture(enabled: false)
        fixture.store.state.confetti.enabled = false
        fixture.store.state.notch.enabled = false
        let coordinator = EventCoordinator(core: fixture.core, hudAnchor: { nil })
        defer { withExtendedLifetime(coordinator) {} }
        coordinator.toys = fixture.store
        fixture.core.onEvent = { [weak coordinator] event in
            coordinator?.apply(.nothing, for: event)
        }
        let before = fixture.store.state.notchBuddy
        let disabledEvent = CoreEvent(id: "coordinator-disabled", kind: "completed", session: "s")
        fixture.core.apply(.event(disabledEvent))
        #expect(fixture.store.state.notchBuddy == before)
        fixture.buddy.isOn = true
        fixture.core.apply(.event(disabledEvent))
        #expect(fixture.store.state.notchBuddy.care.crumbsEaten == 0)
        let enabledEvent = CoreEvent(id: "coordinator-enabled", kind: "completed", session: "s")
        fixture.core.apply(.event(enabledEvent))
        fixture.core.apply(.event(enabledEvent))
        #expect(fixture.store.state.notchBuddy.care.crumbsEaten == 1)
    }

    @Test("CoreModel delivers a duplicate completion ID to Buddy once")
    func duplicateCompletionCreditsOneCrumb() {
        let fixture = fixture(enabled: true)
        fixture.buddy.tuckAway()
        let event = CoreEvent(
            id: "one-completion",
            kind: "completed",
            session: "session-1")

        fixture.core.apply(.event(event))
        fixture.core.apply(.event(event))

        #expect(fixture.store.state.notchBuddy.care.crumbsEaten == 1)
        #expect(fixture.store.state.notchBuddy.care.lastCrumbAt == now.timeIntervalSince1970)
        #expect(fixture.buddy.hopUntil == now.addingTimeInterval(1.1))
        #expect(!fixture.store.state.notchBuddy.tucked)
    }

    @Test("state documents wake Buddy but never award care credits")
    func stateDocumentsNeverCreditCrumbs() {
        let fixture = fixture(enabled: true)
        fixture.buddy.tuckAway()

        fixture.buddy.noteState(CoreState(sessions: [
            session(mode: nil, lifecycle: "completed"),
        ]))
        fixture.buddy.noteState(CoreState(sessions: [
            session("session-2", mode: nil, lifecycle: "completed"),
        ]))

        #expect(fixture.store.state.notchBuddy.care.crumbsEaten == 0)
        #expect(fixture.store.state.notchBuddy.care.lastCrumbAt == 0)
        #expect(fixture.buddy.hopUntil == nil)
    }

    @Test("enabling after a disabled delivery does not replay its completion")
    func enablingDoesNotReplayDisabledEvent() {
        let fixture = fixture(enabled: false)
        let event = CoreEvent(
            id: "while-disabled",
            kind: "completed",
            session: "session-1")

        fixture.core.apply(.event(event))
        fixture.buddy.isOn = true
        fixture.core.apply(.event(event))

        #expect(fixture.store.state.notchBuddy.care.crumbsEaten == 0)
        #expect(fixture.buddy.hopUntil == nil)
    }

    @Test("an unchanged session heartbeat leaves a tucked Buddy asleep")
    func unchangedHeartbeatDoesNotWake() {
        let idle = session()
        let fixture = fixture(enabled: true, sessions: [idle])
        fixture.buddy.tuckAway()

        fixture.buddy.noteState(CoreState(generation: 2, sessions: [idle]))

        #expect(fixture.store.state.notchBuddy.tucked)
    }

    @Test("working, asking, and completed session changes wake a tucked Buddy")
    func meaningfulSessionChangesWake() {
        let changes = [
            session(mode: "working"),
            session(mode: "waiting_for_input"),
            session(mode: nil, lifecycle: "completed"),
        ]

        for changed in changes {
            let fixture = fixture(enabled: true, sessions: [session()])
            fixture.buddy.tuckAway()
            fixture.buddy.noteState(CoreState(sessions: [changed]))

            #expect(!fixture.store.state.notchBuddy.tucked)
            #expect(fixture.store.state.notchBuddy.care.crumbsEaten == 0)
        }
    }

    @Test("global quota events leave a tucked Buddy asleep")
    func quotaEventDoesNotWake() {
        let fixture = fixture(enabled: true, sessions: [session()])
        fixture.buddy.tuckAway()

        fixture.core.apply(.event(CoreEvent(
            id: "quota-only",
            kind: "quota_reset",
            provider: "codex",
            lane: "weekly")))

        #expect(fixture.store.state.notchBuddy.tucked)
        #expect(fixture.store.state.notchBuddy.care.crumbsEaten == 0)
    }
}
