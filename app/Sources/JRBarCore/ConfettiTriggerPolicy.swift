import Foundation

/// Why a burst fired — the trigger row that matched. For the log line
/// and the tests.
public enum ConfettiFireReason: String, Equatable, Sendable {
    /// A confirmed `quota_reset` on any provider lane.
    case quotaReset
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
    /// The daemon's stable fact id when the event carries one (a
    /// `quota_reset`'s `event_id`): what the toy's `reset_receipt` names.
    public var eventID: String?

    public init(reason: ConfettiFireReason, key: String, provider: String? = nil,
                eventID: String? = nil) {
        self.reason = reason
        self.key = key
        self.provider = provider
        self.eventID = eventID
    }
}

/// Why a trigger-relevant event did not earn a burst. Every value is a
/// reason worth a log line — a swallowed reset is the bug this exists
/// to make visible — and a word the daemon's `reset_receipt` can store.
public enum ConfettiTriggerDrop: String, Equatable, Sendable {
    /// The fact is older than `eventFreshnessWindow`: genuinely old news
    /// — a restart must never re-fire it.
    case stale
    /// `firedKeys` already holds the key: the celebration happened (or
    /// was honestly accounted for) — never twice.
    case alreadyFired = "already_celebrated"
    /// A `quota_reset` without its `lane`: cannot be judged.
    case missingLane = "no_lane"
    case missingProvider = "no_provider"
    /// The trigger row that would cover this event is off.
    case triggerOff = "trigger_off"

    /// The app's own words for the log line.
    public var text: String {
        switch self {
        case .stale: return "too old to celebrate"
        case .alreadyFired: return "already celebrated"
        case .missingLane: return "the event names no lane"
        case .missingProvider: return "the event names no provider"
        case .triggerOff: return "its trigger is off"
        }
    }
}

/// What one daemon event means to the burst.
public enum ConfettiTriggerVerdict: Equatable, Sendable {
    /// Not a kind the trigger table knows — nothing to record.
    case unrelated
    /// It earns a burst.
    case fire(ConfettiFire)
    /// It was a trigger kind and it did not fire, with why.
    case dropped(ConfettiTriggerDrop)
}

/// What the toy tells the daemon about a `quota_reset` it was sent
/// (`reset_receipt`, docs/CORE-PROTOCOL.md): the record that makes a
/// celebration that never landed visible in `provider-reset-events.json`.
public struct ConfettiResetReceipt: Equatable, Sendable {
    /// The daemon's words. `delivered` and `dropped` close the daemon's
    /// replay offer for good; the rest leave the reset re-offerable.
    public enum Outcome: String, Equatable, Sendable {
        /// The burst was put on screen.
        case delivered
        /// The room is hushed (a call, a Focus, quiet, a fullscreen app):
        /// kept for later.
        case held
        /// Given up on, for good: a trigger or the toy is off, the room's
        /// hold was set to let go, or the fact was already celebrated.
        case dropped
        /// Kept too long and let go; a later connection may offer it again.
        case expired
    }

    public var eventID: String
    public var outcome: Outcome
    /// One snake_case word for why.
    public var reason: String

    public init(eventID: String, outcome: Outcome, reason: String) {
        self.eventID = eventID
        self.outcome = outcome
        self.reason = reason
    }

    /// The `reset_receipt` command's arguments.
    public var args: [String: JSONValue] {
        ["event_id": .string(eventID), "outcome": .string(outcome.rawValue),
         "reason": .string(reason)]
    }
}

/// The confetti trigger table, pure so it is tested without the overlay.
/// `eventFire` judges one daemon event; `ConfettiEdgeTracker` diffs the
/// state documents for the edges no event carries.
public enum ConfettiTriggerPolicy {
    /// How old a `quota_reset` can be and still earn a burst — the daemon's
    /// own replay bound (`RESET_APP_FRESHNESS_SECONDS`). A reset the daemon
    /// confirms late is stamped when it is confirmed, so it is fresh news;
    /// one older than this is history, and a restart never re-fires it.
    public static let eventFreshnessWindow: TimeInterval = 24 * 60 * 60

    /// The dedup key for an event. A `quota_reset` carries the daemon's
    /// stable `event_id`, which survives a daemon restart; the journal's
    /// `cursor` (`<stream>:<id>`) does not outlive its stream, so it keys
    /// every other kind — the daemon numbers events per run, and after a
    /// restart a bare `ev-N` would collide with a cached key and swallow a
    /// real fact.
    public static func eventKey(_ event: CoreEvent) -> String {
        if event.kind == "quota_reset", let eventID = event.eventId, !eventID.isEmpty {
            return "event:\(eventID)"
        }
        return "event:\(event.cursor ?? event.id)"
    }

    /// What this event means to the burst, and when it is not a burst, why
    /// not. `now` is the app's clock; an event with no `at`, or one stamped
    /// in the future, is treated as fresh.
    public static func eventVerdict(_ event: CoreEvent, settings: ConfettiSettings,
                                    now: Date = Date()) -> ConfettiTriggerVerdict {
        let key = eventKey(event)
        switch event.kind {
        case "quota_reset":
            guard let lane = event.lane, !lane.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .dropped(.missingLane)
            }
            guard let provider = event.provider, !provider.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .dropped(.missingProvider)
            }
            if let at = event.at, now.timeIntervalSince1970 - at >= eventFreshnessWindow {
                return .dropped(.stale)
            }
            if let id = event.eventId, settings.hasSettledReset(id, at: now.timeIntervalSince1970) {
                return .dropped(.alreadyFired)
            }
            guard !settings.firedKeys.contains(key) else { return .dropped(.alreadyFired) }
            if settings.triggers.quotaReset {
                return .fire(ConfettiFire(reason: .quotaReset, key: key, provider: provider,
                                          eventID: event.eventId))
            }
            if settings.triggers.perProviderReset.contains(provider.lowercased()) {
                return .fire(ConfettiFire(reason: .providerReset, key: key, provider: provider,
                                          eventID: event.eventId))
            }
            return .dropped(.triggerOff)
        case "completed":
            guard !settings.firedKeys.contains(key) else { return .dropped(.alreadyFired) }
            guard settings.triggers.sessionCompleted else { return .dropped(.triggerOff) }
            return .fire(ConfettiFire(reason: .sessionCompleted, key: key, provider: event.provider))
        case CoreEvent.milestoneKind:
            // The odometer's step, under the same Milestones switch as the
            // Aquarium's achievements: rare on purpose, never every run.
            guard !settings.firedKeys.contains(key) else { return .dropped(.alreadyFired) }
            guard settings.triggers.milestones else { return .dropped(.triggerOff) }
            return .fire(ConfettiFire(reason: .milestone, key: key, provider: event.provider))
        default:
            return .unrelated
        }
    }

    /// Does this event earn a burst under these triggers? nil for a kind
    /// the user did not switch on, a `quota_reset` with no lane or too old,
    /// and a fact the dedup ring already holds. `eventVerdict` says why.
    public static func eventFire(_ event: CoreEvent, settings: ConfettiSettings,
                                 now: Date = Date()) -> ConfettiFire? {
        if case .fire(let fire) = eventVerdict(event, settings: settings, now: now) { return fire }
        return nil
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
    /// Which daemon connection the documents come from. The daemon numbers
    /// generations per run, so after a restart `generation 7` is a new fact
    /// that would collide with an old `generation 7` key; a non-empty
    /// session keeps them apart. Empty keeps the plain key.
    public private(set) var session: String

    public init(session: String = "") {
        self.session = session
    }

    /// The daemon went away. What comes back is a new run: forget the last
    /// document so the next one only seeds, and key its facts apart from
    /// the old run's. A rise or an all-clear that happened across the gap is
    /// not news the toy can vouch for.
    public mutating func reseed(session: String) {
        credits = [:]
        hadOpenAsks = nil
        self.session = session
    }

    private func stateKey(_ generation: some CustomStringConvertible, _ rest: String) -> String {
        session.isEmpty ? "state:\(generation):\(rest)" : "state:\(session):\(generation):\(rest)"
    }

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
                                          key: stateKey(state.generation, "credits:\(provider.identity)"),
                                          provider: provider.id))
            }
        }
        let openAsks = Self.hasOpenAsks(state)
        if triggers.allClear, hadOpenAsks == true, !openAsks {
            fires.append(ConfettiFire(reason: .allClear,
                                      key: stateKey(state.generation, "all-clear")))
        }
        hadOpenAsks = openAsks
        return fires
    }
}
