import Foundation

/// What the Mac should do about one daemon event: the sound, a
/// notification, a HUD toast, and the escalation side effects. The daemon
/// decides *whether* something happened; this table decides how it lands
/// given the settings document and the focus mode. Pure, so it is tested
/// without AppKit.
public struct EventDelivery: Equatable, Sendable {
    public struct Notification: Equatable, Sendable {
        public enum Category: String, Sendable {
            /// A plain banner; clicking it opens the session.
            case plain
            /// Carries Approve / Deny actions that answer the ask.
            case ask
        }

        public var identifier: String
        public var title: String
        public var body: String
        public var category: Category
        public var session: String?

        public init(identifier: String, title: String, body: String, category: Category = .plain, session: String? = nil) {
            self.identifier = identifier
            self.title = title
            self.body = body
            self.category = category
            self.session = session
        }
    }

    public enum Chime: Equatable, Sendable {
        case unchanged
        /// Start the repeating stage-3 chime (every `interval` seconds).
        case start
        case stop
    }

    /// A system sound name (`Glass`, `Funk`, `Basso`, ...), nil for silence.
    public var sound: String?
    /// How many times `sound` plays back to back (`alert_burst` for asks).
    public var soundRepeats: Int = 1
    public var notification: Notification?
    /// A short HUD line near the notch.
    public var toast: String?
    /// The identifier of a delivered notification to withdraw (an ask that resolved).
    public var withdrawNotification: String?
    /// nil leaves the status item alone; true / false start or stop the amber pulse.
    public var statusPulse: Bool?
    public var chime: Chime = .unchanged

    public init(sound: String? = nil, soundRepeats: Int = 1, notification: Notification? = nil, toast: String? = nil,
                withdrawNotification: String? = nil, statusPulse: Bool? = nil, chime: Chime = .unchanged) {
        self.sound = sound
        self.soundRepeats = soundRepeats
        self.notification = notification
        self.toast = toast
        self.withdrawNotification = withdrawNotification
        self.statusPulse = statusPulse
        self.chime = chime
    }

    public static let nothing = EventDelivery()

    public var isSilent: Bool { sound == nil && notification == nil && toast == nil && statusPulse == nil && chime == .unchanged && withdrawNotification == nil }
}

public enum EventPolicy {
    /// Seconds between stage-3 chimes.
    public static let chimeInterval: TimeInterval = 30
    /// `clear_completed` may be undone for this long.
    public static let undoWindow: TimeInterval = 300

    public static let completionSound = "Glass"
    public static let askSound = "Funk"
    public static let failureSound = "Basso"
    public static let quotaSound = "Pop"
    public static let chimeSound = "Hero"

    /// The system sounds we will play by name; anything else falls back to
    /// the kind's own default so a typo in the daemon never silences an ask.
    public static let knownSounds: Set<String> = ["basso", "blow", "bottle", "frog", "funk", "glass", "hero", "morse", "ping", "pop", "purr", "sosumi", "submarine", "tink"]

    public static func delivery(for event: CoreEvent, state: CoreState?, settings: SettingsDocument?) -> EventDelivery {
        let focus = (state?.focus?.mode ?? "normal").lowercased()
        let soundsSuppressed = ["dim", "dark", "pause"].contains(focus)
        let chimeSuppressed = focus == "pause"
        let notify = event.notify ?? true
        let tierCeiling = escalationCeiling(settings?.string("escalation_tier"))
        let session = event.session.flatMap { state?.session(withID: $0) }
        let provider = event.provider ?? session?.provider
        let providerName = provider.map(LightExplainer.providerName) ?? "An agent"
        let label = event.label.flatMap { $0.isEmpty ? nil : $0 } ?? session?.shortLabel ?? providerName

        func sound(_ fallback: String) -> String? {
            guard notify, !soundsSuppressed else { return nil }
            if let named = event.sound?.lowercased(), knownSounds.contains(named) { return named.prefix(1).uppercased() + named.dropFirst() }
            return fallback
        }

        switch event.kind {
        case "completed":
            let wanted = settings?.bool("completion_notification_enabled") ?? true
            var delivery = EventDelivery(sound: sound(completionSound))
            if notify, wanted {
                delivery.notification = .init(identifier: "completed:\(event.session ?? event.id)", title: "\(label) finished",
                                              body: event.detail ?? "\(providerName) is done. Click to open the session.",
                                              session: event.session)
            }
            return delivery

        case "ask_opened":
            if session?.isSubagent == true, settings?.bool("subagent_asks_alert") == false { return .nothing }
            guard notify else { return .nothing }
            let burst = max(1, min(5, settings?.int("alert_burst") ?? 1))
            var delivery = EventDelivery(sound: sound(askSound), soundRepeats: burst)
            delivery.notification = .init(identifier: "ask:\(event.session ?? event.id)", title: "\(label) needs you",
                                          body: event.detail ?? session?.ask?.summary ?? "\(providerName) is waiting for an answer.",
                                          category: .ask, session: event.session)
            return delivery

        case "ask_resolved":
            var delivery = EventDelivery(withdrawNotification: "ask:\(event.session ?? event.id)")
            // The ask that was escalating is gone: stop shouting unless
            // another one is still open.
            let stillOpen = (state?.asks.isEmpty == false) || (state?.mainSessions.contains { $0.ask != nil } ?? false)
            if !stillOpen {
                delivery.statusPulse = false
                delivery.chime = .stop
            }
            return delivery

        case "failed":
            guard notify else { return .nothing }
            var delivery = EventDelivery(sound: sound(failureSound))
            delivery.notification = .init(identifier: "failed:\(event.session ?? event.id)", title: "\(label) failed",
                                          body: event.detail ?? "\(providerName) stopped with an error. Click to open the session.",
                                          session: event.session)
            return delivery

        case "quota_crossed":
            guard notify, settings?.bool("quota_alerts_enabled") ?? true else { return .nothing }
            var delivery = EventDelivery(sound: sound(quotaSound))
            delivery.notification = .init(identifier: "quota:\(provider ?? event.id)", title: "\(providerName) usage \(event.detail ?? "threshold crossed")",
                                          body: event.label ?? "The window is nearly spent; expect throttling.", session: nil)
            return delivery

        case "quota_reset":
            guard notify, settings?.bool("quota_alerts_enabled") ?? true else { return .nothing }
            return EventDelivery(notification: .init(identifier: "quota:\(provider ?? event.id)", title: "\(providerName) quota reset",
                                                     body: event.detail ?? "A fresh window. Off you go.", session: nil))

        case "escalation_stage":
            let stage = min(event.stage ?? state?.escalation?.stageNumber ?? 0, tierCeiling)
            var delivery = EventDelivery()
            delivery.statusPulse = stage >= 2
            if stage >= 3 {
                delivery.chime = (chimeSuppressed || soundsSuppressed) ? .stop : .start
            } else {
                delivery.chime = .stop
            }
            return delivery

        case "device_connected":
            return EventDelivery(toast: "\(event.label ?? event.detail ?? "Device") connected")
        case "device_disconnected":
            return EventDelivery(toast: "\(event.label ?? event.detail ?? "Device") disconnected")
        case "deck_receipt":
            // A keymap or device receipt. The Control Center shows every
            // one; the HUD only carries the ones that mean the pad cannot
            // be written (a conflict, an interrupted transfer, a change of
            // connection), as a quiet toast.
            guard let receipt = event.receipt, receipt.isProblem else { return .nothing }
            return EventDelivery(toast: receipt.code == "device_conflict" ? DeckDevice.conflictText : receipt.text)
        case "peer_arrived":
            return EventDelivery(toast: "\(event.label ?? "A peer") joined")
        case "peer_departed":
            return EventDelivery(toast: "\(event.label ?? "A peer") left")
        default:
            return .nothing
        }
    }

    /// The highest stage the user allows (`escalation_tier`): light 1,
    /// menu_bar 2, chime / takeover 3. Missing reads as menu_bar, the
    /// Python default.
    public static func escalationCeiling(_ tier: String?) -> Int {
        switch tier?.lowercased() {
        case "off", "none": return 0
        case "light", "ramp": return 1
        case "menu_bar", "menubar": return 2
        case "chime", "final", "takeover", "all": return 3
        default: return 2
        }
    }
}
