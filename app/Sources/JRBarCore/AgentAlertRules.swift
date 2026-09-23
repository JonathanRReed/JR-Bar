import Foundation

/// How loud one provider's agents may be — the Agent Overview card's own
/// job. The panel, the Overview and the card all list sessions; only the
/// card says "Codex can be loud, Grok quiet": asks, completions, failures
/// and sounds per provider, and how far its escalation may climb, in one
/// table instead of global switches scattered across Settings.
///
/// Every field that is nil follows the global setting, so an untouched
/// provider behaves exactly as before; a rule only ever narrows or widens
/// what the global policy already decided for that provider's events.
public struct AgentAlertRule: Codable, Equatable, Hashable, Sendable {
    /// Ask banners, the ask sound burst and the escalation's pulse and
    /// chime. Off keeps the ask on every surface (the panel card, the
    /// light) but never interrupts.
    public var asks: Bool
    /// Completion banners: nil follows `completion_notification_enabled`,
    /// true always banners this provider's finishes, false never does.
    public var completions: Bool?
    /// Failure banners and the failure sound.
    public var failures: Bool
    /// Every sound this provider's events would make, the escalation's
    /// repeating chime included; banners stay.
    public var sounds: Bool
    /// The highest escalation stage this provider's asks may reach
    /// (1 the light, 2 menu-bar pulse, 3 chime); nil follows
    /// `escalation_tier`. A rule can only lower the global ceiling. There
    /// is no stage 0: the light's ramp is the daemon's, and rules apply in
    /// the app, so "nothing" would have promised a quiet light it cannot
    /// keep.
    public var escalationCeiling: Int?

    public init(asks: Bool = true, completions: Bool? = nil, failures: Bool = true,
                sounds: Bool = true, escalationCeiling: Int? = nil) {
        self.asks = asks
        self.completions = completions
        self.failures = failures
        self.sounds = sounds
        self.escalationCeiling = escalationCeiling.map(Self.clampCeiling)
    }

    /// The rule nobody changed: every field follows the global policy.
    public static let followGlobal = AgentAlertRule()
    public var isDefault: Bool { self == .followGlobal }

    private enum CodingKeys: String, CodingKey { case asks, completions, failures, sounds, escalationCeiling }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        asks = (try? c.decodeIfPresent(Bool.self, forKey: .asks)) ?? true
        completions = (try? c.decodeIfPresent(Bool.self, forKey: .completions)) ?? nil
        failures = (try? c.decodeIfPresent(Bool.self, forKey: .failures)) ?? true
        sounds = (try? c.decodeIfPresent(Bool.self, forKey: .sounds)) ?? true
        escalationCeiling = ((try? c.decodeIfPresent(Int.self, forKey: .escalationCeiling)) ?? nil).map(Self.clampCeiling)
    }

    /// 1...3: a saved "nothing" (0) reads as the light it always was.
    static func clampCeiling(_ stage: Int) -> Int { min(3, max(1, stage)) }

    /// "Asks off · done always · no sounds · up to the pulse" — the row's
    /// summary when the table is folded; nil for a default rule.
    public var summary: String? {
        var parts: [String] = []
        if !asks { parts.append("asks silent") }
        if let completions { parts.append(completions ? "finishes banner" : "finishes silent") }
        if !failures { parts.append("failures silent") }
        if !sounds { parts.append("no sounds") }
        if let ceiling = escalationCeiling { parts.append("escalates to \(AgentAlertRules.stageWord(ceiling))") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

public enum AgentAlertRules {
    /// The kinds that end a run — what a "notify when done" watch waits for.
    public static let doneKinds: Set<String> = ["completed", "failed", "ended"]

    /// A session the user asked to hear about finished (or failed, or went
    /// away): make sure a banner says so, whatever the global completion
    /// switch or the provider's rule decided — the watch is the explicit
    /// ask. Other kinds pass through.
    public static func notifyWhenDone(_ delivery: EventDelivery, event: CoreEvent, state: CoreState?) -> EventDelivery {
        guard doneKinds.contains(event.kind), delivery.notification == nil else { return delivery }
        let session = event.session.flatMap { state?.session(withID: $0) }
        let name = provider(of: event, state: state).map(LightExplainer.providerName) ?? "An agent"
        let label = event.label.flatMap { $0.isEmpty ? nil : $0 } ?? session?.shortLabel ?? name
        let (title, body): (String, String) = switch event.kind {
        case "completed": ("\(label) finished", event.detail ?? "\(name) is done — you asked to hear. Click to open the session.")
        case "failed": ("\(label) failed", event.detail ?? "\(name) stopped with an error. Click to open the session.")
        default: ("\(label) ended", event.detail ?? "\(name) went away without confirming it finished.")
        }
        var out = delivery
        out.notification = .init(identifier: "\(event.kind):\(event.session ?? event.id)", title: title, body: body,
                                 session: event.session)
        return out
    }

    /// "none", "the light", "the pulse", "the chime".
    public static func stageWord(_ stage: Int) -> String {
        switch stage {
        case ...0: return "nothing"
        case 1: return "the light"
        case 2: return "the pulse"
        default: return "the chime"
        }
    }

    /// The provider an event is about: the event's own word, else its
    /// session's. An escalation step names neither — the ladder climbs for
    /// the ask that has waited longest, so that ask's provider owns it.
    public static func provider(of event: CoreEvent, state: CoreState?) -> String? {
        if let provider = event.provider ?? event.session.flatMap({ state?.session(withID: $0)?.provider }) {
            return provider
        }
        guard event.kind == "escalation_stage", let state else { return nil }
        let oldest = state.asks.min { ($0.openedAt ?? .greatestFiniteMagnitude) < ($1.openedAt ?? .greatestFiniteMagnitude) }
        return oldest?.session.flatMap { state.session(withID: $0)?.provider }
            ?? oldest?.session.flatMap { $0.split(separator: ":").first.map(String.init) }
    }

    /// `delivery` — what `EventPolicy` decided — narrowed or widened by the
    /// event's provider rule. Only the provider's own events change: a
    /// device toast or a quota banner (quota is the account's, not one
    /// agent's) passes through, and a provider with no rule is untouched.
    public static func apply(_ delivery: EventDelivery, to event: CoreEvent, state: CoreState?,
                             rules: [String: AgentAlertRule], currentStage: Int? = nil) -> EventDelivery {
        guard let provider = provider(of: event, state: state), let rule = rules[provider], !rule.isDefault else {
            return delivery
        }
        var out = delivery
        switch event.kind {
        case "ask_opened":
            if !rule.asks {
                out.sound = nil
                out.notification = nil
            }
        case "completed":
            if rule.completions == false { out.notification = nil }
            if rule.completions == true, out.notification == nil, event.notify ?? true {
                let session = event.session.flatMap { state?.session(withID: $0) }
                let name = LightExplainer.providerName(provider)
                let label = event.label.flatMap { $0.isEmpty ? nil : $0 } ?? session?.shortLabel ?? name
                out.notification = .init(identifier: "completed:\(event.session ?? event.id)", title: "\(label) finished",
                                         body: event.detail ?? "\(name) is done. Click to open the session.",
                                         session: event.session)
            }
        case "failed":
            if !rule.failures {
                out.sound = nil
                out.notification = nil
            }
        case "escalation_stage":
            if let ceiling = rule.escalationCeiling {
                let stage = min(event.stage ?? currentStage ?? 0, ceiling)
                if stage < 2 { out.statusPulse = false }
                if stage < 3 { out.chime = .stop }
            }
            // The stage-3 chime is the loudest sound JR-Bar makes; a rule
            // that silences this provider's sounds or asks silences it too,
            // and a provider whose asks never interrupt never pulses.
            if !rule.sounds || !rule.asks { out.chime = .stop }
            if !rule.asks { out.statusPulse = false }
        default:
            return delivery
        }
        if !rule.sounds { out.sound = nil }
        return out
    }
}
