import AppKit
import JRBarCore

/// Turns daemon events into things on the Mac: sounds, notifications, the
/// HUD toast, the status item's amber pulse and the stage-3 chime. The
/// decisions come from `EventPolicy`; this object only owns the players
/// and the timers.
@MainActor
final class EventCoordinator {
    let core: CoreModel
    let sounds = SoundPlayer()
    let notifications = NotificationBridge()
    let hud: NotchHUD

    var onStatusPulse: ((Bool) -> Void)?
    private(set) var isPulsing = false
    /// The Toys page's store: confetti fires on the user's triggers.
    /// Weak — the delegate owns it.
    weak var toys: ToysStore?

    /// The Agent utility's "quiet while the ask's pane is in front"
    /// setting, wired by the delegate; on by default.
    var quietWhenPaneFrontmost: @MainActor () -> Bool = { true }
    /// The Agent utility's per-provider alert rules, applied to what
    /// `EventPolicy` decided before anything plays; wired by the delegate,
    /// a pass-through until then.
    var deliveryRules: @MainActor (EventDelivery, CoreEvent) -> EventDelivery = { delivery, _ in delivery }
    /// The frontmost-app read, injectable so tests can stage the pane.
    var frontmostApp: @MainActor () -> (bundleID: String?, pid: Int32?) = {
        let app = NSWorkspace.shared.frontmostApplication
        return (app?.bundleIdentifier, app?.processIdentifier)
    }
    /// The daemon's `session_in_front` for a session — true, false, or
    /// nil when it cannot be told — injectable so tests stage the
    /// verdict. Asked, never prompting, on an ask and at each stage.
    var sessionInFront: @MainActor (String) async -> Bool?
    /// The last escalation_stage the daemon announced — remembered so a
    /// frontmost flip can re-decide the noise without waiting for the
    /// next stage boundary.
    private var lastEscalation: CoreEvent?
    /// The daemon's last word on whether the owner is watching an asking
    /// session, and under which frontmost app it was read.
    private(set) var inFrontVerdict: AskingPane.Verdict?
    /// The verdict a check in flight is for, so one ask never asks twice.
    private var inFrontAsking: String?

    init(core: CoreModel, hudAnchor: @escaping @MainActor () -> NSRect?) {
        self.core = core
        sessionInFront = { [weak core] session in
            guard let core, core.isLive else { return nil }
            let reply = try? await core.send("session_in_front", args: ["session": .string(session)], timeout: 3)
            return AskingPane.inFront(from: reply)
        }
        hud = NotchHUD(anchorRect: hudAnchor)
        sounds.onMissing = { [weak core] name in core?.appendLocalLog(level: "warn", "no system sound named \(name)") }
        notifications.onLog = { [weak core] line in core?.appendLocalLog(line) }
        notifications.onOpenSession = { [weak core] session in core?.openSession(session) }
        notifications.onAnswerAsk = { [weak core] session, approve in core?.answerAsk(session: session, approve: approve) }
        // One announcer at the top of the screen: the Mac's own news is
        // offered to the island first and takes the pill only when the
        // island can't; a headphone the ear already names is not said
        // twice.
        hud.islandPresent = { [weak self] notice in
            self?.toys?.notch.presentSystemNotice(notice) ?? false
        }
        hud.hudLife = { [weak self] in self?.toys?.state.notch.hudDuration ?? NotchHUD.life }
        hud.earAnnouncesAudioRoute = { [weak self] in self?.toys?.notch.earNoticesLive ?? false }
        // The Mac's Focus, said or not, is a quiet stretch the island's
        // hold follows.
        hud.announcements.onFocus = { [weak self] name, on in
            self?.toys?.notch.noteMacFocus(name: name, on: on)
        }
        // The coordinator lives for the app's lifetime; the observer's
        // weak self is cleanup enough (a nonisolated deinit could not
        // touch the isolated token anyway).
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reapplyEscalationNoise() }
        }
        trackState()
    }

    /// Re-arms an observation of the applied state after every document
    /// and hands it to the confetti toy: the banked-credits and
    /// all-clear triggers are document edges, not events — no `event`
    /// frame ever carries them.
    private func trackState() {
        withObservationTracking {
            _ = core.state
        } onChange: { [weak self] in
            // onChange fires from the property's willSet — read the new
            // document after a hop, like every other observe loop does.
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let state = self.core.state {
                    self.toys?.confetti.noteState(state)
                    self.toys?.notchBuddy.noteState(state)
                    // The daemon's focus_sync reading — a Focus toggle
                    // announces in the notch pill.
                    self.hud.announcements.noteDaemonFocus(mode: state.focus?.mode,
                                                           source: state.focus?.source)
                }
                self.trackState()
            }
        }
    }

    func handle(_ event: CoreEvent) {
        let settings = core.settings.map { SettingsDocument($0.document) }
        let watching = askingPaneFrontmost(sessionID: event.session)
        let delivery = deliveryRules(EventPolicy.delivery(for: event, state: core.state, settings: settings,
                                                          askingFrontmost: watching), event)
        if event.kind == "escalation_stage" { lastEscalation = event }
        apply(delivery, for: event)
        confirmWatching(event, decidedWatching: watching)
        var summary = "event \(event.kind)"
        if let label = event.label, !label.isEmpty { summary += " · \(label)" }
        if delivery.isSilent { summary += " (quiet)" }
        else {
            var parts: [String] = []
            if let sound = delivery.sound { parts.append(delivery.soundRepeats > 1 ? "\(sound)×\(delivery.soundRepeats)" : sound) }
            if delivery.notification != nil { parts.append("banner") }
            if let toast = delivery.toast { parts.append("hud “\(toast)”") }
            if let pulse = delivery.statusPulse { parts.append(pulse ? "pulse on" : "pulse off") }
            if delivery.chime == .start { parts.append("chime every \(Int(EventPolicy.chimeInterval)) s") }
            if delivery.takeover { parts.append("notch takeover") }
            if delivery.chime == .stop, sounds.isChiming { parts.append("chime off") }
            // A delivery whose whole job is to take a banner away has
            // nothing else to name; the log said "event ask_resolved → ".
            if parts.isEmpty, delivery.withdrawNotification != nil { parts.append("banner withdrawn") }
            summary += parts.isEmpty ? " (quiet)" : " → " + parts.joined(separator: ", ")
        }
        core.appendLocalLog(summary)
        NSLog("JR-Bar: %@", summary)
    }

    func apply(_ delivery: EventDelivery, for event: CoreEvent) {
        if let sound = delivery.sound { sounds.play(sound, repeats: delivery.soundRepeats) }
        if let identifier = delivery.withdrawNotification { notifications.withdraw(identifier: identifier) }
        if let notification = delivery.notification { notifications.deliver(notification) }
        if let toast = delivery.toast {
            let symbol = event.kind == "device_disconnected" ? "cable.connector.slash" : (event.kind.hasPrefix("peer") ? "person.2.wave.2" : "cable.connector")
            hud.show(toast, symbol: symbol)
        }
        if let pulse = delivery.statusPulse, pulse != isPulsing {
            isPulsing = pulse
            onStatusPulse?(pulse)
        }
        switch delivery.chime {
        case .start: sounds.startChime(EventPolicy.chimeSound, interval: EventPolicy.chimeInterval)
        case .stop: sounds.stopChime()
        case .unchanged: break
        }
        // Confetti judges every event against the user's triggers
        // itself; the toy decides whether it is on and picks the
        // provider's colour from the same table the rest of the app uses.
        toys?.confetti.noteEvent(event)
        toys?.notchBuddy.noteEvent(event)
        // A quota reset brings the aquarium's submarine by.
        toys?.aquarium?.noteEvent(event)
        // The island turns the events that matter into its transient
        // capsules — its own policy and cooldown decide whether this one
        // shows.
        toys?.notch.noteEvent(event)
        // The `takeover` tier's finale: the ask grows out of the notch
        // and holds until it is acted on. A stage below it (or a
        // watched pane) shrinks a card already up back to its capsule.
        if event.kind == "escalation_stage" {
            if delivery.takeover {
                toys?.notch.noteTakeover(event)
            } else {
                toys?.notch.releaseTakeover()
            }
        }
    }

    /// The ask the event names is on screen: the user is already looking
    /// at it, so the escalation ladder's noise stays down. The app's own
    /// read is `answer_local`'s — the host app's bundle on the frontmost
    /// app, and when the session names a process the frontmost pid on
    /// that process's ancestry (`AskingPane`) — and the daemon's
    /// `session_in_front`, while it still speaks for this session and
    /// this frontmost app, overrules it either way (`AskingPane
    /// .watching`). A remote session has no pane here at all, so it can
    /// never quiet the ladder.
    private func askingPaneFrontmost(sessionID: String?) -> Bool {
        guard quietWhenPaneFrontmost(), let sessionID,
              let session = core.state?.session(withID: sessionID), !session.remote else { return false }
        let expected = Set([session.terminal?.bundleId, session.origin?.bundleId].compactMap { $0 })
        let front = frontmostApp()
        let local = AskingPane.isFrontmost(expectedBundleIDs: expected, sessionPID: session.pid,
                                           frontmostBundleID: front.bundleID, frontmostPID: front.pid)
        let verdict = inFrontVerdict.flatMap {
            $0.speaks(for: sessionID, frontmostPID: front.pid, now: Date()) ? $0.inFront : nil
        }
        return AskingPane.watching(local: local, inFront: verdict)
    }

    /// Ask the daemon whether the owner is watching the session an ask
    /// or a stage is about — the tab, not just the app — and, when its
    /// word differs from what this event was decided on, put it right:
    /// an ask whose sound the app rule kept down chimes after all (the
    /// owner is in another tab), a stage re-decides its pulse and chime.
    /// Only while "quiet while watching" is on, for a local session,
    /// once per session while a check is out.
    private func confirmWatching(_ event: CoreEvent, decidedWatching: Bool) {
        guard event.kind == "ask_opened" || event.kind == "escalation_stage",
              quietWhenPaneFrontmost(), let sessionID = event.session,
              let session = core.state?.session(withID: sessionID), !session.remote,
              inFrontAsking != sessionID else { return }
        let front = frontmostApp().pid
        if let verdict = inFrontVerdict, verdict.speaks(for: sessionID, frontmostPID: front, now: Date()) { return }
        inFrontAsking = sessionID
        Task { [weak self] in
            guard let self else { return }
            let inFront = await self.sessionInFront(sessionID)
            self.inFrontAsking = nil
            self.inFrontVerdict = AskingPane.Verdict(session: sessionID, inFront: inFront,
                                                     frontmostPID: front, at: Date())
            let watching = self.askingPaneFrontmost(sessionID: sessionID)
            guard watching != decidedWatching else { return }
            if event.kind == "ask_opened", decidedWatching, !watching {
                // The app rule quieted the ask's sound; the daemon says
                // the owner is in another tab — it sounds after all.
                let settings = self.core.settings.map { SettingsDocument($0.document) }
                let delivery = self.deliveryRules(
                    EventPolicy.delivery(for: event, state: self.core.state, settings: settings,
                                         askingFrontmost: false), event)
                if let sound = delivery.sound { self.sounds.play(sound, repeats: delivery.soundRepeats) }
            } else if event.kind == "escalation_stage" {
                self.reapplyEscalationNoise()
            }
        }
    }

    /// The frontmost app changed: if the asking pane just came forward
    /// the escalation's noise goes quiet now — and walking away from a
    /// stage that had been suppressed lets it speak up without waiting
    /// for the next boundary. Only the pulse and the chime re-decide;
    /// sounds and banners already fired are gone either way.
    private func reapplyEscalationNoise() {
        guard let event = lastEscalation, asksStillOpen else { return }
        // A new app in front: the daemon's word is asked afresh, and
        // until it answers the app's own rule decides.
        confirmWatching(event, decidedWatching: askingPaneFrontmost(sessionID: event.session))
        let settings = core.settings.map { SettingsDocument($0.document) }
        let delivery = deliveryRules(EventPolicy.delivery(for: event, state: core.state, settings: settings,
                                                          askingFrontmost: askingPaneFrontmost(sessionID: event.session)), event)
        if let pulse = delivery.statusPulse, pulse != isPulsing {
            isPulsing = pulse
            onStatusPulse?(pulse)
        }
        switch delivery.chime {
        case .start: sounds.startChime(EventPolicy.chimeSound, interval: EventPolicy.chimeInterval)
        case .stop: sounds.stopChime()
        case .unchanged: break
        }
        // The pane coming forward is the person looking at the ask: the
        // takeover card shrinks back to its capsule. Walking away again
        // does not re-grow it — that waits for the next stage.
        if !delivery.takeover { toys?.notch.releaseTakeover() }
    }

    private var asksStillOpen: Bool {
        (core.state?.asks.isEmpty == false) || (core.state?.mainSessions.contains { $0.ask != nil } ?? false)
    }

    /// The daemon went away: nothing is escalating any more, and a
    /// takeover card's Approve would answer a daemon that is gone.
    func reset() {
        lastEscalation = nil
        inFrontVerdict = nil
        sounds.stopChime()
        toys?.notch.releaseTakeover()
        if isPulsing {
            isPulsing = false
            onStatusPulse?(false)
        }
    }
}
