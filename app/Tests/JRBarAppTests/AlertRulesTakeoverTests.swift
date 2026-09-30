import Foundation
import Testing
@testable import JRBarApp
@testable import JRBarCore

/// The coordinator's wiring for a provider's alert rule and the notch
/// takeover: the rule runs between the policy and the notch, so a provider
/// whose asks never interrupt does not get the ask grown out of the island.
/// Nothing here opens a window, plays a sound or reaches a daemon: the Mac
/// is dimmed in the fixture, which holds the chime and leaves the takeover
/// standing.
@Suite("Alert rules and takeover")
@MainActor
struct AlertRulesTakeoverTests {
    private let session = "grok:session:takeover"

    private func makeCoordinator(rules: [String: AgentAlertRule]) -> (EventCoordinator, ToysStore) {
        var toysState = ToysState()
        toysState.notch = NotchSettings(enabled: true, provider: .jrbar, islandEnabled: true)
        let core = CoreModel()
        core.apply(.settings(CoreSettings(generation: 2, document: .object(["escalation_tier": .string("takeover")]))))
        core.apply(.state(CoreState(
            sessions: [CoreSession(id: session, provider: "grok", ask: CoreAsk(summary: "Run"))],
            asks: [CoreAsk(session: session, openedAt: 1, summary: "Run", answerable: true, request: "r1")],
            focus: CoreFocus(mode: "dim"))))
        let toys = ToysStore(core: core, settings: SettingsStore(core: core), state: toysState,
                             cardModel: makeTestCardModel(), notchRuntimeEnabled: false)
        toys.notch.islandVisible = true
        let events = EventCoordinator(core: core, hudAnchor: { nil })
        events.toys = toys
        events.quietWhenPaneFrontmost = { false }
        events.deliveryRules = { [weak core] delivery, event in
            AgentAlertRules.apply(delivery, to: event, state: core?.state, rules: rules)
        }
        return (events, toys)
    }

    @Test("a provider whose asks never interrupt does not grow the ask card at stage 3")
    func quietAsksKeepTheCardDown() {
        let stage3 = CoreEvent(id: "e", kind: "escalation_stage", session: session, stage: 3)

        // The control: with no rule the same event does take the notch over,
        // so the assertions below are about the rule and not the fixture.
        let (ungated, ungatedToys) = makeCoordinator(rules: [:])
        ungated.handle(stage3)
        #expect(ungatedToys.notch.activeCapsule?.takeover == true)

        let (silenced, silencedToys) = makeCoordinator(rules: ["grok": AgentAlertRule(asks: false)])
        silenced.handle(stage3)
        #expect(silencedToys.notch.activeCapsule?.takeover != true)

        let (capped, cappedToys) = makeCoordinator(rules: ["grok": AgentAlertRule(escalationCeiling: 2)])
        capped.handle(stage3)
        #expect(cappedToys.notch.activeCapsule?.takeover != true)
    }
}
