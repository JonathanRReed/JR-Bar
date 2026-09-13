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

    init(core: CoreModel, hudAnchor: @escaping @MainActor () -> NSRect?) {
        self.core = core
        hud = NotchHUD(anchorRect: hudAnchor)
        sounds.onMissing = { [weak core] name in core?.appendLocalLog(level: "warn", "no system sound named \(name)") }
        notifications.onLog = { [weak core] line in core?.appendLocalLog(line) }
        notifications.onOpenSession = { [weak core] session in core?.openSession(session) }
        notifications.onAnswerAsk = { [weak core] session, approve in core?.answerAsk(session: session, approve: approve) }
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
                }
                self.trackState()
            }
        }
    }

    func handle(_ event: CoreEvent) {
        let settings = core.settings.map { SettingsDocument($0.document) }
        let delivery = EventPolicy.delivery(for: event, state: core.state, settings: settings)
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
    }

    /// The daemon went away: nothing is escalating any more.
    func reset() {
        sounds.stopChime()
        if isPulsing {
            isPulsing = false
            onStatusPulse?(false)
        }
    }
}
