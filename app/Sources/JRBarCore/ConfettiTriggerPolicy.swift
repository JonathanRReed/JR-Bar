import Foundation

/// Why a burst fired — the trigger row that matched. For the log line
/// and the tests.
public enum ConfettiFireReason: String, Equatable, Sendable {
    /// `quota_reset` on a weekly lane (`weekly`, `*-weekly`).
    case weeklyReset
    /// `quota_reset` for a provider the user picked, any lane.
    case providerReset
    /// A `completed` event: an agent finished a run.
    case sessionCompleted
    /// The last open ask went away — nothing left waiting on the user.
    case allClear
    /// Codex's banked-credit balance grew between state documents.
    case codexBanked
    /// The daemon's Milestone Odometer crossed a step (a `milestone`
    /// event) -- the lights' cue and the burst read one completion count.
    case milestone
}

/// A firing decision: the reason, the dedup key `firedKeys` records so
/// the same fact can never burst twice, and the provider whose colours
/// the burst wears when the fact names one.
public struct ConfettiFire: Equatable, Sendable {
    public var reason: ConfettiFireReason
    /// The dedup identity, persisted in `ConfettiSettings.firedKeys`.
    public var key: String
    public var provider: String?

    public init(reason: ConfettiFireReason, key: String, provider: String? = nil) {
        self.reason = reason
        self.key = key
        self.provider = provider
    }
}

/// The confetti trigger table, pure so it is tested without the overlay.
/// `eventFire` judges one daemon event; `ConfettiEdgeTracker` diffs the
/// state documents for the edges no event carries.
public enum ConfettiTriggerPolicy {
    /// The weekly lanes: the bare `weekly` id and provider-scoped ids
    /// ending `-weekly` (Antigravity's `claude-gpt-weekly`, a Codex
    /// product window like `spark-weekly`).
    public static func isWeeklyLane(_ lane: String) -> Bool {
        lane == "weekly" || lane.hasSuffix("-weekly")
    }

    /// Does this event earn a burst under these triggers? nil for a kind
    /// the user did not switch on, a `quota_reset` with no lane, and an
    /// event id the dedup ring already holds. The key prefers the frame's
    /// `cursor` (`<stream>:<id>`) over the bare id: the daemon numbers
    /// events per run, so after a restart a new `ev-N` would collide with
    /// a cached key and a real reset would be swallowed.
    public static func eventFire(_ event: CoreEvent, settings: ConfettiSettings) -> ConfettiFire? {
        let key = "event:\(event.cursor ?? event.id)"
        guard !settings.firedKeys.contains(key) else { return nil }
        switch event.kind {
        case "quota_reset":
            guard let lane = event.lane else { return nil }
            if settings.triggers.weeklyReset, isWeeklyLane(lane) {
                return ConfettiFire(reason: .weeklyReset, key: key, provider: event.provider)
            }
            if let provider = event.provider,
               settings.triggers.perProviderReset.contains(provider.lowercased()) {
                return ConfettiFire(reason: .providerReset, key: key, provider: provider)
            }
            return nil
        case "completed":
            guard settings.triggers.sessionCompleted else { return nil }
            return ConfettiFire(reason: .sessionCompleted, key: key, provider: event.provider)
        case CoreEvent.milestoneKind:
            // The odometer's step, under the same Milestones switch as the
            // Aquarium's achievements: rare on purpose, never every run.
            guard settings.triggers.milestones else { return nil }
            return ConfettiFire(reason: .milestone, key: key, provider: event.provider)
        default:
            return nil
        }
    }
}

/// The state edges: facts that arrive as a changed document rather than
/// an event. The tracker remembers the last comparison, so each edge
/// fires on its transition only; the first document after launch or a
/// reconnect just seeds it — an app restart can never re-fire a fact
/// that predates it.
///
/// Facts are remembered whether or not their trigger is on: a baseline
/// that went stale while the toggle was off would fire on the next state
/// after enabling for a rise that happened weeks ago.
public struct ConfettiEdgeTracker: Equatable, Sendable {
    /// The last banked-credit balance per usage row (`provider.identity`,
    /// so a second account of one provider is its own row).
    public private(set) var credits: [String: Double] = [:]
    /// Whether the last state had anything waiting on the user. nil
    /// until the first document seeds it.
    public private(set) var hadOpenAsks: Bool?

    public init() {}

    /// "Something is waiting": the asks list, plus any main session
    /// carrying an ask the list lacks — the set `EventPolicy` counts.
    public static func hasOpenAsks(_ state: CoreState) -> Bool {
        !state.asks.isEmpty || state.mainSessions.contains { $0.ask != nil }
    }

    /// Fold one applied state in; the fires its transitions earn under
    /// these triggers, in a stable order. The keys carry the state's
    /// generation, so folding the same document twice fires nothing.
    public mutating func note(_ state: CoreState, triggers: ConfettiTriggers) -> [ConfettiFire] {
        var fires: [ConfettiFire] = []
        for provider in state.usage?.providers ?? [] {
            guard let balance = provider.creditsRemaining else { continue }
            let before = credits[provider.identity]
            credits[provider.identity] = balance
            if triggers.codexBankedReset, provider.id == "codex",
               let before, balance > before {
                fires.append(ConfettiFire(reason: .codexBanked,
                                          key: "state:\(state.generation):credits:\(provider.identity)",
                                          provider: provider.id))
            }
        }
        let openAsks = Self.hasOpenAsks(state)
        if triggers.allClear, hadOpenAsks == true, !openAsks {
            fires.append(ConfettiFire(reason: .allClear,
                                      key: "state:\(state.generation):all-clear"))
        }
        hadOpenAsks = openAsks
        return fires
    }
}
