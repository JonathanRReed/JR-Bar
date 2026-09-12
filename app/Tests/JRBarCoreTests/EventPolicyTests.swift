import Foundation
import Testing
@testable import JRBarCore

@Suite("Event delivery policy")
struct EventPolicyTests {
    static func settings(_ members: [String: JSONValue]) -> SettingsDocument { SettingsDocument(.object(members)) }
    static let worker = CoreSession(id: "claude:w", provider: "claude", kind: "worker", parent: "claude:1", label: "worker")
    static let codex = CoreSession(id: "codex:1", provider: "codex", label: "sidepulse-core", mode: "waiting", ask: CoreAsk(kind: "permission", summary: "Run: rm -rf build"))
    static func state(focus: String? = nil, sessions: [CoreSession] = [], asks: [CoreAsk] = [], stage: String? = nil) -> CoreState {
        CoreState(sessions: sessions, asks: asks, focus: focus.map { CoreFocus(mode: $0) }, escalation: stage.map { CoreEscalation(stage: $0) })
    }

    @Test("a completion plays Glass and banners only when the setting allows")
    func completed() {
        let event = CoreEvent(id: "1", kind: "completed", session: "codex:1", label: "sidepulse-core", sound: "glass", notify: true)
        let on = EventPolicy.delivery(for: event, state: Self.state(sessions: [Self.codex]), settings: Self.settings(["completion_notification_enabled": .bool(true)]))
        #expect(on.sound == "Glass")
        #expect(on.notification?.title == "sidepulse-core finished")
        #expect(on.notification?.category == .plain)
        #expect(on.notification?.session == "codex:1")
        let off = EventPolicy.delivery(for: event, state: Self.state(), settings: Self.settings(["completion_notification_enabled": .bool(false)]))
        #expect(off.sound == "Glass")
        #expect(off.notification == nil)
        // The daemon's own default is off, so a settings document that
        // simply never mentions the key must read the same as `false` —
        // or a fresh install banners every completion.
        let absent = EventPolicy.delivery(for: event, state: Self.state(), settings: Self.settings(["alert_burst": .number(2)]))
        #expect(absent.sound == "Glass")
        #expect(absent.notification == nil)
        let noDoc = EventPolicy.delivery(for: event, state: Self.state(), settings: nil)
        #expect(noDoc.notification == nil)
        let silent = EventPolicy.delivery(for: CoreEvent(id: "2", kind: "completed", notify: false), state: Self.state(), settings: nil)
        #expect(silent == .nothing)
    }

    @Test("an ask uses the alert burst, the ask category, and skips sub-agents when told to")
    func ask() {
        let event = CoreEvent(id: "3", kind: "ask_opened", session: "codex:1", label: "sidepulse-core", sound: "funk", notify: true, detail: "Run: rm -rf build")
        let delivery = EventPolicy.delivery(for: event, state: Self.state(sessions: [Self.codex]), settings: Self.settings(["alert_burst": .number(3)]))
        #expect(delivery.sound == "Funk")
        #expect(delivery.soundRepeats == 3)
        #expect(delivery.notification?.category == .ask)
        #expect(delivery.notification?.identifier == "ask:codex:1")
        #expect(delivery.notification?.body == "Run: rm -rf build")
        let unknownSound = EventPolicy.delivery(for: CoreEvent(id: "4", kind: "ask_opened", session: "codex:1", sound: "kazoo", notify: true), state: Self.state(sessions: [Self.codex]), settings: nil)
        #expect(unknownSound.sound == "Funk", "an unknown sound name falls back to the kind's default")
        #expect(unknownSound.soundRepeats == 1)
        let subagent = CoreEvent(id: "5", kind: "ask_opened", session: "claude:w", label: "worker", notify: true)
        let muted = EventPolicy.delivery(for: subagent, state: Self.state(sessions: [Self.worker]), settings: Self.settings(["subagent_asks_alert": .bool(false)]))
        #expect(muted == .nothing)
        let allowed = EventPolicy.delivery(for: subagent, state: Self.state(sessions: [Self.worker]), settings: Self.settings(["subagent_asks_alert": .bool(true)]))
        #expect(allowed.notification != nil)
    }

    @Test("quiet modes keep the banner and drop the sound; pause also stops the chime")
    func quiet() {
        let completed = CoreEvent(id: "6", kind: "completed", session: "codex:1", sound: "glass", notify: true)
        for mode in ["dim", "dark"] {
            let delivery = EventPolicy.delivery(for: completed, state: Self.state(focus: mode), settings: Self.settings(["completion_notification_enabled": .bool(true)]))
            #expect(delivery.sound == nil, Comment(rawValue: mode))
            #expect(delivery.notification != nil, Comment(rawValue: mode))
        }
        let stage3 = CoreEvent(id: "7", kind: "escalation_stage", session: "codex:1", notify: true, stage: 3)
        let loud = EventPolicy.delivery(for: stage3, state: Self.state(), settings: Self.settings(["escalation_tier": .string("chime")]))
        #expect(loud.chime == .start)
        #expect(loud.statusPulse == true)
        let paused = EventPolicy.delivery(for: stage3, state: Self.state(focus: "pause"), settings: Self.settings(["escalation_tier": .string("chime")]))
        #expect(paused.chime == .stop)
        #expect(paused.statusPulse == true, "the icon still pulses; only sound is held")
    }

    @Test("the escalation tier caps the stage")
    func tiers() {
        #expect(EventPolicy.escalationCeiling("light") == 1)
        #expect(EventPolicy.escalationCeiling("menu_bar") == 2)
        #expect(EventPolicy.escalationCeiling("chime") == 3)
        #expect(EventPolicy.escalationCeiling("takeover") == 3)
        #expect(EventPolicy.escalationCeiling(nil) == 2)
        let stage3 = CoreEvent(id: "8", kind: "escalation_stage", stage: 3)
        let capped = EventPolicy.delivery(for: stage3, state: Self.state(), settings: Self.settings(["escalation_tier": .string("menu_bar")]))
        #expect(capped.statusPulse == true)
        #expect(capped.chime == .stop)
        let light = EventPolicy.delivery(for: stage3, state: Self.state(), settings: Self.settings(["escalation_tier": .string("light")]))
        #expect(light.statusPulse == false)
        let stage2FromState = EventPolicy.delivery(for: CoreEvent(id: "9", kind: "escalation_stage"), state: Self.state(stage: "menu_bar"), settings: nil)
        #expect(stage2FromState.statusPulse == true)
        #expect(CoreEscalation.stageNumber("final") == 3)
        #expect(CoreEscalation.stageNumber("2") == 2)
        #expect(CoreEscalation.stageNumber("none") == 0)
    }

    @Test("resolving the last ask withdraws its banner and stops the noise")
    func resolved() {
        let event = CoreEvent(id: "10", kind: "ask_resolved", session: "codex:1")
        let last = EventPolicy.delivery(for: event, state: Self.state(), settings: nil)
        #expect(last.withdrawNotification == "ask:codex:1")
        #expect(last.statusPulse == false)
        #expect(last.chime == .stop)
        let another = EventPolicy.delivery(for: event, state: Self.state(asks: [CoreAsk(session: "claude:1", kind: "permission")]), settings: nil)
        #expect(another.statusPulse == nil)
        #expect(another.chime == .unchanged)
    }

    @Test("failures, quota and devices")
    func rest() {
        let failed = EventPolicy.delivery(for: CoreEvent(id: "11", kind: "failed", session: "gemini:1", label: "docs-sweep", sound: "basso", notify: true, detail: "Exit 1"), state: Self.state(), settings: nil)
        #expect(failed.sound == "Basso")
        #expect(failed.notification?.title == "docs-sweep failed")
        #expect(failed.notification?.body == "Exit 1")
        let quota = EventPolicy.delivery(for: CoreEvent(id: "12", kind: "quota_crossed", label: "5h window at 90%", notify: true, provider: "claude", detail: "crossed 90%"), state: Self.state(), settings: nil)
        #expect(quota.notification?.title == "Claude usage crossed 90%")
        #expect(quota.sound == "Pop")
        let quotaOff = EventPolicy.delivery(for: CoreEvent(id: "13", kind: "quota_crossed", notify: true, provider: "claude"), state: Self.state(), settings: Self.settings(["quota_alerts_enabled": .bool(false)]))
        #expect(quotaOff == .nothing)
        let reset = EventPolicy.delivery(for: CoreEvent(id: "14", kind: "quota_reset", notify: true, provider: "codex"), state: Self.state(), settings: nil)
        #expect(reset.sound == nil)
        #expect(reset.notification?.title == "Codex quota reset")
        let device = EventPolicy.delivery(for: CoreEvent(id: "15", kind: "device_disconnected", label: "SidePulse", notify: true), state: Self.state(), settings: nil)
        #expect(device.toast == "SidePulse disconnected")
        #expect(device.notification == nil && device.sound == nil)
        let unknown = EventPolicy.delivery(for: CoreEvent(id: "16", kind: "something_new", notify: true), state: Self.state(), settings: nil)
        #expect(unknown == .nothing)
    }

    @Test("stage decodes from a number or a name")
    func decoding() throws {
        let numeric = try CoreCodec.decode(frame: Data(#"{"t":"event","v":1,"id":"e1","kind":"escalation_stage","stage":2}"#.utf8))
        guard case .event(let event) = numeric else { Issue.record("not an event"); return }
        #expect(event.stage == 2)
        let named = try CoreCodec.decode(frame: Data(#"{"t":"event","v":1,"id":"e2","kind":"escalation_stage","stage":"final","provider":"codex","detail":"x"}"#.utf8))
        guard case .event(let event2) = named else { Issue.record("not an event"); return }
        #expect(event2.stage == 3)
        #expect(event2.provider == "codex")
        #expect(event2.detail == "x")
    }
}
