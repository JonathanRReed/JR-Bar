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
    /// The daemon's whole focus document, with its effect axes.
    static func state(quiet focus: CoreFocus?, sessions: [CoreSession] = [], asks: [CoreAsk] = []) -> CoreState {
        CoreState(sessions: sessions, asks: asks, focus: focus)
    }

    static let bannersOn = settings(["completion_notification_enabled": .bool(true), "quota_alerts_enabled": .bool(true)])
    static let completedEvent = CoreEvent(id: "q1", kind: "completed", session: "codex:1", sound: "glass", notify: true)
    static let askEvent = CoreEvent(id: "q2", kind: "ask_opened", session: "codex:1", sound: "funk", notify: true)
    static let failedEvent = CoreEvent(id: "q3", kind: "failed", session: "codex:1", sound: "basso", notify: true)
    static let quotaEvent = CoreEvent(id: "q4", kind: "quota_crossed", notify: true, provider: "claude", detail: "crossed 90%")
    static let stage3Event = CoreEvent(id: "q5", kind: "escalation_stage", session: "codex:1", notify: true, stage: 3)

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

    @Test("dim keeps the banner and drops the sound; pause also stops the chime")
    func dimKeepsBannersPauseStopsChime() {
        let completed = CoreEvent(id: "6", kind: "completed", session: "codex:1", sound: "glass", notify: true)
        let dim = EventPolicy.delivery(for: completed, state: Self.state(focus: "dim"), settings: Self.settings(["completion_notification_enabled": .bool(true)]))
        #expect(dim.sound == nil)
        #expect(dim.notification != nil)
        let stage3 = CoreEvent(id: "7", kind: "escalation_stage", session: "codex:1", notify: true, stage: 3)
        let loud = EventPolicy.delivery(for: stage3, state: Self.state(), settings: Self.settings(["escalation_tier": .string("chime")]))
        #expect(loud.chime == .start)
        #expect(loud.statusPulse == true)
        let paused = EventPolicy.delivery(for: stage3, state: Self.state(focus: "pause"), settings: Self.settings(["escalation_tier": .string("chime")]))
        #expect(paused.chime == .stop)
        #expect(paused.statusPulse == true, "the icon still pulses; only sound is held")
    }

    @Test("fully dark holds the banner as well as the sound")
    func dark() {
        // The daemon's Dark says banner_allowed false and audible_allowed
        // false, and docs/archive/VISION.md has Fully Dark withhold every visual
        // interruption; it used to keep the banner.
        let axes = CoreFocus(mode: "dark", bannerAllowed: false, audibleAllowed: false)
        let withheld = EventPolicy.delivery(for: Self.completedEvent, state: Self.state(quiet: axes), settings: Self.bannersOn)
        #expect(withheld.sound == nil)
        #expect(withheld.notification == nil)
        // An older daemon that sends only the mode word reads the same.
        let wordOnly = EventPolicy.delivery(for: Self.completedEvent, state: Self.state(focus: "dark"), settings: Self.bannersOn)
        #expect(wordOnly.sound == nil)
        #expect(wordOnly.notification == nil)
    }

    @Test("mute holds every banner and sound, and leaves the escalation's picture standing")
    func mute() {
        let axes = CoreFocus(mode: "mute", bannerAllowed: false, audibleAllowed: false, outbound: "none")
        let muted = Self.state(quiet: axes, sessions: [Self.codex])
        for event in [Self.completedEvent, Self.askEvent, Self.failedEvent, Self.quotaEvent] {
            let delivery = EventPolicy.delivery(for: event, state: muted, settings: Self.bannersOn)
            #expect(delivery.sound == nil, Comment(rawValue: event.kind))
            #expect(delivery.notification == nil, Comment(rawValue: event.kind))
        }
        // The light and the panel still show the ask; the pulse is a
        // display fact, so only the chime goes quiet.
        let takeover = Self.settings(["escalation_tier": .string("takeover")])
        let stage = EventPolicy.delivery(for: Self.stage3Event, state: muted, settings: takeover)
        #expect(stage.statusPulse == true)
        #expect(stage.chime == .stop)
        #expect(stage.takeover, "a picture, not a sound")
        // An answered ask still takes its banner back.
        let resolved = EventPolicy.delivery(for: CoreEvent(id: "q6", kind: "ask_resolved", session: "codex:1"),
                                            state: Self.state(quiet: axes), settings: Self.bannersOn)
        #expect(resolved.withdrawNotification == "ask:codex:1")
        #expect(resolved.statusPulse == false)
        #expect(resolved.chime == .stop)
        // An older daemon that sends only the mode word reads the same.
        let wordOnly = EventPolicy.delivery(for: Self.completedEvent, state: Self.state(focus: "mute"), settings: Self.bannersOn)
        #expect(wordOnly.sound == nil)
        #expect(wordOnly.notification == nil)
    }

    @Test("a call's quiet holds the sounds, on the axis, though the mode reads off")
    func callQuiet() {
        // A call's default quiet takes only the sounds: mode "off",
        // audible_allowed false, banners still allowed.
        let axes = CoreFocus(mode: "off", source: "call", bannerAllowed: true, audibleAllowed: false)
        let state = Self.state(quiet: axes, sessions: [Self.codex])
        let finish = EventPolicy.delivery(for: Self.completedEvent, state: state, settings: Self.bannersOn)
        #expect(finish.sound == nil)
        #expect(finish.notification != nil)
        let question = EventPolicy.delivery(for: Self.askEvent, state: state, settings: Self.bannersOn)
        #expect(question.sound == nil)
        #expect(question.notification?.category == .ask)
        let failure = EventPolicy.delivery(for: Self.failedEvent, state: state, settings: Self.bannersOn)
        #expect(failure.sound == nil)
        #expect(failure.notification != nil)
        let ladder = EventPolicy.delivery(for: Self.stage3Event, state: state, settings: Self.settings(["escalation_tier": .string("chime")]))
        #expect(ladder.chime == .stop)
        #expect(ladder.statusPulse == true)
    }

    @Test("the axes decide, not the first contribution's mode word")
    func composedQuiet() {
        // A schedule's Dim under a Mute Focus reports mode "dim", with both
        // axes false: the banner goes, though a dim alone keeps it.
        let axes = CoreFocus(mode: "dim", source: "schedule", bannerAllowed: false, audibleAllowed: false)
        let delivery = EventPolicy.delivery(for: Self.completedEvent, state: Self.state(quiet: axes), settings: Self.bannersOn)
        #expect(delivery.sound == nil)
        #expect(delivery.notification == nil)
    }

    static let quotaPaceEvent = CoreEvent(id: "q7", kind: "quota_pace", label: "5-hour", notify: true, provider: "codex",
                                          detail: "30% left · runs out around 3:40 PM · resets 5:30 PM")
    static let quotaResetEvent = CoreEvent(id: "q8", kind: "quota_reset", notify: true, provider: "codex")

    @Test("asks only lets an ask through and holds the rest by kind, though the switches allow them")
    func asksOnly() {
        let axes = CoreFocus(mode: "asks_only", bannerAllowed: true, audibleAllowed: true, outbound: "asks")
        let quiet = Self.state(quiet: axes, sessions: [Self.codex])
        for event in [Self.completedEvent, Self.failedEvent, Self.quotaEvent, Self.quotaPaceEvent, Self.quotaResetEvent] {
            let delivery = EventPolicy.delivery(for: event, state: quiet, settings: Self.bannersOn)
            #expect(delivery.sound == nil, Comment(rawValue: event.kind))
            #expect(delivery.notification == nil, Comment(rawValue: event.kind))
        }
        let ask = EventPolicy.delivery(for: Self.askEvent, state: quiet, settings: Self.bannersOn)
        #expect(ask.sound == "Funk")
        #expect(ask.notification?.category == .ask)
        // The frontmost-pane rule is the same as ever: no burst, the banner for the record.
        let watched = EventPolicy.delivery(for: Self.askEvent, state: quiet, settings: Self.bannersOn, askingFrontmost: true)
        #expect(watched.sound == nil)
        #expect(watched.notification?.category == .ask)
        // The ladder that climbs for an ask is an ask: it keeps its chime.
        let chime = Self.settings(["escalation_tier": .string("chime")])
        let ladder = EventPolicy.delivery(for: Self.stage3Event, state: quiet, settings: chime)
        #expect(ladder.chime == .start)
        #expect(ladder.statusPulse == true)
        // An answered ask still takes its banner back.
        let resolved = EventPolicy.delivery(for: CoreEvent(id: "q9", kind: "ask_resolved", session: "codex:1"),
                                            state: Self.state(quiet: axes), settings: Self.bannersOn)
        #expect(resolved.withdrawNotification == "ask:codex:1")
    }

    @Test("pause keeps asks and failures, holds the courtesy kinds, and still holds every sound")
    func pause() {
        let axes = CoreFocus(mode: "pause", outbound: "critical")
        let paused = Self.state(quiet: axes, sessions: [Self.codex])
        let finish = EventPolicy.delivery(for: Self.completedEvent, state: paused, settings: Self.bannersOn)
        #expect(finish.sound == nil)
        #expect(finish.notification == nil)
        for event in [Self.quotaEvent, Self.quotaPaceEvent, Self.quotaResetEvent] {
            #expect(EventPolicy.delivery(for: event, state: paused, settings: Self.bannersOn).notification == nil,
                    Comment(rawValue: event.kind))
        }
        let failure = EventPolicy.delivery(for: Self.failedEvent, state: paused, settings: Self.bannersOn)
        #expect(failure.notification?.title == "sidepulse-core failed")
        #expect(failure.sound == nil, "pause has always held every sound")
        let question = EventPolicy.delivery(for: Self.askEvent, state: paused, settings: Self.bannersOn)
        #expect(question.notification?.category == .ask)
        #expect(question.sound == nil)
        let chime = Self.settings(["escalation_tier": .string("chime")])
        let ladder = EventPolicy.delivery(for: Self.stage3Event, state: paused, settings: chime)
        #expect(ladder.chime == .stop)
        #expect(ladder.statusPulse == true)
    }

    @Test("the outbound word alone decides by kind, and 'all' or an unknown word changes nothing")
    func outboundAlone() {
        // No effect booleans at all: only `outbound` speaks.
        let none = Self.state(quiet: CoreFocus(mode: "off", outbound: "none"), sessions: [Self.codex])
        for event in [Self.completedEvent, Self.askEvent, Self.failedEvent, Self.quotaEvent] {
            let delivery = EventPolicy.delivery(for: event, state: none, settings: Self.bannersOn)
            #expect(delivery.sound == nil, Comment(rawValue: event.kind))
            #expect(delivery.notification == nil, Comment(rawValue: event.kind))
        }
        let baseline = EventPolicy.delivery(for: Self.completedEvent, state: Self.state(), settings: Self.bannersOn)
        for word in ["all", "someday"] {
            let state = Self.state(quiet: CoreFocus(mode: "off", outbound: word))
            let delivery = EventPolicy.delivery(for: Self.completedEvent, state: state, settings: Self.bannersOn)
            #expect(delivery == baseline, Comment(rawValue: word))
        }
    }

    @Test("holding quiet clears sounds and banners and touches nothing else")
    func holdingQuiet() {
        let banner = EventDelivery.Notification(identifier: "ask:codex:1", title: "needs you", body: "?", category: .ask)
        let loud = EventDelivery(sound: "Funk", soundRepeats: 3, notification: banner, toast: "Dock connected",
                                 withdrawNotification: "ask:codex:0", statusPulse: true, chime: .start, takeover: true)
        let muted = CoreFocus(mode: "mute", bannerAllowed: false, audibleAllowed: false)
        let held = EventPolicy.holdingQuiet(loud, for: Self.askEvent, focus: muted)
        #expect(held.sound == nil)
        #expect(held.notification == nil)
        #expect(held.chime == .stop, "a starting chime is a sound")
        #expect(held.toast == "Dock connected")
        #expect(held.withdrawNotification == "ask:codex:0")
        #expect(held.statusPulse == true)
        #expect(held.takeover)

        // Sounds alone, on the axis: the banner stays.
        let call = CoreFocus(mode: "off", source: "call", bannerAllowed: true, audibleAllowed: false)
        let soundsOnly = EventPolicy.holdingQuiet(loud, for: Self.askEvent, focus: call)
        #expect(soundsOnly.sound == nil)
        #expect(soundsOnly.notification == banner)

        // Banners alone, on the axis: the sound stays.
        let silentBanners = CoreFocus(mode: "off", bannerAllowed: false, audibleAllowed: true)
        let bannersOnly = EventPolicy.holdingQuiet(loud, for: Self.askEvent, focus: silentBanners)
        #expect(bannersOnly.sound == "Funk")
        #expect(bannersOnly.notification == nil)
        #expect(bannersOnly.chime == .start)

        // A kind the outbound admission leaves out loses its sound, chime
        // and banner, and nothing else; an admitted kind comes back as it was.
        let asks = CoreFocus(mode: "asks_only", bannerAllowed: true, audibleAllowed: true, outbound: "asks")
        let left = EventPolicy.holdingQuiet(loud, for: Self.completedEvent, focus: asks)
        #expect(left.sound == nil)
        #expect(left.notification == nil)
        #expect(left.chime == .stop)
        #expect(left.toast == "Dock connected")
        #expect(left.withdrawNotification == "ask:codex:0")
        #expect(left.statusPulse == true)
        #expect(left.takeover)
        let kept = EventPolicy.holdingQuiet(loud, for: Self.askEvent, focus: asks)
        #expect(kept == loud)
        let critical = CoreFocus(mode: "off", outbound: "critical")
        #expect(EventPolicy.holdingQuiet(loud, for: Self.failedEvent, focus: critical) == loud)
        #expect(EventPolicy.holdingQuiet(loud, for: Self.quotaEvent, focus: critical).notification == nil)

        // No focus, or an open one: the delivery comes back as it was.
        #expect(EventPolicy.holdingQuiet(loud, for: Self.completedEvent, focus: nil) == loud)
        #expect(EventPolicy.holdingQuiet(loud, for: Self.completedEvent, focus: CoreFocus(mode: "off")) == loud)
        // A stop and an unchanged chime are not sounds.
        let stopping = EventDelivery(statusPulse: false, chime: .stop)
        #expect(EventPolicy.holdingQuiet(stopping, for: Self.askEvent, focus: muted) == stopping)
    }

    @Test("an absent or open focus changes nothing")
    func openFocus() {
        let baseline = EventPolicy.delivery(for: Self.completedEvent, state: Self.state(), settings: Self.bannersOn)
        #expect(baseline.sound == "Glass")
        #expect(baseline.notification != nil)
        let openFocuses = [CoreFocus(mode: "off"), CoreFocus(mode: nil), CoreFocus(mode: "off", bannerAllowed: true, audibleAllowed: true, outbound: "all")]
        for focus in openFocuses {
            let delivery = EventPolicy.delivery(for: Self.completedEvent, state: Self.state(quiet: focus), settings: Self.bannersOn)
            #expect(delivery == baseline, Comment(rawValue: String(describing: focus.mode)))
        }
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

    @Test("take over is its own stage: the chime plus the ask grown out of the notch")
    func takeoverTier() {
        let stage3 = CoreEvent(id: "30", kind: "escalation_stage", session: "codex:1", notify: true, stage: 3)
        let takeover = Self.settings(["escalation_tier": .string("takeover")])
        let loud = EventPolicy.delivery(for: stage3, state: Self.state(), settings: takeover)
        #expect(loud.takeover)
        #expect(loud.chime == .start, "the loudest tier keeps the chime")
        #expect(!loud.isSilent)

        // Chime is chime: it never takes the notch over.
        let chime = EventPolicy.delivery(for: stage3, state: Self.state(),
                                         settings: Self.settings(["escalation_tier": .string("chime")]))
        #expect(!chime.takeover)
        #expect(chime.chime == .start)

        // Below the finale, a watched pane or a paused Mac: no takeover.
        let stage2 = CoreEvent(id: "31", kind: "escalation_stage", session: "codex:1", notify: true, stage: 2)
        #expect(!EventPolicy.delivery(for: stage2, state: Self.state(), settings: takeover).takeover)
        #expect(!EventPolicy.delivery(for: stage3, state: Self.state(), settings: takeover,
                                      askingFrontmost: true).takeover)
        #expect(!EventPolicy.delivery(for: stage3, state: Self.state(focus: "pause"), settings: takeover).takeover)
        // Dim silences sounds, not pictures; takeover is a picture.
        let dim = EventPolicy.delivery(for: stage3, state: Self.state(focus: "dim"), settings: takeover)
        #expect(dim.takeover)
        #expect(dim.chime == .stop)

        #expect(EventPolicy.isTakeoverTier("takeover"))
        #expect(EventPolicy.isTakeoverTier("TAKEOVER"))
        #expect(!EventPolicy.isTakeoverTier("chime"))
        #expect(!EventPolicy.isTakeoverTier(nil))
        #expect(!EventDelivery(takeover: false).takeover)
    }

    @Test("a frontmost asking pane quiets the ladder but keeps the record")
    func askingFrontmost() {
        let ask = CoreEvent(id: "20", kind: "ask_opened", session: "codex:1", label: "sidepulse-core",
                            sound: "funk", notify: true, detail: "Run: rm -rf build")
        let quiet = EventPolicy.delivery(for: ask, state: Self.state(sessions: [Self.codex]),
                                         settings: Self.settings(["alert_burst": .number(3)]),
                                         askingFrontmost: true)
        #expect(quiet.sound == nil, "the user is already looking at the pane — no burst")
        #expect(quiet.notification?.category == .ask, "the banner still lands for the record")
        let stage3 = CoreEvent(id: "21", kind: "escalation_stage", session: "codex:1", notify: true, stage: 3)
        let suppressed = EventPolicy.delivery(for: stage3, state: Self.state(),
                                              settings: Self.settings(["escalation_tier": .string("chime")]),
                                              askingFrontmost: true)
        #expect(suppressed.statusPulse == false, "no amber pulse while the pane is in front")
        #expect(suppressed.chime == .stop)
        // Walking away re-arms the same stage — the default argument is
        // the unsuppressed read every existing caller already had.
        let loud = EventPolicy.delivery(for: stage3, state: Self.state(),
                                        settings: Self.settings(["escalation_tier": .string("chime")]))
        #expect(loud.statusPulse == true)
        #expect(loud.chime == .start)
        let stage2 = CoreEvent(id: "22", kind: "escalation_stage", session: "codex:1", notify: true, stage: 2)
        #expect(EventPolicy.delivery(for: stage2, state: Self.state(), settings: nil, askingFrontmost: true).statusPulse == false)
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
        // Absent means off everywhere — the daemon, the toggle and the
        // policy all read `quota_alerts_enabled` the same way.
        let quotaDefault = EventPolicy.delivery(for: CoreEvent(id: "12", kind: "quota_crossed", label: "5h window at 90%", notify: true, provider: "claude", detail: "crossed 90%"), state: Self.state(), settings: nil)
        #expect(quotaDefault == .nothing)
        let quotaOn = EventPolicy.delivery(for: CoreEvent(id: "12b", kind: "quota_crossed", label: "5h window at 90%", notify: true, provider: "claude", detail: "crossed 90%"), state: Self.state(), settings: Self.settings(["quota_alerts_enabled": .bool(true)]))
        #expect(quotaOn.notification?.title == "Claude usage crossed 90%")
        #expect(quotaOn.sound == "Pop")
        let quotaOff = EventPolicy.delivery(for: CoreEvent(id: "13", kind: "quota_crossed", notify: true, provider: "claude"), state: Self.state(), settings: Self.settings(["quota_alerts_enabled": .bool(false)]))
        #expect(quotaOff == .nothing)
        let resetDefault = EventPolicy.delivery(for: CoreEvent(id: "14", kind: "quota_reset", notify: true, provider: "codex"), state: Self.state(), settings: nil)
        #expect(resetDefault == .nothing)
        let reset = EventPolicy.delivery(for: CoreEvent(id: "14b", kind: "quota_reset", notify: true, provider: "codex"), state: Self.state(), settings: Self.settings(["quota_alerts_enabled": .bool(true)]))
        #expect(reset.sound == nil)
        #expect(reset.notification?.title == "Codex quota reset")
        let paceEvent = CoreEvent(id: "14c", kind: "quota_pace", label: "5-hour", notify: true, provider: "codex",
                                  detail: "30% left · runs out around 3:40 PM · resets 5:30 PM")
        #expect(EventPolicy.delivery(for: paceEvent, state: Self.state(), settings: nil) == .nothing)
        let pace = EventPolicy.delivery(for: paceEvent, state: Self.state(), settings: Self.settings(["quota_alerts_enabled": .bool(true)]))
        #expect(pace.sound == "Pop")
        #expect(pace.notification?.title == "Codex is running low")
        #expect(pace.notification?.body == "5-hour: 30% left · runs out around 3:40 PM · resets 5:30 PM")
        #expect(pace.notification?.identifier == "quota:codex")
        let quietPace = EventPolicy.delivery(for: paceEvent, state: Self.state(focus: "dim"), settings: Self.settings(["quota_alerts_enabled": .bool(true)]))
        #expect(quietPace.sound == nil && quietPace.notification != nil)
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
