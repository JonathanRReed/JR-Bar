import Foundation

// Codable models for protocol 1 (docs/CORE-PROTOCOL.md). Every field the
// document shows is here; everything is optional unless the protocol makes
// it load-bearing, and unknown keys are ignored by construction (Codable
// synthesised decoders never reject extra members). Timestamps are Unix
// epoch seconds, as on the wire.

public enum CoreProtocol {
    public static let version = 1
    /// The newest `settings.schema` this build's controls were written
    /// against; a daemon above it gets a banner in the Settings window
    /// rather than silent blind writes.
    public static let knownSettingsSchema = 3
}

/// Decodes a structured row tolerantly: one malformed row drops out of the
/// list instead of failing the whole document. The daemon's schema moves
/// faster than a pinned decoder, and a version-skew row must not blank the
/// panel — or take the strip's program with it.
private func tolerantRows<T: Decodable>(_ type: T.Type, _ raw: [JSONValue]?) -> [T] {
    (raw ?? []).compactMap { try? ReplyDecoding.decode(T.self, from: $0) }
}

// MARK: - hello

public struct CoreHello: Codable, Hashable, Sendable {
    public var coreVersion: String?
    public var pid: Int?
    public var capabilities: [String]
    /// The daemon incarnation's event stream and its journal's tail
    /// cursor. A reconnect that sees the SAME stream can ask
    /// `replay_events` for the frames the drop ate; a different stream
    /// is a restarted journal — anchor, never replay.
    public var stream: String?
    public var cursor: String?

    public init(coreVersion: String? = nil, pid: Int? = nil, capabilities: [String] = [],
                stream: String? = nil, cursor: String? = nil) {
        self.coreVersion = coreVersion
        self.pid = pid
        self.capabilities = capabilities
        self.stream = stream
        self.cursor = cursor
    }

    enum CodingKeys: String, CodingKey {
        case coreVersion = "core_version"
        case pid
        case capabilities
        case stream
        case cursor
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        coreVersion = try c.decodeIfPresent(String.self, forKey: .coreVersion)
        pid = try c.decodeIfPresent(Int.self, forKey: .pid)
        capabilities = try c.decodeIfPresent([String].self, forKey: .capabilities) ?? []
        stream = try c.decodeIfPresent(String.self, forKey: .stream)
        cursor = try c.decodeIfPresent(String.self, forKey: .cursor)
    }
}

// MARK: - state

public struct CoreAggregate: Codable, Hashable, Sendable {
    public var mode: String
    public var needsYou: Int
    public var active: Int
    public var ready: Int
    /// Sessions in a failed/blocked state — the daemon has always sent it;
    /// the header just never decoded it.
    public var failed: Int

    public init(mode: String = "idle", needsYou: Int = 0, active: Int = 0, ready: Int = 0, failed: Int = 0) {
        self.mode = mode
        self.needsYou = needsYou
        self.active = active
        self.ready = ready
        self.failed = failed
    }

    enum CodingKeys: String, CodingKey {
        case mode
        case needsYou = "needs_you"
        case active
        case ready
        case failed
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? "idle"
        needsYou = try c.decodeIfPresent(Int.self, forKey: .needsYou) ?? 0
        active = try c.decodeIfPresent(Int.self, forKey: .active) ?? 0
        ready = try c.decodeIfPresent(Int.self, forKey: .ready) ?? 0
        failed = try c.decodeIfPresent(Int.self, forKey: .failed) ?? 0
    }
}

public struct CoreOrigin: Codable, Hashable, Sendable {
    public var kind: String?
    public var label: String?
    public var bundleId: String?

    enum CodingKeys: String, CodingKey {
        case kind, label
        case bundleId = "bundle_id"
    }
}

public struct CoreTerminal: Codable, Hashable, Sendable {
    public var app: String?
    public var bundleId: String?
    /// Decoded for forward headroom; nothing displays the tty — the row's
    /// "Open in …" action names `app` only.
    public var tty: String?

    enum CodingKeys: String, CodingKey {
        case app, tty
        case bundleId = "bundle_id"
    }
}

/// A pending question, either pinned in `state.asks` (with `session`) or
/// embedded in the session it belongs to (without).
public struct CoreAsk: Codable, Hashable, Sendable, Identifiable {
    public var session: String?
    public var kind: String?
    public var openedAt: Double?
    public var summary: String?
    /// The daemon's verdict on whether the answer chain can type a reply
    /// into this session (provider capability + a live target). nil on
    /// older daemons — treat as answerable to preserve old behaviour.
    public var answerable: Bool?
    /// Whether this ask accepts free text (a reply field instead of
    /// Approve/Deny).
    public var replyable: Bool?

    public var id: String { (session ?? "") + "|" + (summary ?? "") + "|" + String(openedAt ?? 0) }

    /// What the buttons may claim: assume yes when the daemon is too old
    /// to say, so nothing regresses against pre-0.8.2 cores.
    public var canAnswer: Bool { answerable ?? true }
    public var wantsTextReply: Bool { replyable ?? false }

    public init(session: String? = nil, kind: String? = nil, openedAt: Double? = nil, summary: String? = nil,
                answerable: Bool? = nil, replyable: Bool? = nil) {
        self.session = session
        self.kind = kind
        self.openedAt = openedAt
        self.summary = summary
        self.answerable = answerable
        self.replyable = replyable
    }

    enum CodingKeys: String, CodingKey {
        case session, kind, summary, answerable, replyable
        case openedAt = "opened_at"
    }
}

public struct CoreSession: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var provider: String
    public var kind: String
    public var parent: String?
    public var label: String?
    /// The daemon's 8-character handle for the session (`short_id`), shown
    /// when the label is missing or is itself a UUID.
    public var shortId: String?
    public var cwd: String?
    /// Decoded for `SessionActivity.reduce` and the light explainer; the
    /// raw word is never displayed.
    public var mode: String?
    /// Decoded for `SessionActivity.reduce` and the light explainer; the
    /// raw word is never displayed.
    public var lifecycle: String?
    /// Decoded for `SessionActivity.reduce` (`user` counts as waiting);
    /// never displayed verbatim.
    public var nextActor: String?
    public var since: Double?
    /// Decoded for the light explainer's ordering and "… ago" phrasing;
    /// not itself displayed.
    public var updatedAt: Double?
    public var stale: Bool
    public var pid: Int?
    public var origin: CoreOrigin?
    public var ask: CoreAsk?
    public var terminal: CoreTerminal?
    public var workers: Int
    /// The family mailbox's active snooze (`snoozed_until`), when one
    /// covers this session.
    public var snoozedUntil: Double?
    /// The hook's last word for the session: the canonical event name
    /// (`PreToolUse`, `PostToolUse`, …), the tool it was about when one
    /// applied, and the message it carried. Facts, not state — a finished
    /// row's `event` is history rather than something happening now, and
    /// `message` can carry agent prose, so it needs bounding before it
    /// renders anywhere.
    public var event: String?
    public var tool: String?
    public var message: String?

    public init(id: String, provider: String, kind: String = "main", parent: String? = nil, label: String? = nil,
                shortId: String? = nil, cwd: String? = nil, mode: String? = nil, lifecycle: String? = nil, nextActor: String? = nil,
                since: Double? = nil, updatedAt: Double? = nil, stale: Bool = false, pid: Int? = nil,
                origin: CoreOrigin? = nil, ask: CoreAsk? = nil, terminal: CoreTerminal? = nil, workers: Int = 0,
                snoozedUntil: Double? = nil, event: String? = nil, tool: String? = nil, message: String? = nil) {
        self.id = id
        self.provider = provider
        self.kind = kind
        self.parent = parent
        self.label = label
        self.shortId = shortId
        self.cwd = cwd
        self.mode = mode
        self.lifecycle = lifecycle
        self.nextActor = nextActor
        self.since = since
        self.updatedAt = updatedAt
        self.stale = stale
        self.pid = pid
        self.origin = origin
        self.ask = ask
        self.terminal = terminal
        self.workers = workers
        self.snoozedUntil = snoozedUntil
        self.event = event
        self.tool = tool
        self.message = message
    }

    enum CodingKeys: String, CodingKey {
        case id, provider, kind, parent, label, cwd, mode, lifecycle, since, stale, pid, origin, ask, terminal, workers
        case event, tool, message
        case shortId = "short_id"
        case nextActor = "next_actor"
        case updatedAt = "updated_at"
        case snoozedUntil = "snoozed_until"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? "unknown"
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "main"
        parent = try c.decodeIfPresent(String.self, forKey: .parent)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        shortId = try c.decodeIfPresent(String.self, forKey: .shortId)
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
        mode = try c.decodeIfPresent(String.self, forKey: .mode)
        lifecycle = try c.decodeIfPresent(String.self, forKey: .lifecycle)
        nextActor = try c.decodeIfPresent(String.self, forKey: .nextActor)
        since = try c.decodeIfPresent(Double.self, forKey: .since)
        updatedAt = try c.decodeIfPresent(Double.self, forKey: .updatedAt)
        stale = try c.decodeIfPresent(Bool.self, forKey: .stale) ?? false
        pid = try c.decodeIfPresent(Int.self, forKey: .pid)
        origin = try c.decodeIfPresent(CoreOrigin.self, forKey: .origin)
        ask = try c.decodeIfPresent(CoreAsk.self, forKey: .ask)
        terminal = try c.decodeIfPresent(CoreTerminal.self, forKey: .terminal)
        workers = try c.decodeIfPresent(Int.self, forKey: .workers) ?? 0
        snoozedUntil = try c.decodeIfPresent(Double.self, forKey: .snoozedUntil)
        event = try c.decodeIfPresent(String.self, forKey: .event)
        tool = try c.decodeIfPresent(String.self, forKey: .tool)
        message = try c.decodeIfPresent(String.self, forKey: .message)
    }
}

public struct CoreDevice: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var kind: String
    public var name: String?
    public var path: String?
    public var leds: Int?
    public var connected: Bool?
    public var enabled: Bool?
    /// As sent: the Pro reports a percent (79), the lights document a
    /// fraction (0.79). `brightnessFraction` normalises.
    public var brightness: Double?
    public var linked: Bool?
    /// Decoded for forward headroom; nothing displays the device's last
    /// write time.
    public var lastWrite: Double?
    public var error: String?

    public init(id: String, kind: String, name: String? = nil, path: String? = nil, leds: Int? = nil,
                connected: Bool? = nil, enabled: Bool? = nil, brightness: Double? = nil, linked: Bool? = nil,
                lastWrite: Double? = nil, error: String? = nil) {
        self.id = id
        self.kind = kind
        self.name = name
        self.path = path
        self.leds = leds
        self.connected = connected
        self.enabled = enabled
        self.brightness = brightness
        self.linked = linked
        self.lastWrite = lastWrite
        self.error = error
    }

    public var brightnessFraction: Double? {
        guard let brightness else { return nil }
        return brightness > 1.0 ? min(1, brightness / 100.0) : max(0, brightness)
    }

    /// Screen Bar rows say `enabled`, hardware rows say `connected`.
    public var isPresent: Bool { connected ?? enabled ?? false }

    enum CodingKeys: String, CodingKey {
        case id, kind, name, path, leds, connected, enabled, brightness, linked, error
        case lastWrite = "last_write"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "unknown"
        name = try c.decodeIfPresent(String.self, forKey: .name)
        path = try c.decodeIfPresent(String.self, forKey: .path)
        leds = try c.decodeIfPresent(Int.self, forKey: .leds)
        connected = try c.decodeIfPresent(Bool.self, forKey: .connected)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled)
        brightness = try c.decodeIfPresent(Double.self, forKey: .brightness)
        linked = try c.decodeIfPresent(Bool.self, forKey: .linked)
        lastWrite = try c.decodeIfPresent(Double.self, forKey: .lastWrite)
        error = try c.decodeIfPresent(String.self, forKey: .error)
    }
}

/// One usage window of one provider.
///
/// A window the account does not have is **absent** — no entry at all. A
/// window that exists but whose provider stated no number is **unknown**:
/// it arrives with `used_pct: null`, and `usedPct` is nil. Reading that as
/// zero drew a full green bar and said "plenty left" about a window nobody
/// had measured, which is a confident lie; every consumer has to render it
/// as unknown (CORE-PROTOCOL, "Three states, never two").
public struct CoreUsageWindow: Codable, Hashable, Sendable, Identifiable {
    /// The daemon's window key (`five-hour`, `weekly`, `daily`, `credits`, …) when it sends one.
    public var key: String?
    public var name: String
    /// How much of the window is spent, 0…100 — nil when the provider
    /// stated no number. Never substitute a number for nil.
    public var usedPct: Double?
    public var resetsAt: Double?
    /// Per-window pace projection; the daemon emits it for every measured
    /// window, not only the primary one.
    public var forecast: CoreUsageForecast?

    public var id: String { key ?? name }

    /// The panel's short label for the window: `5h`, `7d`, `Daily`, `Monthly`, `Credits`.
    public var shortName: String { UsageWindowLabel.short(id: key, name: name) }

    /// The expanded label for captions and tooltips: `5-hour`, `7-day`, or
    /// the daemon's own name when it is already a word.
    public var longName: String { UsageWindowLabel.long(id: key, name: name) }

    /// The window exists and nobody said how full it is.
    public var isUnknown: Bool { usedPct == nil }

    /// The percent column: `42%`, or an em dash when there is no reading.
    /// Every surface uses the same two characters for "unknown".
    public var percentText: String { UsageWindowLabel.percent(usedPct) }

    /// What VoiceOver and the tooltips say: "42 percent used", or
    /// "no reading" — never "0 percent used".
    public var spokenPercent: String { UsageWindowLabel.spoken(usedPct) }

    public init(key: String? = nil, name: String, usedPct: Double?, resetsAt: Double? = nil, forecast: CoreUsageForecast? = nil) {
        self.key = key
        self.name = name
        self.usedPct = usedPct
        self.resetsAt = resetsAt
        self.forecast = forecast
    }

    enum CodingKeys: String, CodingKey {
        case name
        case key = "id"
        case usedPct = "used_pct"
        case resetsAt = "resets_at"
        case forecast
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decodeIfPresent(String.self, forKey: .key)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? key ?? "?"
        // `null` is the daemon saying "the window exists, nobody measured
        // it". A malformed value is no better a reading than a missing one,
        // and neither may become a number.
        let raw = (try? c.decodeIfPresent(Double.self, forKey: .usedPct)) ?? nil
        usedPct = raw.flatMap { $0.isFinite ? $0 : nil }
        resetsAt = try c.decodeIfPresent(Double.self, forKey: .resetsAt)
        forecast = try? c.decodeIfPresent(CoreUsageForecast.self, forKey: .forecast)
    }
}

public struct CoreUsageForecast: Codable, Hashable, Sendable {
    public var exhaustsAt: Double?
    public var pace: String?

    public init(exhaustsAt: Double? = nil, pace: String? = nil) {
        self.exhaustsAt = exhaustsAt
        self.pace = pace
    }

    enum CodingKeys: String, CodingKey {
        case pace
        case exhaustsAt = "exhausts_at"
    }
}

/// `usage.providers[].tokens`: the provider's own counters at
/// `observed_at` — input, cached-input and output tokens for whatever
/// period the provider reports on. They ride the provider's `fidelity`:
/// a stale or derived snapshot's counts are stale or derived counts, and
/// a snapshot that counted nothing sends zeroes rather than omitting the
/// block.
public struct CoreUsageTokens: Codable, Hashable, Sendable {
    public var input: Int
    public var cachedInput: Int
    public var output: Int

    /// Everything the provider counted, cache reads included.
    public var total: Int { input + cachedInput + output }

    public init(input: Int = 0, cachedInput: Int = 0, output: Int = 0) {
        self.input = input
        self.cachedInput = cachedInput
        self.output = output
    }

    enum CodingKeys: String, CodingKey {
        case input, output
        case cachedInput = "cached_input"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Counters are integers on the wire; a daemon that sends a float
        // loses nothing by having it truncated.
        func counter(_ key: CodingKeys) -> Int {
            if let value = try? c.decodeIfPresent(Int.self, forKey: key) { return max(0, value) }
            if let value = try? c.decodeIfPresent(Double.self, forKey: key), value.isFinite { return max(0, Int(value)) }
            return 0
        }
        input = counter(.input)
        cachedInput = counter(.cachedInput)
        output = counter(.output)
    }
}

public struct CoreProviderUsage: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var windows: [CoreUsageWindow]
    public var fidelity: String?
    public var state: String?
    public var forecast: CoreUsageForecast?
    /// Plan, account label and fidelity when the daemon knows them
    /// (app-proposed; `usage_history` carries the same block).
    public var account: UsageAccount?
    /// The daemon's fix-it hint when the source is not `ready` ("Reconnect
    /// Claude", "Run grok login") and the reason word behind it
    /// (`authentication_required`, `browser_session_not_imported`).
    public var action: String?
    public var reason: String?
    /// Which configured account this reading belongs to — two accounts of
    /// one provider arrive as two rows sharing `id`, distinguished here.
    public var instance: String?
    /// False when the provider has no quota source at all (Pi, Kiro, …):
    /// a "meters" checkbox for it would be a dead control.
    public var quotaSource: Bool
    /// The provider's token counters at `observed_at`; absent when the
    /// daemon predates the field, present (possibly all-zero) otherwise.
    public var tokens: CoreUsageTokens?
    /// The daemon's own cost estimate for the snapshot's period — an
    /// estimate from list prices, never an invoice.
    public var estimatedCostUSD: Double?
    /// A credit balance, for providers that bill in credits rather than
    /// percent-of-window.
    public var creditsRemaining: Double?
    /// When the snapshot was taken (epoch seconds): the age a stale lane
    /// should name instead of posing as current.
    public var observedAt: Double?

    public init(id: String, windows: [CoreUsageWindow] = [], fidelity: String? = nil, state: String? = nil, forecast: CoreUsageForecast? = nil,
                account: UsageAccount? = nil, action: String? = nil, reason: String? = nil,
                instance: String? = nil, quotaSource: Bool = true, tokens: CoreUsageTokens? = nil,
                estimatedCostUSD: Double? = nil, creditsRemaining: Double? = nil, observedAt: Double? = nil) {
        self.id = id
        self.windows = windows
        self.fidelity = fidelity
        self.state = state
        self.forecast = forecast
        self.account = account
        self.action = action
        self.reason = reason
        self.instance = instance
        self.quotaSource = quotaSource
        self.tokens = tokens
        self.estimatedCostUSD = estimatedCostUSD
        self.creditsRemaining = creditsRemaining
        self.observedAt = observedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        windows = tolerantRows(
            CoreUsageWindow.self,
            try c.decodeIfPresent([JSONValue].self, forKey: .windows)
        )
        fidelity = try c.decodeIfPresent(String.self, forKey: .fidelity)
        state = try c.decodeIfPresent(String.self, forKey: .state)
        forecast = try c.decodeIfPresent(CoreUsageForecast.self, forKey: .forecast)
        account = try c.decodeIfPresent(UsageAccount.self, forKey: .account)
        action = try? c.decodeIfPresent(String.self, forKey: .action)
        reason = try? c.decodeIfPresent(String.self, forKey: .reason)
        instance = try? c.decodeIfPresent(String.self, forKey: .instance)
        quotaSource = (try? c.decodeIfPresent(Bool.self, forKey: .quotaSource)) ?? true
        tokens = try? c.decodeIfPresent(CoreUsageTokens.self, forKey: .tokens)
        estimatedCostUSD = try? c.decodeIfPresent(Double.self, forKey: .estimatedCostUSD)
        creditsRemaining = try? c.decodeIfPresent(Double.self, forKey: .creditsRemaining)
        observedAt = try? c.decodeIfPresent(Double.self, forKey: .observedAt)
    }

    /// Stable identity across multi-account rows of the same provider;
    /// the default instance collapses to the bare id.
    public var identity: String {
        guard let instance, !instance.isEmpty, instance != "default" else { return id }
        return "\(id)|\(instance)"
    }

    enum CodingKeys: String, CodingKey {
        case id, windows, fidelity, state, forecast, account, action, reason, instance, tokens
        case quotaSource = "quota_source"
        case estimatedCostUSD = "estimated_cost_usd"
        case creditsRemaining = "credits_remaining"
        case observedAt = "observed_at"
    }

    /// `not_signed_in`, `signed_out`, `unauthenticated`, `no_auth`: the CLI
    /// has to log in before the daemon can read anything.
    public var isSignedOut: Bool {
        guard let state = state?.lowercased() else { return false }
        return state.contains("sign") || state.contains("auth") || state.contains("login")
    }

    /// Anything the daemon did not measure directly (`derived`, `estimated`, …).
    public var isDerived: Bool {
        guard let fidelity else { return false }
        return fidelity != "official"
    }
}

public struct CoreUsage: Codable, Hashable, Sendable {
    public var refreshedAt: Double?
    public var providers: [CoreProviderUsage]

    public init(refreshedAt: Double? = nil, providers: [CoreProviderUsage] = []) {
        self.refreshedAt = refreshedAt
        self.providers = providers
    }

    enum CodingKeys: String, CodingKey {
        case providers
        case refreshedAt = "refreshed_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        refreshedAt = try c.decodeIfPresent(Double.self, forKey: .refreshedAt)
        providers = tolerantRows(
            CoreProviderUsage.self,
            try c.decodeIfPresent([JSONValue].self, forKey: .providers)
        )
    }
}

public struct CoreClosedLid: Codable, Hashable, Sendable {
    public var policy: String?
    public var holding: Bool?
    public var helperInstalled: Bool?

    enum CodingKeys: String, CodingKey {
        case policy, holding
        case helperInstalled = "helper_installed"
    }
}

public struct CorePower: Codable, Hashable, Sendable {
    public var keepAwake: Bool?
    public var closedLid: CoreClosedLid?

    enum CodingKeys: String, CodingKey {
        case keepAwake = "keep_awake"
        case closedLid = "closed_lid"
    }
}

public struct CoreFocus: Codable, Hashable, Sendable {
    public var mode: String?
    public var source: String?
    public var until: Double?
}

public struct CoreEscalation: Codable, Hashable, Sendable {
    public var stage: String?
    public var since: Double?

    public init(stage: String? = nil, since: Double? = nil) {
        self.stage = stage
        self.since = since
    }

    /// `"none"` 0, `"ramp"`/`"light"` 1, `"menu_bar"` 2, `"final"`/`"chime"`/
    /// `"takeover"` 3; digits as themselves. Unknown words are 0.
    public static func stageNumber(_ text: String?) -> Int {
        guard let text = text?.trimmingCharacters(in: .whitespaces).lowercased(), !text.isEmpty else { return 0 }
        if let number = Int(text) { return max(0, min(3, number)) }
        switch text {
        case "none", "off", "fresh": return 0
        case "ramp", "light", "1": return 1
        case "menu_bar", "menubar", "menu-bar", "flash": return 2
        case "final", "chime", "takeover", "loud": return 3
        default: return 0
        }
    }

    public var stageNumber: Int { Self.stageNumber(stage) }
}

/// One remote peer as of the daemon's last refresh (`state.peers`).
/// Facts only: reachable or not, how many rows it published, and the
/// failure word when it did not answer.
public struct CorePeer: Codable, Hashable, Sendable, Identifiable {
    public var machine: String
    public var host: String?
    public var reachable: Bool
    public var rows: Int
    public var failure: String?

    public var id: String { machine }

    public init(machine: String, host: String? = nil, reachable: Bool = false, rows: Int = 0, failure: String? = nil) {
        self.machine = machine
        self.host = host
        self.reachable = reachable
        self.rows = rows
        self.failure = failure
    }

    enum CodingKeys: String, CodingKey {
        case machine, host, reachable, rows, failure
    }
}

public struct CoreState: Codable, Hashable, Sendable {
    public var generation: Int
    public var now: Double?
    public var aggregate: CoreAggregate
    public var sessions: [CoreSession]
    public var asks: [CoreAsk]
    public var devices: [CoreDevice]
    public var usage: CoreUsage?
    public var power: CorePower?
    public var focus: CoreFocus?
    public var escalation: CoreEscalation?
    public var health: JSONValue?
    public var settingsGeneration: Int?
    /// The Creator Micro 2 deck (app-proposed extension, see app/README.md).
    public var deck: DeckState?
    /// Sessions the daemon keeps out of `sessions` (acknowledged
    /// completions, older ended runs) that `list_history` still has; nil
    /// from a daemon that does not count them.
    public var hiddenCount: Int?
    /// Moves when the effect registry, packs or assignments change, so the
    /// Effect Studio can reload its catalog without reconnecting.
    public var catalogGeneration: Int?
    /// `unseen_completions`: ids of listed sessions that finished since
    /// the user last looked — the daemon intersects it with the rows it
    /// still lists, so membership is all a "new" marker has to check.
    public var unseenCompletions: [String]
    /// `peers`: the remote-peers fleet as of the last refresh — absent
    /// while the feature is off, one row per discovered peer otherwise.
    public var peers: [CorePeer]?

    public init(generation: Int = 0, now: Double? = nil, aggregate: CoreAggregate = CoreAggregate(),
                sessions: [CoreSession] = [], asks: [CoreAsk] = [], devices: [CoreDevice] = [], usage: CoreUsage? = nil,
                power: CorePower? = nil, focus: CoreFocus? = nil, escalation: CoreEscalation? = nil,
                health: JSONValue? = nil, settingsGeneration: Int? = nil, deck: DeckState? = nil, hiddenCount: Int? = nil,
                catalogGeneration: Int? = nil, unseenCompletions: [String] = [], peers: [CorePeer]? = nil) {
        self.generation = generation
        self.now = now
        self.aggregate = aggregate
        self.sessions = sessions
        self.asks = asks
        self.devices = devices
        self.usage = usage
        self.power = power
        self.focus = focus
        self.escalation = escalation
        self.health = health
        self.settingsGeneration = settingsGeneration
        self.deck = deck
        self.hiddenCount = hiddenCount
        self.catalogGeneration = catalogGeneration
        self.unseenCompletions = unseenCompletions
        self.peers = peers
    }

    enum CodingKeys: String, CodingKey {
        case generation, now, aggregate, sessions, asks, devices, usage, power, focus, escalation, health, deck
        case settingsGeneration = "settings_generation"
        case hiddenCount = "hidden_count"
        case catalogGeneration = "catalog_generation"
        case unseenCompletions = "unseen_completions"
        case peers
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        generation = try c.decodeIfPresent(Int.self, forKey: .generation) ?? 0
        now = try c.decodeIfPresent(Double.self, forKey: .now)
        aggregate = try c.decodeIfPresent(CoreAggregate.self, forKey: .aggregate) ?? CoreAggregate()
        sessions = tolerantRows(
            CoreSession.self,
            try c.decodeIfPresent([JSONValue].self, forKey: .sessions)
        )
        asks = tolerantRows(
            CoreAsk.self,
            try c.decodeIfPresent([JSONValue].self, forKey: .asks)
        )
        devices = tolerantRows(
            CoreDevice.self,
            try c.decodeIfPresent([JSONValue].self, forKey: .devices)
        )
        usage = try c.decodeIfPresent(CoreUsage.self, forKey: .usage)
        power = try c.decodeIfPresent(CorePower.self, forKey: .power)
        focus = try c.decodeIfPresent(CoreFocus.self, forKey: .focus)
        escalation = try c.decodeIfPresent(CoreEscalation.self, forKey: .escalation)
        health = try c.decodeIfPresent(JSONValue.self, forKey: .health)
        settingsGeneration = try c.decodeIfPresent(Int.self, forKey: .settingsGeneration)
        // A malformed deck must not take the whole state down with it.
        deck = try? c.decodeIfPresent(DeckState.self, forKey: .deck)
        if let count = try? c.decodeIfPresent(Int.self, forKey: .hiddenCount) {
            hiddenCount = max(0, count)
        } else if let count = try? c.decodeIfPresent(Double.self, forKey: .hiddenCount) {
            hiddenCount = max(0, Int(count))
        } else {
            hiddenCount = nil
        }
        catalogGeneration = try? c.decodeIfPresent(Int.self, forKey: .catalogGeneration)
        unseenCompletions = (try? c.decodeIfPresent([String].self, forKey: .unseenCompletions)) ?? []
        peers = tolerantRows(CorePeer.self, try c.decodeIfPresent([JSONValue].self, forKey: .peers))
    }

    /// Sessions the panel lists: `kind == "main"`. Workers roll up into their parent's badge.
    public var mainSessions: [CoreSession] { sessions.filter { $0.kind == "main" || $0.parent == nil } }

    public func session(withID id: String) -> CoreSession? { sessions.first { $0.id == id } }

    /// Asks whose session the daemon no longer lists — cleared, or
    /// acknowledged out from under a request that is still open. The
    /// aggregate counts them and the light is about them, so the panel
    /// gives them a row of their own rather than dropping them.
    public var orphanAsks: [CoreAsk] {
        guard !asks.isEmpty else { return [] }
        let known = Set(sessions.map(\.id))
        return asks.filter { ask in
            guard let session = ask.session, !session.isEmpty else { return true }
            return !known.contains(session)
        }
    }

    /// `health.sources[provider]` decoded: whether the provider's hook
    /// feed is still delivering (`fresh`) and how many seconds since the
    /// last event it accepted (`heard_age_seconds`, nil when it never
    /// has). `health` stays a reserved JSONValue subtree — this and
    /// `intakeHealth` are the parts of it consumers need typed.
    public func sourceHealth(for provider: String) -> (fresh: Bool, heardAgeSeconds: Double?)? {
        guard let source = health?["sources"]?[provider]?.objectValue else { return nil }
        return (source["fresh"]?.boolValue ?? false, source["heard_age_seconds"]?.doubleValue)
    }

    /// `health.intake`: the intake report's verdict codes (`hook_state`,
    /// `source_health`) and the `silence_seconds` bound it judges
    /// quiet by; nil from a daemon that reports no intake at all.
    public var intakeHealth: (hookState: String?, sourceHealth: String?, silenceSeconds: Double?)? {
        guard let intake = health?["intake"], !intake.isNull else { return nil }
        return (intake["hook_state"]?.stringValue,
                intake["source_health"]?.stringValue,
                intake["silence_seconds"]?.doubleValue)
    }
}

// MARK: - lights

/// What the daemon says about the `why` it chose: the session the light
/// is about, its label and provider, how long it has been in that state,
/// and the dimming applied on top (`why_detail`, every field optional).
public struct CoreWhyDetail: Codable, Hashable, Sendable {
    public var session: String?
    public var label: String?
    public var provider: String?
    public var secondsInState: Double?
    public var brightnessFactor: Double?
    /// Names of the dimming sources in effect (`idle_dim`, `battery`, …).
    public var dimming: [String]

    public init(session: String? = nil, label: String? = nil, provider: String? = nil, secondsInState: Double? = nil,
                brightnessFactor: Double? = nil, dimming: [String] = []) {
        self.session = session
        self.label = label
        self.provider = provider
        self.secondsInState = secondsInState
        self.brightnessFactor = brightnessFactor
        self.dimming = dimming
    }

    enum CodingKeys: String, CodingKey {
        case session, label, provider, dimming
        case secondsInState = "seconds_in_state"
        case brightnessFactor = "brightness_factor"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        session = try c.decodeIfPresent(String.self, forKey: .session)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        provider = try c.decodeIfPresent(String.self, forKey: .provider)
        secondsInState = try c.decodeIfPresent(Double.self, forKey: .secondsInState)
        brightnessFactor = try c.decodeIfPresent(Double.self, forKey: .brightnessFactor)
        // Strings today; objects with a name/kind/reason are read for their word.
        let raw = (try? c.decodeIfPresent([JSONValue].self, forKey: .dimming)) ?? []
        dimming = raw.compactMap { value -> String? in
            switch value {
            case .string(let text): return text
            case .object(let object):
                for key in ["name", "kind", "reason", "id"] {
                    if case .string(let text)? = object[key] { return text }
                }
                return nil
            default: return nil
            }
        }
    }
}

public struct CoreLightSurface: Codable, Hashable, Sendable {
    public var program: String
    public var ledCount: Int?
    /// Epoch seconds at which the program's t=0 happened on the strip.
    public var anchor: Double?
    public var motion: String?
    public var staticFallback: String?
    public var brightness: Double?
    public var why: String?
    public var whyDetail: CoreWhyDetail?
    /// `dot` only, and only while a role is actually driving the Dot
    /// (`docs/CORE-PROTOCOL.md`, "The Dot's role"): `extend` or `asks`.
    /// Absent when the Dot renders its own display, and never on a preview.
    public var role: String?

    public init(program: String, ledCount: Int? = nil, anchor: Double? = nil, motion: String? = nil,
                staticFallback: String? = nil, brightness: Double? = nil, why: String? = nil,
                whyDetail: CoreWhyDetail? = nil, role: String? = nil) {
        self.program = program
        self.ledCount = ledCount
        self.anchor = anchor
        self.motion = motion
        self.staticFallback = staticFallback
        self.brightness = brightness
        self.why = why
        self.whyDetail = whyDetail
        self.role = role
    }

    enum CodingKeys: String, CodingKey {
        case program, anchor, motion, brightness, why, role
        case ledCount = "led_count"
        case staticFallback = "static_fallback"
        case whyDetail = "why_detail"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        program = try c.decodeIfPresent(String.self, forKey: .program) ?? ""
        ledCount = try c.decodeIfPresent(Int.self, forKey: .ledCount)
        anchor = try c.decodeIfPresent(Double.self, forKey: .anchor)
        motion = try c.decodeIfPresent(String.self, forKey: .motion)
        staticFallback = try c.decodeIfPresent(String.self, forKey: .staticFallback)
        brightness = try c.decodeIfPresent(Double.self, forKey: .brightness)
        why = try c.decodeIfPresent(String.self, forKey: .why)
        whyDetail = try? c.decodeIfPresent(CoreWhyDetail.self, forKey: .whyDetail)
        role = try c.decodeIfPresent(String.self, forKey: .role)
    }
}

/// `lights.auto_dim`: the decision behind the `auto_dim` dimming word.
/// `mode` is the setting, `source` the reader that produced `factor`
/// (ambient without a sensor falls back to `display`), `available` false
/// when the mode's own source could not be read, `reading` the raw value
/// (lux, the display fraction, or minutes since midnight).
public struct CoreAutoDim: Codable, Hashable, Sendable {
    public var mode: String
    public var source: String
    public var factor: Double?
    public var available: Bool
    public var reading: Double?

    public init(mode: String = "off", source: String = "off", factor: Double? = nil, available: Bool = true, reading: Double? = nil) {
        self.mode = mode
        self.source = source
        self.factor = factor
        self.available = available
        self.reading = reading
    }

    enum CodingKeys: String, CodingKey { case mode, source, factor, available, reading }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? "off"
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? mode
        factor = try? c.decodeIfPresent(Double.self, forKey: .factor)
        available = try c.decodeIfPresent(Bool.self, forKey: .available) ?? true
        reading = try? c.decodeIfPresent(Double.self, forKey: .reading)
    }

    /// The setting is doing something.
    public var isActive: Bool { mode != "off" }
}

/// `lights.dot_link`: the daemon's own word for the Pro + Dot link —
/// which of `off`, `no_dot`, `no_strip`, `beacon`, `solo`, `linked` or
/// `failed` applies right now, the `dot_role` behind it, and the linked
/// write's error class when the last one failed. The states a settings
/// toggle cannot express (`no_strip`, `failed`) are why this exists; it
/// is nil on daemons that predate it, and the app falls back to the
/// `devices_linked` setting then.
public struct CoreDotLink: Codable, Hashable, Sendable {
    public var state: String
    public var role: String?
    public var error: String?

    public init(state: String, role: String? = nil, error: String? = nil) {
        self.state = state
        self.role = role
        self.error = error
    }

    enum CodingKeys: String, CodingKey { case state, role, error }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? "off"
        role = try c.decodeIfPresent(String.self, forKey: .role)
        error = try c.decodeIfPresent(String.self, forKey: .error)
    }
}

public struct CoreLights: Codable, Hashable, Sendable {
    public var surfaces: [String: CoreLightSurface]
    public var linked: Bool?
    /// Additive (protocol 1, schema 3): the `devices_linked` setting in
    /// effect with both a Pro and a Dot connected, the measured gap between
    /// their write completions, and the auto-dim decision.
    public var devicesLinked: Bool?
    public var linkedSkewMs: Double?
    /// When `linkedSkewMs` was measured (epoch seconds); the two travel
    /// together or not at all.
    public var linkedSkewAt: Double?
    public var dotLink: CoreDotLink?
    public var autoDim: CoreAutoDim?

    public init(surfaces: [String: CoreLightSurface] = [:], linked: Bool? = nil, devicesLinked: Bool? = nil,
                linkedSkewMs: Double? = nil, linkedSkewAt: Double? = nil,
                dotLink: CoreDotLink? = nil, autoDim: CoreAutoDim? = nil) {
        self.surfaces = surfaces
        self.linked = linked
        self.devicesLinked = devicesLinked
        self.linkedSkewMs = linkedSkewMs
        self.linkedSkewAt = linkedSkewAt
        self.dotLink = dotLink
        self.autoDim = autoDim
    }

    enum CodingKeys: String, CodingKey {
        case surfaces, linked
        case devicesLinked = "devices_linked"
        case linkedSkewMs = "linked_skew_ms"
        case linkedSkewAt = "linked_skew_at"
        case dotLink = "dot_link"
        case autoDim = "auto_dim"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawSurfaces = try c.decodeIfPresent([String: JSONValue].self, forKey: .surfaces) ?? [:]
        surfaces = rawSurfaces.compactMapValues {
            try? ReplyDecoding.decode(CoreLightSurface.self, from: $0)
        }
        linked = try c.decodeIfPresent(Bool.self, forKey: .linked)
        devicesLinked = try? c.decodeIfPresent(Bool.self, forKey: .devicesLinked)
        linkedSkewMs = try? c.decodeIfPresent(Double.self, forKey: .linkedSkewMs)
        linkedSkewAt = try? c.decodeIfPresent(Double.self, forKey: .linkedSkewAt)
        dotLink = try? c.decodeIfPresent(CoreDotLink.self, forKey: .dotLink)
        autoDim = try? c.decodeIfPresent(CoreAutoDim.self, forKey: .autoDim)
    }

    public var screenBar: CoreLightSurface? { surfaces["screen_bar"] }
    public var hardware: CoreLightSurface? { surfaces["hardware"] }
    public var dot: CoreLightSurface? { surfaces["dot"] }

    /// The skew is a measurement, not a state: past half an hour it is
    /// old news and says nothing about whether the pair is in step now.
    public static let linkedSkewFreshSeconds: TimeInterval = 30 * 60
    public var isLinkedSkewFresh: Bool {
        guard let linkedSkewAt, linkedSkewMs != nil else { return false }
        return linkedSkewAt >= Date().timeIntervalSince1970 - Self.linkedSkewFreshSeconds
    }
}

// MARK: - event

public struct CoreEvent: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var kind: String
    public var session: String?
    public var label: String?
    public var at: Double?
    public var sound: String?
    public var notify: Bool?
    /// Additive fields: the provider behind the event, a one-line detail
    /// (the ask summary, the quota window), and the escalation stage
    /// (`escalation_stage` events; 0...3, or a stage name).
    public var provider: String?
    public var detail: String?
    public var stage: Int?
    /// `deck_input`: the observed control (`{index, kind, at}`, nested
    /// because the envelope's `kind` is the event kind). `deck_receipt`:
    /// the receipt `code` and its `message`.
    public var input: DeckInput?
    public var code: String?
    public var message: String?
    /// `usage_history_ready`: the range (`7d`, `30d`, …) whose scan finished
    /// for `provider`; nil means every range.
    public var range: String?

    /// `usage_history_ready {provider, range?}`: the daemon's background
    /// scan for `usage_history` has fresh rows; a client that asked earlier
    /// and got a partial or slow answer should ask again. `notify: false`;
    /// a daemon that never sends it costs nothing.
    public static let usageHistoryReadyKind = "usage_history_ready"

    /// `quota_reset`'s lane (`"weekly"`, `"5h-weekly"`, …): the quota
    /// window that reset. Confetti fires only on the weekly ones.
    public var lane: String?

    /// `list_history` rows: seconds the session ran when the daemon knows
    /// both ends of it. nil for events without a measured span.
    public var duration: Double?

    /// The resume point this frame carries: `<stream>:<event id>`. The
    /// last cursor a client saw is what it replays from after a drop.
    public var cursor: String?

    public init(id: String, kind: String, session: String? = nil, label: String? = nil, at: Double? = nil, sound: String? = nil,
                notify: Bool? = nil, provider: String? = nil, detail: String? = nil, stage: Int? = nil,
                input: DeckInput? = nil, code: String? = nil, message: String? = nil, range: String? = nil,
                lane: String? = nil, duration: Double? = nil, cursor: String? = nil) {
        self.id = id
        self.kind = kind
        self.session = session
        self.label = label
        self.at = at
        self.sound = sound
        self.notify = notify
        self.provider = provider
        self.detail = detail
        self.stage = stage
        self.input = input
        self.code = code
        self.message = message
        self.range = range
        self.lane = lane
        self.duration = duration
        self.cursor = cursor
    }

    enum CodingKeys: String, CodingKey { case id, kind, session, label, at, sound, notify, provider, detail, stage, input, code, message, range, lane, duration, cursor }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "unknown"
        session = try c.decodeIfPresent(String.self, forKey: .session)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        at = try c.decodeIfPresent(Double.self, forKey: .at)
        sound = try c.decodeIfPresent(String.self, forKey: .sound)
        notify = try c.decodeIfPresent(Bool.self, forKey: .notify)
        provider = try c.decodeIfPresent(String.self, forKey: .provider)
        detail = try c.decodeIfPresent(String.self, forKey: .detail)
        if let number = try? c.decodeIfPresent(Int.self, forKey: .stage) {
            stage = number
        } else if let text = try? c.decodeIfPresent(String.self, forKey: .stage) {
            stage = CoreEscalation.stageNumber(text)
        } else {
            stage = nil
        }
        input = try? c.decodeIfPresent(DeckInput.self, forKey: .input)
        code = try? c.decodeIfPresent(String.self, forKey: .code)
        message = try? c.decodeIfPresent(String.self, forKey: .message)
        range = try? c.decodeIfPresent(String.self, forKey: .range)
        lane = try? c.decodeIfPresent(String.self, forKey: .lane)
        duration = try? c.decodeIfPresent(Double.self, forKey: .duration)
        cursor = try? c.decodeIfPresent(String.self, forKey: .cursor)
    }

    /// `deck_receipt` as a receipt value.
    public var receipt: DeckReceipt? {
        guard kind == "deck_receipt", let code else { return nil }
        return DeckReceipt(code: code, message: message, at: at)
    }
}

// MARK: - settings

public struct CoreSettings: Codable, Hashable, Sendable {
    public var generation: Int
    public var schema: Int?
    public var document: JSONValue

    public init(generation: Int = 0, schema: Int? = nil, document: JSONValue = .object([:])) {
        self.generation = generation
        self.schema = schema
        self.document = document
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        generation = try c.decodeIfPresent(Int.self, forKey: .generation) ?? 0
        schema = try c.decodeIfPresent(Int.self, forKey: .schema)
        document = try c.decodeIfPresent(JSONValue.self, forKey: .document) ?? .object([:])
    }
}

// MARK: - reply

public struct CoreReplyError: Codable, Hashable, Sendable, Error {
    public var code: String
    public var message: String?

    public init(code: String, message: String? = nil) {
        self.code = code
        self.message = message
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        code = try c.decodeIfPresent(String.self, forKey: .code) ?? "error"
        message = try c.decodeIfPresent(String.self, forKey: .message)
    }
}

public struct CoreReply: Codable, Hashable, Sendable {
    public var id: String
    public var ok: Bool
    public var result: JSONValue?
    public var error: CoreReplyError?

    public init(id: String, ok: Bool, result: JSONValue? = nil, error: CoreReplyError? = nil) {
        self.id = id
        self.ok = ok
        self.result = result
        self.error = error
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        ok = try c.decodeIfPresent(Bool.self, forKey: .ok) ?? false
        result = try c.decodeIfPresent(JSONValue.self, forKey: .result)
        error = try c.decodeIfPresent(CoreReplyError.self, forKey: .error)
    }
}

// MARK: - log

public struct CoreLog: Codable, Hashable, Sendable {
    public var level: String?
    public var message: String?
    public var at: Double?
}

// MARK: - command (app → daemon)

public struct CoreCommand: Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var args: [String: JSONValue]

    public init(id: String, name: String, args: [String: JSONValue] = [:]) {
        self.id = id
        self.name = name
        self.args = args
    }

    enum CodingKeys: String, CodingKey { case t, v, id, name, args }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        args = try c.decodeIfPresent([String: JSONValue].self, forKey: .args) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode("command", forKey: .t)
        try c.encode(CoreProtocol.version, forKey: .v)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(args, forKey: .args)
    }
}

// MARK: - envelope

/// One decoded daemon → app frame.
public enum CoreMessage: Hashable, Sendable {
    case hello(CoreHello)
    case state(CoreState)
    case lights(CoreLights)
    case event(CoreEvent)
    case settings(CoreSettings)
    case reply(CoreReply)
    case log(CoreLog)
    /// A type this build does not know (or a protocol version it does not
    /// speak). Kept so callers can count or log it; never an error.
    case unknown(type: String, version: Int?)

    public var typeName: String {
        switch self {
        case .hello: return "hello"
        case .state: return "state"
        case .lights: return "lights"
        case .event: return "event"
        case .settings: return "settings"
        case .reply: return "reply"
        case .log: return "log"
        case .unknown(let type, _): return type
        }
    }
}
