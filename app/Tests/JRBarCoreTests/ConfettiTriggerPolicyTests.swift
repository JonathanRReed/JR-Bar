import Foundation
import Testing
@testable import JRBarCore

/// The confetti trigger table: which events and state edges earn a
/// burst, and the dedup that keeps each fact to once.
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

    @Test("defaults celebrate quota resets only")
    func defaults() {
        let triggers = ConfettiSettings().triggers
        #expect(triggers.quotaReset)
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
        let partial = try decode(#"{"triggers": {"sessionCompleted": true, "quotaReset": "yes"}}"#)
        #expect(partial.triggers.sessionCompleted)
        #expect(partial.triggers.quotaReset, "a mistyped flag falls back to the default, on")
        let picked = try decode(#"{"triggers": {"perProviderReset": ["Codex", "claude"]}}"#)
        #expect(picked.triggers.perProviderReset == ["codex", "claude"],
                "provider ids normalise to the lowercase the daemon sends")
        #expect(try decode(#"{"firedKeys": ["a", "", "b"]}"#).firedKeys == ["a", "b"])
    }

    // MARK: Events

    @Test("every confirmed provider lane reset fires under defaults")
    func quotaReset() {
        for provider in ["claude", "codex", "copilot", "cursor", "future-provider"] {
            for lane in ["weekly", "five-hour", "daily", "monthly", "credits", "model-one"] {
                let event = CoreEvent(id: "reset", kind: "quota_reset", provider: provider, lane: lane)
                let fire = ConfettiTriggerPolicy.eventFire(event, settings: Self.settings())
                #expect(fire?.reason == .quotaReset && fire?.provider == provider)
            }
        }
        for event in [CoreEvent(id: "missing-lane", kind: "quota_reset", provider: "codex"),
                      CoreEvent(id: "missing-provider", kind: "quota_reset", lane: "daily"),
                      CoreEvent(id: "empty-lane", kind: "quota_reset", provider: "codex", lane: " "),
                      CoreEvent(id: "empty-provider", kind: "quota_reset", provider: "", lane: "daily")] {
            #expect(ConfettiTriggerPolicy.eventFire(event, settings: Self.settings()) == nil)
        }
    }

    @Test("legacy reset choices migrate and encode only the new key")
    func legacyResetChoices() throws {
        let legacy = Data(#"{"weeklyReset":false,"perProviderReset":["Codex"]}"#.utf8)
        let triggers = try JSONDecoder().decode(ConfettiTriggers.self, from: legacy)
        #expect(!triggers.quotaReset)
        #expect(triggers.perProviderReset == ["codex"])
        let encoded = try JSONEncoder().encode(triggers)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["quotaReset"] as? Bool == false)
        #expect(object["weeklyReset"] == nil)
        #expect(try JSONDecoder().decode(ConfettiTriggers.self, from: encoded) == triggers)
        let preferred = Data(#"{"quotaReset":true,"weeklyReset":false}"#.utf8)
        #expect(try JSONDecoder().decode(ConfettiTriggers.self, from: preferred).quotaReset)
    }

    @Test("a picked provider's every lane fires, not only the weekly one")
    func perProviderReset() {
        let settings = Self.settings {
            $0.triggers.quotaReset = false
            $0.triggers.perProviderReset = ["codex"]
        }
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
        noWeekly.triggers.quotaReset = false
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

    @Test("an odometer milestone fires under the Milestones switch, once per crossing")
    func odometerMilestone() throws {
        let data = Data(#"{"id":"ev-4","kind":"milestone","provider":"codex","label":"Completion milestone","detail":"50 finished","count":50,"reached":[25,50],"next_count":100,"cursor":"s1:ev-4"}"#.utf8)
        let event = try JSONDecoder().decode(CoreEvent.self, from: data)
        #expect(event.count == 50)
        #expect(ConfettiTriggerPolicy.eventFire(event, settings: Self.settings()) == nil,
                "off by default, like every trigger after the weekly one")
        var on = Self.settings { $0.triggers.milestones = true }
        let fire = try #require(ConfettiTriggerPolicy.eventFire(event, settings: on))
        #expect(fire.reason == .milestone && fire.provider == "codex" && fire.key == "event:s1:ev-4")
        on.noteFired(fire.key)
        #expect(ConfettiTriggerPolicy.eventFire(event, settings: on) == nil, "a replayed crossing never fires twice")
        // Completions alone never earn it: that is the Completed trigger's.
        let completed = CoreEvent(id: "ev-5", kind: "completed", provider: "codex")
        #expect(ConfettiTriggerPolicy.eventFire(completed, settings: on) == nil)
    }

    // MARK: A reset the daemon confirmed late, or offered again

    private func reset(eventID: String? = "claude:weekly:abc", lane: String? = "weekly",
                       at: Double?, cursor: String? = nil) -> CoreEvent {
        CoreEvent(id: eventID ?? "ev-1", kind: "quota_reset", at: at, provider: "claude",
                  lane: lane, cursor: cursor, eventId: eventID)
    }

    @Test("a quota_reset is keyed by the daemon's fact id, which outlives a restart")
    func resetKeyedByFactID() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let first = reset(at: now.timeIntervalSince1970 - 60, cursor: "run1:ev-4")
        let again = reset(at: now.timeIntervalSince1970 - 60, cursor: "run2:ev-1")
        #expect(ConfettiTriggerPolicy.eventKey(first) == "event:claude:weekly:abc")
        #expect(ConfettiTriggerPolicy.eventKey(first) == ConfettiTriggerPolicy.eventKey(again))
        var settings = Self.settings()
        let fire = try #require(ConfettiTriggerPolicy.eventFire(first, settings: settings, now: now))
        #expect(fire.reason == .quotaReset && fire.eventID == "claude:weekly:abc")
        settings.noteFired(fire.key)
        #expect(ConfettiTriggerPolicy.eventVerdict(again, settings: settings, now: now)
                == .dropped(.alreadyFired))
        // A different reset of the same lane is a new fact, so it fires.
        let nextWeek = reset(eventID: "claude:weekly:def", at: now.timeIntervalSince1970 - 60)
        #expect(ConfettiTriggerPolicy.eventFire(nextWeek, settings: settings, now: now) != nil)
        // Another kind keeps the journal's cursor.
        let done = CoreEvent(id: "ev-9", kind: "completed", cursor: "run1:ev-9")
        #expect(ConfettiTriggerPolicy.eventKey(done) == "event:run1:ev-9")
    }

    @Test("a reset confirmed hours after its boundary still celebrates; history does not")
    func resetFreshnessWindow() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let window = ConfettiTriggerPolicy.eventFreshnessWindow
        let settings = Self.settings()
        // Confirmed an hour ago, offered again on connect: celebrate.
        #expect(ConfettiTriggerPolicy.eventFire(
            reset(at: now.timeIntervalSince1970 - 3600), settings: settings, now: now) != nil)
        // Just inside the window.
        #expect(ConfettiTriggerPolicy.eventFire(
            reset(at: now.timeIntervalSince1970 - window + 1), settings: settings, now: now) != nil)
        // At and past it: genuinely old news — a restart never re-fires it.
        #expect(ConfettiTriggerPolicy.eventVerdict(
            reset(at: now.timeIntervalSince1970 - window), settings: settings, now: now)
            == .dropped(.stale))
        #expect(ConfettiTriggerPolicy.eventVerdict(
            reset(at: now.timeIntervalSince1970 - 30 * 86400), settings: settings, now: now)
            == .dropped(.stale))
        // No stamp, or one from a clock ahead of ours, is not evidence of age.
        #expect(ConfettiTriggerPolicy.eventFire(reset(at: nil), settings: settings, now: now) != nil)
        #expect(ConfettiTriggerPolicy.eventFire(
            reset(at: now.timeIntervalSince1970 + 600), settings: settings, now: now) != nil)
    }

    @Test("a reset that earns no burst says why")
    func resetDropReasons() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fresh = now.timeIntervalSince1970 - 60
        let resetsOff = Self.settings { $0.triggers.quotaReset = false }
        #expect(ConfettiTriggerPolicy.eventVerdict(reset(at: fresh), settings: resetsOff, now: now)
                == .dropped(.triggerOff))
        #expect(ConfettiTriggerPolicy.eventVerdict(
            reset(lane: "five-hour", at: fresh), settings: resetsOff, now: now)
            == .dropped(.triggerOff))
        #expect(ConfettiTriggerPolicy.eventVerdict(
            reset(lane: nil, at: fresh), settings: Self.settings(), now: now)
            == .dropped(.missingLane))
        #expect(ConfettiTriggerPolicy.eventVerdict(
            CoreEvent(id: "x", kind: "ask_opened"), settings: Self.settings(), now: now)
            == .unrelated)
        // The words the daemon's receipt store keeps.
        #expect(ConfettiTriggerDrop.alreadyFired.rawValue == "already_celebrated")
        #expect(ConfettiTriggerDrop.triggerOff.rawValue == "trigger_off")
    }

    @Test("the event_id and its receipt travel as the daemon spells them")
    func eventIDAndReceiptWire() throws {
        let data = Data(#"{"id":"claude:weekly:abc","kind":"quota_reset","provider":"claude","lane":"weekly","event_id":"claude:weekly:abc","at":1800000000}"#.utf8)
        let event = try JSONDecoder().decode(CoreEvent.self, from: data)
        #expect(event.eventId == "claude:weekly:abc")
        let receipt = ConfettiResetReceipt(eventID: "claude:weekly:abc", outcome: .held, reason: "call")
        #expect(receipt.args == ["event_id": .string("claude:weekly:abc"), "outcome": .string("held"),
                                 "reason": .string("call")])
    }

    @Test("an outside confetti request is the toy's to judge, never a trigger")
    func requestIsNotATrigger() {
        var everything = Self.settings { $0.triggers.milestones = true }
        everything.triggers.sessionCompleted = true
        #expect(ConfettiTriggerPolicy.eventFire(
            CoreEvent(id: "c-1", kind: "confetti", provider: "claude"), settings: everything) == nil)
    }

    @Test("kinds the toy never asked about stay quiet")
    func otherKinds() {
        var everything = ConfettiSettings()
        everything.triggers = ConfettiTriggers(sessionCompleted: true, quotaReset: true,
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

    @Test("reset settlement survives persistence and has a separate bounded replay lifetime")
    func resetSettlementPersistence() throws {
        var settings = Self.settings()
        settings.noteSettledReset("settled", at: 1000)
        let restored = try JSONDecoder().decode(ConfettiSettings.self, from: JSONEncoder().encode(settings))
        let reset = CoreEvent(id: "next-stream-event", kind: "quota_reset", at: 1000,
                              provider: "kilo", lane: "monthly", eventId: "settled")
        let verdict = ConfettiTriggerPolicy.eventVerdict(reset, settings: restored,
                                                       now: Date(timeIntervalSince1970: 1001))
        #expect(verdict == .dropped(.alreadyFired))
        #expect(restored.hasSettledReset("settled", at: 999))
        #expect(!restored.hasSettledReset("settled", at: 1000 + ConfettiTriggerPolicy.eventFreshnessWindow))
        var afterClockRollback = restored
        afterClockRollback.noteSettledReset("another-reset", at: 999)
        #expect(afterClockRollback.hasSettledReset("settled", at: 999))

        let entries = Dictionary(uniqueKeysWithValues: (0...ConfettiSettings.settledResetLimit).map {
            ("synthetic-\($0)", Double($0))
        })
        let document = try JSONSerialization.data(withJSONObject: ["settledResets": entries])
        let bounded = try JSONDecoder().decode(ConfettiSettings.self, from: document)
        #expect(bounded.settledResets.count == ConfettiSettings.settledResetLimit)
        #expect(bounded.settledResets["synthetic-0"] == nil)
        #expect(bounded.settledResets["synthetic-\(ConfettiSettings.settledResetLimit)"] != nil)
    }

    // MARK: State edges

    @Test("a reseed forgets the last document, and a new session keys its facts apart")
    func reseedAfterReconnect() {
        var tracker = ConfettiEdgeTracker(session: "run-a")
        var settings = Self.settings()
        settings.triggers.codexBankedReset = true
        let codex = { (credits: Double?) in
            CoreProviderUsage(id: "codex", creditsRemaining: credits)
        }
        #expect(tracker.note(Self.state(generation: 1, providers: [codex(40)]),
                             triggers: settings.triggers).isEmpty)
        let first = tracker.note(Self.state(generation: 2, providers: [codex(72)]),
                                 triggers: settings.triggers)
        #expect(first.count == 1)
        // The daemon restarts: the balance that rose across the gap only seeds.
        tracker.reseed(session: "run-b")
        #expect(tracker.note(Self.state(generation: 1, providers: [codex(90)]),
                             triggers: settings.triggers).isEmpty, "the first document after a reseed seeds")
        let second = tracker.note(Self.state(generation: 2, providers: [codex(120)]),
                                  triggers: settings.triggers)
        #expect(second.count == 1)
        #expect(second[0].key != first[0].key, "generation 2 of a new run is a new fact")
    }

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
