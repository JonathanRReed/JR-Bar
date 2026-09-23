import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// The lid's angle as one shared signal: the fold's sensor publishes it,
/// the buddy pulls on its nightcap as the lid comes down.
@Suite("Hinge signal")
@MainActor
struct HingeSignalTests {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func store(sessions: [CoreSession] = []) -> ToysStore {
        let core = CoreModel()
        core.apply(.state(CoreState(sessions: sessions)))
        var state = ToysState()
        state.notchBuddy.enabled = true
        return ToysStore(core: core, settings: SettingsStore(core: core), state: state,
                         cardModel: makeTestCardModel(), notchRuntimeEnabled: false)
    }

    @Test("whole degrees, fresh readings only, between shut and the closing line")
    func closing() {
        let s = store()
        #expect(!s.lidClosing(at: t0), "no reading yet")
        s.noteHinge(118.4, at: t0)
        #expect(s.hingeAngle == 118)
        #expect(!s.lidClosing(at: t0), "open for work")
        s.noteHinge(41.6, at: t0)
        #expect(s.hingeAngle == 42)
        #expect(s.lidClosing(at: t0))
        #expect(!s.lidClosing(at: t0.addingTimeInterval(5)), "a stale reading says nothing")
        s.noteHinge(3, at: t0)
        #expect(!s.lidClosing(at: t0), "shut is shut, not closing")
        s.noteHinge(nil, at: t0)
        #expect(s.hingeAngle == nil)
    }

    @Test("the lid coming down puts the nightcap on a working buddy, not on an ask")
    func goodnight() {
        let working = store(sessions: [CoreSession(id: "w", provider: "claude", mode: "tool_running")])
        let buddy = working.notchBuddy
        #expect(buddy.summary(at: t0).mood == .pacing)
        working.noteHinge(40, at: t0)
        #expect(buddy.summary(at: t0).mood == .asleep)
        working.noteHinge(120, at: t0)
        #expect(buddy.summary(at: t0).mood == .pacing)

        let asking = store(sessions: [CoreSession(id: "a", provider: "claude", mode: "waiting_input",
                                                  ask: CoreAsk(session: "a", kind: "permission", openedAt: 1))])
        asking.noteHinge(40, at: t0)
        #expect(asking.notchBuddy.summary(at: t0).mood == .waving, "an ask still waves")
    }
}
