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

    @Test("sounds off silences the stage-3 chime; the pulse still climbs")
    func quietSoundsStopTheChime() {
        let loud = EventDelivery(statusPulse: true, chime: .start)
        let event = CoreEvent(id: "s", kind: "escalation_stage", stage: 3)
        let quiet = AgentAlertRules.apply(loud, to: event, state: Self.state, rules: ["grok": AgentAlertRule(sounds: false)])
        #expect(quiet.chime == .stop)
        #expect(quiet.statusPulse == true)
    }

    @Test("asks off: the escalation neither chimes nor pulses for that provider")
    func quietAsksNeverEscalate() {
        let loud = EventDelivery(statusPulse: true, chime: .start)
        let event = CoreEvent(id: "s", kind: "escalation_stage", stage: 3)
        let quiet = AgentAlertRules.apply(loud, to: event, state: Self.state, rules: ["grok": AgentAlertRule(asks: false)])
        #expect(quiet.chime == .stop)
        #expect(quiet.statusPulse == false)
    }

    static let takeoverDelivery = EventDelivery(statusPulse: true, chime: .start, takeover: true)
    static let stage3 = CoreEvent(id: "s", kind: "escalation_stage", stage: 3)

    @Test("a capped ceiling never takes the notch over")
    func cappedCeilingNeverTakesOver() {
        let one = AgentAlertRules.apply(Self.takeoverDelivery, to: Self.stage3, state: Self.state,
                                        rules: ["grok": AgentAlertRule(escalationCeiling: 1)])
        #expect(!one.takeover)
        #expect(one.chime == .stop)
        #expect(one.statusPulse == false)
        let two = AgentAlertRules.apply(Self.takeoverDelivery, to: Self.stage3, state: Self.state,
                                        rules: ["grok": AgentAlertRule(escalationCeiling: 2)])
        #expect(!two.takeover)
        #expect(two.chime == .stop)
        #expect(two.statusPulse == true)
    }

    @Test("a ceiling of 3 keeps the finale Settings armed")
    func ceilingThreeKeepsTakeover() {
        let three = AgentAlertRules.apply(Self.takeoverDelivery, to: Self.stage3, state: Self.state,
                                          rules: ["grok": AgentAlertRule(escalationCeiling: 3)])
        #expect(three.takeover)
        #expect(three.chime == .start)
        #expect(three.statusPulse == true)
    }

    @Test("asks off never takes the notch over")
    func quietAsksNeverTakeOver() {
        let quiet = AgentAlertRules.apply(Self.takeoverDelivery, to: Self.stage3, state: Self.state,
                                          rules: ["grok": AgentAlertRule(asks: false)])
        #expect(!quiet.takeover)
        #expect(quiet.chime == .stop)
        #expect(quiet.statusPulse == false)
    }

    @Test("sounds off keeps the picture: takeover is not a sound")
    func quietSoundsKeepTakeover() {
        let quiet = AgentAlertRules.apply(Self.takeoverDelivery, to: Self.stage3, state: Self.state,
                                          rules: ["grok": AgentAlertRule(sounds: false)])
        #expect(quiet.takeover)
        #expect(quiet.chime == .stop)
        #expect(quiet.statusPulse == true)
    }

    @Test("another provider's takeover is untouched")
    func otherProviderKeepsTakeover() {
        let codexStage = CoreEvent(id: "s", kind: "escalation_stage", session: "codex:2", stage: 3)
        let out = AgentAlertRules.apply(Self.takeoverDelivery, to: codexStage, state: Self.state,
                                        rules: ["grok": AgentAlertRule(asks: false)])
        #expect(out == Self.takeoverDelivery)
    }

    @Test("with no stage on the event the current stage decides the takeover")
    func currentStageDecidesTakeover() {
        let bare = CoreEvent(id: "s", kind: "escalation_stage")
        let rules = ["grok": AgentAlertRule(escalationCeiling: 3)]
        let below = AgentAlertRules.apply(Self.takeoverDelivery, to: bare, state: Self.state, rules: rules, currentStage: 2)
        #expect(!below.takeover)
        let at = AgentAlertRules.apply(Self.takeoverDelivery, to: bare, state: Self.state, rules: rules, currentStage: 3)
        #expect(at.takeover)
    }

    @Test("the ceiling starts at the light: a saved 'nothing' reads as the light it always was")
    func ceilingFloor() throws {
        #expect(AgentAlertRule(escalationCeiling: 0).escalationCeiling == 1)
        let saved = try JSONDecoder().decode(AgentAlertRule.self, from: Data(#"{"escalationCeiling":0}"#.utf8))
        #expect(saved.escalationCeiling == 1)
        #expect(saved.summary == "escalates to the light")
    }

    @Test("device toasts and quota banners are not one agent's to silence")
    func otherKinds() {
        let toast = EventDelivery(toast: "SidePulse connected")
        #expect(AgentAlertRules.apply(toast, to: CoreEvent(id: "d", kind: "device_connected", provider: "grok"),
                                      state: Self.state, rules: ["grok": AgentAlertRule(sounds: false)]) == toast)
    }

    static let mutedState = CoreState(
        generation: 1,
        aggregate: CoreAggregate(),
        sessions: [CoreSession(id: "codex:2", provider: "codex", label: "core", mode: "working")],
        focus: CoreFocus(mode: "mute", bannerAllowed: false, audibleAllowed: false))

    @Test("a rule that always banners finishes cannot widen past quiet")
    func rulesStayInsideQuiet() {
        let event = CoreEvent(id: "c", kind: "completed", session: "codex:2", provider: "codex")
        let rules = ["codex": AgentAlertRule(completions: true)]
        let unmuted = AgentAlertRules.apply(EventDelivery(sound: "Glass"), to: event, state: Self.state, rules: rules)
        #expect(unmuted.notification?.title == "core finished", "the control: without quiet the rule banners")
        let muted = AgentAlertRules.apply(EventDelivery(sound: "Glass"), to: event, state: Self.mutedState, rules: rules)
        #expect(muted.notification == nil)
        #expect(muted.sound == nil)
        // A pass through the policy first, as the coordinator does it.
        let decided = EventPolicy.delivery(for: event, state: Self.mutedState, settings: nil)
        let ruled = AgentAlertRules.apply(decided, to: event, state: Self.mutedState, rules: rules)
        #expect(ruled.notification == nil)
    }

    @Test("a notify-when-done watch is the one banner quiet does not hold, and it adds no sound")
    func watchBeatsQuiet() {
        let event = CoreEvent(id: "c", kind: "completed", session: "codex:2", provider: "codex")
        let rules = ["codex": AgentAlertRule(completions: true)]
        let ruled = AgentAlertRules.apply(EventDelivery(sound: "Glass"), to: event, state: Self.mutedState, rules: rules)
        let watched = AgentAlertRules.notifyWhenDone(ruled, event: event, state: Self.mutedState)
        #expect(watched.notification?.title == "core finished")
        #expect(watched.sound == nil)
    }

    static let asksOnlyState = CoreState(
        generation: 1,
        aggregate: CoreAggregate(),
        sessions: [CoreSession(id: "codex:2", provider: "codex", label: "core", mode: "working")],
        focus: CoreFocus(mode: "asks_only", bannerAllowed: true, audibleAllowed: true, outbound: "asks"))

    @Test("a rule that banners finishes stays inside Asks only, and a watch still banners without a sound")
    func rulesStayInsideAsksOnly() {
        let event = CoreEvent(id: "c", kind: "completed", session: "codex:2", provider: "codex")
        let rules = ["codex": AgentAlertRule(completions: true)]
        let widened = AgentAlertRules.apply(EventDelivery(sound: "Glass"), to: event, state: Self.asksOnlyState, rules: rules)
        #expect(widened.notification == nil, "the rule widens a finish; Asks only admits none")
        #expect(widened.sound == nil)
        // The clamp is the same one the coordinator's rules hook composes.
        let composed = EventPolicy.holdingQuiet(widened, for: event, focus: Self.asksOnlyState.focus)
        #expect(composed.notification == nil)
        // The explicit watch is the one documented exception.
        let watched = AgentAlertRules.notifyWhenDone(composed, event: event, state: Self.asksOnlyState)
        #expect(watched.notification?.title == "core finished")
        #expect(watched.sound == nil)
        // An ask under the same rule set is admitted and is not silenced by it.
        let ask = CoreEvent(id: "a", kind: "ask_opened", session: "codex:2", provider: "codex")
        let asked = AgentAlertRules.apply(Self.askDelivery, to: ask, state: Self.asksOnlyState, rules: rules)
        #expect(asked == Self.askDelivery)
    }

    @Test("a rule's escalation still lets quiet stop the chime it would have started")
    func rulesKeepQuietChime() {
        let loud = EventDelivery(statusPulse: true, chime: .start)
        let codexStage = CoreEvent(id: "s", kind: "escalation_stage", session: "codex:2", stage: 3)
        let out = AgentAlertRules.apply(loud, to: codexStage, state: Self.mutedState,
                                        rules: ["codex": AgentAlertRule(escalationCeiling: 3)])
        // Nothing in the rule starts a chime, so the delivery's own
        // chime is all that is in play; quiet stops it.
        #expect(out.chime == .stop)
        #expect(out.statusPulse == true)
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

    @Test("rules persist inside the Agent Overview settings, missing keys follow the global policy")
    func persistence() throws {
        var settings = AgentOverviewSettings()
        settings.alertRules = ["grok": AgentAlertRule(asks: false, escalationCeiling: 9)]
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AgentOverviewSettings.self, from: data)
        #expect(decoded.alertRules["grok"]?.asks == false)
        #expect(decoded.alertRules["grok"]?.escalationCeiling == 3)
        let old = try JSONDecoder().decode(AgentOverviewSettings.self, from: Data(#"{"enabled":true}"#.utf8))
        #expect(old.alertRules.isEmpty)
        let partial = try JSONDecoder().decode(AgentAlertRule.self, from: Data(#"{"sounds":false}"#.utf8))
        #expect(partial.asks && partial.failures && !partial.sounds && partial.completions == nil)
        #expect(partial.summary == "no sounds")
        #expect(AgentAlertRule().summary == nil)
    }
}
