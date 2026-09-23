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
    /// The last escalation_stage the daemon announced — remembered so a
    /// frontmost flip can re-decide the noise without waiting for the
    /// next stage boundary.
    private var lastEscalation: CoreEvent?

    init(core: CoreModel, hudAnchor: @escaping @MainActor () -> NSRect?) {
        self.core = core
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
        let delivery = deliveryRules(EventPolicy.delivery(for: event, state: core.state, settings: settings,
                                                          askingFrontmost: askingPaneFrontmost(sessionID: event.session)), event)
        if event.kind == "escalation_stage" { lastEscalation = event }
        apply(delivery, for: event)
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
    /// at it, so the escalation ladder's noise stays down. The proof is
    /// `answer_local`'s own — the host app's bundle on the frontmost app,
    /// and when the session names a process the frontmost pid on that
    /// process's ancestry (`AskingPane`). A remote session has no pane
    /// here at all, so it can never quiet the ladder.
    private func askingPaneFrontmost(sessionID: String?) -> Bool {
        guard quietWhenPaneFrontmost(), let sessionID,
              let session = core.state?.session(withID: sessionID), !session.remote else { return false }
        let expected = Set([session.terminal?.bundleId, session.origin?.bundleId].compactMap { $0 })
        let front = frontmostApp()
        return AskingPane.isFrontmost(expectedBundleIDs: expected, sessionPID: session.pid,
                                      frontmostBundleID: front.bundleID, frontmostPID: front.pid)
    }

    /// The frontmost app changed: if the asking pane just came forward
    /// the escalation's noise goes quiet now — and walking away from a
    /// stage that had been suppressed lets it speak up without waiting
    /// for the next boundary. Only the pulse and the chime re-decide;
    /// sounds and banners already fired are gone either way.
    private func reapplyEscalationNoise() {
        guard let event = lastEscalation, asksStillOpen else { return }
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

    /// The daemon went away: nothing is escalating any more.
    func reset() {
        lastEscalation = nil
        sounds.stopChime()
        if isPulsing {
            isPulsing = false
            onStatusPulse?(false)
        }
    }
}
