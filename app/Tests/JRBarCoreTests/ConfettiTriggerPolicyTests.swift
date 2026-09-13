import Foundation
import Testing
@testable import JRBarCore

/// The confetti trigger table: which events and state edges earn a
/// burst, and the dedup that keeps each fact to once. The defaults must
/// be exactly the behaviour the toy has always had — a weekly refill and
/// nothing else — so an existing user's file changes nothing.
@Suite("Confetti trigger policy")
struct ConfettiTriggerPolicyTests {
    static func settings(_ edit: (inout ConfettiSettings) -> Void = { _ in }) -> ConfettiSettings {
        var settings = ConfettiSettings()
        edit(&settings)
        return settings
    }

    static func state(generation: Int = 1, asks: [CoreAsk] = [],
                      sessions: [CoreSession] = [], providers: [CoreProviderUsage] = []) -> CoreState {
        CoreState(generation: generation, sessions: sessions, asks: asks,
                  usage: CoreUsage(providers: providers))
    }

    // MARK: Defaults & decoding

    @Test("defaults are the shipped behaviour: weekly resets only")
    func defaults() {
        let triggers = ConfettiSettings().triggers
        #expect(triggers.weeklyReset)
        #expect(!triggers.sessionCompleted && !triggers.codexBankedReset && !triggers.allClear)
        #expect(triggers.perProviderReset.isEmpty)
    }

    @Test("missing and mistyped trigger keys decode to the defaults")
    func decode() throws {
        let decode = { (json: String) throws -> ConfettiSettings in
            try JSONDecoder().decode(ConfettiSettings.self, from: Data(json.utf8))
        }
        #expect(try decode("{}").triggers == ConfettiTriggers())
        #expect(try decode(#"{"triggers": "loud"}"#).triggers == ConfettiTriggers())
        let partial = try decode(#"{"triggers": {"sessionCompleted": true, "weeklyReset": "yes"}}"#)
        #expect(partial.triggers.sessionCompleted)
        #expect(partial.triggers.weeklyReset, "a mistyped flag falls back to the default, on")
        let picked = try decode(#"{"triggers": {"perProviderReset": ["Codex", "claude"]}}"#)
        #expect(picked.triggers.perProviderReset == ["codex", "claude"],
                "provider ids normalise to the lowercase the daemon sends")
        #expect(try decode(#"{"firedKeys": ["a", "", "b"]}"#).firedKeys == ["a", "b"])
    }

    // MARK: Events

    @Test("a weekly-lane quota_reset fires under defaults; other lanes stay quiet")
    func weeklyReset() {
        let weekly = ConfettiTriggerPolicy.eventFire(
            CoreEvent(id: "1", kind: "quota_reset", provider: "claude", lane: "weekly"),
            settings: Self.settings())
        #expect(weekly?.reason == .weeklyReset && weekly?.provider == "claude")
        #expect(ConfettiTriggerPolicy.eventFire(
            CoreEvent(id: "2", kind: "quota_reset", provider: "antigravity", lane: "claude-gpt-weekly"),
            settings: Self.settings())?.reason == .weeklyReset)
        #expect(ConfettiTriggerPolicy.eventFire(
            CoreEvent(id: "3", kind: "quota_reset", provider: "codex", lane: "five-hour"),
            settings: Self.settings()) == nil)
        #expect(ConfettiTriggerPolicy.eventFire(
            CoreEvent(id: "4", kind: "quota_reset", provider: "codex"),
            settings: Self.settings()) == nil,
            "a lane-less reset is not a weekly reset")
    }

    @Test("a picked provider's every lane fires, not only the weekly one")
    func perProviderReset() {
        let settings = Self.settings { $0.triggers.perProviderReset = ["codex"] }
        let fiveHour = ConfettiTriggerPolicy.eventFire(
            CoreEvent(id: "5", kind: "quota_reset", provider: "codex", lane: "five-hour"),
            settings: settings)
        #expect(fiveHour?.reason == .providerReset && fiveHour?.provider == "codex")
        #expect(ConfettiTriggerPolicy.eventFire(
            CoreEvent(id: "6", kind: "quota_reset", provider: "claude", lane: "five-hour"),
            settings: settings) == nil,
            "an unpicked provider stays quiet")
        // With the weekly toggle off a picked provider's weekly lane still fires.
        var noWeekly = settings
        noWeekly.triggers.weeklyReset = false
        #expect(ConfettiTriggerPolicy.eventFire(
            CoreEvent(id: "7", kind: "quota_reset", provider: "codex", lane: "weekly"),
            settings: noWeekly)?.reason == .providerReset)
    }

    @Test("completed events fire only when the trigger is on")
    func sessionCompleted() {
        let event = CoreEvent(id: "8", kind: "completed", provider: "claude")
        #expect(ConfettiTriggerPolicy.eventFire(event, settings: Self.settings()) == nil)
        let on = Self.settings { $0.triggers.sessionCompleted = true }
        let fire = ConfettiTriggerPolicy.eventFire(event, settings: on)
        #expect(fire?.reason == .sessionCompleted && fire?.provider == "claude")
    }

    @Test("kinds the toy never asked about stay quiet")
    func otherKinds() {
        var everything = ConfettiSettings()
        everything.triggers = ConfettiTriggers(sessionCompleted: true, weeklyReset: true,
                                               perProviderReset: ["codex"], codexBankedReset: true,
                                               allClear: true)
        for kind in ["ask_opened", "ask_resolved", "failed", "quota_crossed", "escalation_stage"] {
            #expect(ConfettiTriggerPolicy.eventFire(
                CoreEvent(id: "k-\(kind)", kind: kind, provider: "codex", lane: "weekly"),
                settings: everything) == nil, "\(kind) must never fire, lane or no lane")
        }
    }

    @Test("an event id already in the ring never fires again")
    func eventDedup() {
        var settings = Self.settings()
        let event = CoreEvent(id: "9", kind: "quota_reset", provider: "claude", lane: "weekly")
        let fire = ConfettiTriggerPolicy.eventFire(event, settings: settings)
        #expect(fire != nil)
        settings.noteFired(fire!.key)
        #expect(ConfettiTriggerPolicy.eventFire(event, settings: settings) == nil)
    }

    @Test("the ring keeps only its depth of keys")
    func ringLimit() {
        var settings = Self.settings()
        for index in 0..<(ConfettiSettings.firedKeyLimit + 5) {
            settings.noteFired("k\(index)")
        }
        #expect(settings.firedKeys.count == ConfettiSettings.firedKeyLimit)
        #expect(settings.firedKeys.first == "k5", "the oldest keys fall off")
        settings.noteFired("")
        #expect(settings.firedKeys.count == ConfettiSettings.firedKeyLimit)
    }

    // MARK: State edges

    @Test("Codex banked credits fire on a rise, once, and only for Codex")
    func codexBanked() {
        var tracker = ConfettiEdgeTracker()
        var settings = Self.settings()
        settings.triggers.codexBankedReset = true
        let codex = { (credits: Double?) in
            CoreProviderUsage(id: "codex", creditsRemaining: credits)
        }
        // The first document only seeds: a restart must not re-fire a
        // balance that predates it.
        #expect(tracker.note(Self.state(generation: 1, providers: [codex(40)]),
                           triggers: settings.triggers).isEmpty)
        #expect(tracker.note(Self.state(generation: 2, providers: [codex(40)]),
                           triggers: settings.triggers).isEmpty, "flat is not a gain")
        let fires = tracker.note(Self.state(generation: 3, providers: [codex(72)]),
                                 triggers: settings.triggers)
        #expect(fires.count == 1 && fires[0].reason == .codexBanked && fires[0].provider == "codex")
        // Re-folding the same document fires nothing — the key repeats.
        #expect(tracker.note(Self.state(generation: 3, providers: [codex(72)]),
                           triggers: settings.triggers).isEmpty)
        #expect(tracker.note(Self.state(generation: 4, providers: [codex(10)]),
                           triggers: settings.triggers).isEmpty, "spending is not a gain")
        // A balance that vanishes then returns higher still counts.
        #expect(tracker.note(Self.state(generation: 5, providers: [codex(nil)]),
                           triggers: settings.triggers).isEmpty)
        #expect(tracker.note(Self.state(generation: 6, providers: [codex(15)]),
                           triggers: settings.triggers).count == 1)
        // Another provider's credits are tracked but the trigger names Codex.
        let grok = CoreProviderUsage(id: "grok", creditsRemaining: 5)
        #expect(tracker.note(Self.state(generation: 7, providers: [grok]),
                           triggers: settings.triggers).isEmpty)
        #expect(tracker.note(Self.state(generation: 8, providers: [CoreProviderUsage(id: "grok", creditsRemaining: 9)]),
                           triggers: settings.triggers).isEmpty)
    }

    @Test("the codex trigger off means the rise is only a baseline update")
    func codexBankedOff() {
        var tracker = ConfettiEdgeTracker()
        let codex = CoreProviderUsage(id: "codex", creditsRemaining: 40)
        let off = Self.settings()
        #expect(tracker.note(Self.state(generation: 1, providers: [codex]),
                           triggers: off.triggers).isEmpty)
        var higher = codex
        higher.creditsRemaining = 50
        #expect(tracker.note(Self.state(generation: 2, providers: [higher]),
                           triggers: off.triggers).isEmpty)
    }

    @Test("the ask set emptying fires once when switched on")
    func allClear() {
        var tracker = ConfettiEdgeTracker()
        var settings = Self.settings()
        settings.triggers.allClear = true
        let ask = CoreAsk(session: "codex:1", kind: "permission", summary: "Run it?")
        #expect(tracker.note(Self.state(generation: 1), triggers: settings.triggers).isEmpty,
                "the first document only seeds")
        #expect(tracker.note(Self.state(generation: 2, asks: [ask]), triggers: settings.triggers).isEmpty,
                "asks appearing is not all-clear")
        let fires = tracker.note(Self.state(generation: 3), triggers: settings.triggers)
        #expect(fires == [ConfettiFire(reason: .allClear, key: "state:3:all-clear")])
        #expect(tracker.note(Self.state(generation: 4), triggers: settings.triggers).isEmpty,
                "still empty is not a new edge")
        // An ask carried on the session row counts the same as the list's.
        let session = CoreSession(id: "claude:1", provider: "claude",
                                  ask: CoreAsk(kind: "permission", summary: "Allow?"))
        #expect(tracker.note(Self.state(generation: 5, sessions: [session]),
                           triggers: settings.triggers).isEmpty)
        #expect(tracker.note(Self.state(generation: 6),
                           triggers: settings.triggers).count == 1)
    }

    @Test("the all-clear trigger off means the emptying is only tracked")
    func allClearOff() {
        var tracker = ConfettiEdgeTracker()
        let off = Self.settings()
        let ask = CoreAsk(session: "codex:1", kind: "permission")
        #expect(tracker.note(Self.state(generation: 1, asks: [ask]), triggers: off.triggers).isEmpty)
        #expect(tracker.note(Self.state(generation: 2), triggers: off.triggers).isEmpty)
        #expect(tracker.hadOpenAsks == false, "the fact is still tracked for the next comparison")
    }
}
