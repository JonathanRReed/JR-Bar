import Foundation
import Testing
@testable import JRBarCore

/// Per-provider alert rules — the Agent Overview card's own job — applied
/// on top of what `EventPolicy` decided.
@Suite("Agent alert rules")
struct AgentAlertRulesTests {
    static let state = CoreState(
        generation: 1,
        aggregate: CoreAggregate(),
        sessions: [
            CoreSession(id: "grok:1", provider: "grok", label: "grok run", mode: "waiting"),
            CoreSession(id: "codex:2", provider: "codex", label: "core", mode: "working"),
        ],
        asks: [CoreAsk(session: "grok:1", kind: "permission", openedAt: 10, summary: "rm -rf?")])

    static let askDelivery = EventDelivery(sound: "Glass", notification: .init(identifier: "ask:grok:1", title: "grok run needs you", body: "?", category: .ask))

    @Test("a provider with no rule, or a default one, is untouched")
    func passThrough() {
        let event = CoreEvent(id: "e", kind: "ask_opened", session: "grok:1")
        #expect(AgentAlertRules.apply(Self.askDelivery, to: event, state: Self.state, rules: [:]) == Self.askDelivery)
        #expect(AgentAlertRules.apply(Self.askDelivery, to: event, state: Self.state, rules: ["grok": .followGlobal]) == Self.askDelivery)
    }

    @Test("a quiet provider's asks stay on screen but never interrupt; another provider's are untouched")
    func quietAsks() {
        let rules = ["grok": AgentAlertRule(asks: false)]
        let grok = AgentAlertRules.apply(Self.askDelivery, to: CoreEvent(id: "e", kind: "ask_opened", session: "grok:1"),
                                         state: Self.state, rules: rules)
        #expect(grok.sound == nil && grok.notification == nil)
        let codex = AgentAlertRules.apply(Self.askDelivery, to: CoreEvent(id: "f", kind: "ask_opened", session: "codex:2"),
                                          state: Self.state, rules: rules)
        #expect(codex == Self.askDelivery)
    }

    @Test("finishes: always banners one provider even with the global switch off, never silences another")
    func completions() {
        let silent = EventDelivery(sound: "Hero")
        let always = AgentAlertRules.apply(silent, to: CoreEvent(id: "c", kind: "completed", session: "codex:2", provider: "codex"),
                                           state: Self.state, rules: ["codex": AgentAlertRule(completions: true)])
        #expect(always.notification?.title == "core finished")
        #expect(always.sound == "Hero")

        let banner = EventDelivery(sound: "Hero", notification: .init(identifier: "completed:codex:2", title: "core finished", body: ""))
        let never = AgentAlertRules.apply(banner, to: CoreEvent(id: "c", kind: "completed", session: "codex:2"),
                                          state: Self.state, rules: ["codex": AgentAlertRule(completions: false, sounds: false)])
        #expect(never.notification == nil)
        #expect(never.sound == nil)
    }

    @Test("an escalation for a capped provider's ask stops at its ceiling")
    func escalation() {
        let loud = EventDelivery(statusPulse: true, chime: .start)
        let event = CoreEvent(id: "s", kind: "escalation_stage", stage: 3)
        let capped = AgentAlertRules.apply(loud, to: event, state: Self.state, rules: ["grok": AgentAlertRule(escalationCeiling: 1)])
        #expect(capped.statusPulse == false)
        #expect(capped.chime == .stop)
        let pulseOnly = AgentAlertRules.apply(loud, to: event, state: Self.state, rules: ["grok": AgentAlertRule(escalationCeiling: 2)])
        #expect(pulseOnly.statusPulse == true)
        #expect(pulseOnly.chime == .stop)
    }

    @Test("device toasts and quota banners are not one agent's to silence")
    func otherKinds() {
        let toast = EventDelivery(toast: "SidePulse connected")
        #expect(AgentAlertRules.apply(toast, to: CoreEvent(id: "d", kind: "device_connected", provider: "grok"),
                                      state: Self.state, rules: ["grok": AgentAlertRule(sounds: false)]) == toast)
    }

    @Test("a notify-when-done watch banners the ending, whatever the switches decided")
    func notifyWhenDone() {
        let finished = AgentAlertRules.notifyWhenDone(EventDelivery(sound: "Hero"),
                                                      event: CoreEvent(id: "c", kind: "completed", session: "codex:2"),
                                                      state: Self.state)
        #expect(finished.notification?.title == "core finished")
        #expect(finished.notification?.session == "codex:2")
        let ended = AgentAlertRules.notifyWhenDone(.nothing, event: CoreEvent(id: "e", kind: "ended", session: "grok:1"),
                                                   state: Self.state)
        #expect(ended.notification?.title == "grok run ended")
        let existing = EventDelivery(notification: .init(identifier: "failed:x", title: "already", body: ""))
        #expect(AgentAlertRules.notifyWhenDone(existing, event: CoreEvent(id: "f", kind: "failed", session: "codex:2"),
                                               state: Self.state) == existing)
        #expect(AgentAlertRules.notifyWhenDone(.nothing, event: CoreEvent(id: "a", kind: "ask_opened", session: "codex:2"),
                                               state: Self.state) == .nothing)
    }

    @Test("rules persist inside the organizer settings, missing keys follow the global policy")
    func persistence() throws {
        var settings = AgentOrganizerSettings()
        settings.alertRules = ["grok": AgentAlertRule(asks: false, escalationCeiling: 9)]
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AgentOrganizerSettings.self, from: data)
        #expect(decoded.alertRules["grok"]?.asks == false)
        #expect(decoded.alertRules["grok"]?.escalationCeiling == 3)
        let old = try JSONDecoder().decode(AgentOrganizerSettings.self, from: Data(#"{"enabled":true}"#.utf8))
        #expect(old.alertRules.isEmpty)
        let partial = try JSONDecoder().decode(AgentAlertRule.self, from: Data(#"{"sounds":false}"#.utf8))
        #expect(partial.asks && partial.failures && !partial.sounds && partial.completions == nil)
        #expect(partial.summary == "no sounds")
        #expect(AgentAlertRule().summary == nil)
    }
}
