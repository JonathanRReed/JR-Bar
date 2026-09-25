import AppKit
import JRBarCore
import Observation

/// The Usage Center's state: the providers from the daemon's `state`, the
/// `usage_history` documents per provider and range, the forecast per
/// window (the daemon's, else a local extrapolation of the sample log),
/// and the one-shot `quota_reset` flourish.
@MainActor
@Observable
final class UsageCenterStore {
    enum Metric: String, CaseIterable, Identifiable {
        case tokens, cost
        var id: String { rawValue }
        var label: String { self == .tokens ? "Tokens" : "Cost" }
    }

    let core: CoreModel

    /// The daemon's settings document: `usage_graph_days` and
    /// `usage_display_mode` live there, so the Settings page's "Graph
    /// range" and "Lead with" pickers and this window's toolbar write the
    /// same keys through `set_setting`.
    var document: SettingsDocument? { core.settings.map { SettingsDocument($0.document) } }

    /// The range the cards show: `usage_graph_days` as a history range.
    /// A write from this window lands through `set_setting` and repaints
    /// via the pushed document; `pendingRange` covers the instant in
    /// between so the toolbar never flickers back to the old value.
    var range: UsageHistoryRange {
        get { pendingRange ?? Self.range(forDays: document?.int("usage_graph_days")) }
        set { setRange(newValue) }
    }

    /// The metric the cards lead with: `usage_display_mode`. "percent"
    /// and "sessions" are legal daemon values the legacy menu graphs; the
    /// Usage Center has no such chart, so they read as tokens rather than
    /// rendering a blank window.
    var metric: Metric {
        get { pendingMetric ?? (Metric(rawValue: document?.string("usage_display_mode") ?? "") ?? .tokens) }
        set { setMetric(newValue) }
    }

    private var pendingRange: UsageHistoryRange?
    private var pendingMetric: Metric?
    private var seenSettingsGeneration: Int?

    /// `usage_graph_days` as a `UsageHistoryRange`; anything else the
    /// document holds (absent, corrupt) is the daemon's own default week.
    static func range(forDays days: Int?) -> UsageHistoryRange {
        switch days {
        case 30: return .month
        case 90: return .quarter
        case 365: return .year
        default: return .week
        }
    }

    /// Write `usage_graph_days` and reload every card for the new range.
    func setRange(_ newValue: UsageHistoryRange) {
        guard newValue != range else { return }
        pendingRange = newValue
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.core.setSetting("usage_graph_days", value: .number(Double(newValue.days)))
            } catch {
                self.pendingRange = nil
                self.show(error: "Range not saved: \(Self.describe(error))")
            }
        }
        loadAll()
    }

    /// Write `usage_display_mode`; the cards repaint on the push.
    func setMetric(_ newValue: Metric) {
        guard newValue != metric else { return }
        pendingMetric = newValue
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.core.setSetting("usage_display_mode", value: .string(newValue.rawValue))
            } catch {
                self.pendingMetric = nil
                self.show(error: "Metric not saved: \(Self.describe(error))")
            }
        }
    }
    var now = Date()
    var refreshing = false
    var lastError: String?
    var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    /// Provider → when its `quota_reset` arrived; the card celebrates for ~1.4 s.
    var resetPulses: [String: Date] = [:]
    /// The panel's per-provider drill ("Open Claude in the Usage Center"):
    /// the view scrolls this provider's card into view, and `focusPulses`
    /// flashes its border once on the same 1.6 s clock as `quota_reset`.
    /// `focusPulses` is also the scroll trigger: re-focusing the same
    /// provider still moves the marker, where a repeated id would not.
    var focusProvider: String?
    var focusPulses: [String: Date] = [:]

    /// The panel drills in by provider id; the scroll marker is the
    /// card's `identity` so a duplicate provider id still lands on a card.
    func focus(provider: String?) {
        guard let provider else { return }
        let identity = core.usage.first { $0.id == provider }?.identity ?? provider
        focusProvider = identity
        focusPulses[identity] = Date()
    }

    func isFocused(_ provider: CoreProviderUsage) -> Bool {
        guard let at = focusPulses[provider.identity] else { return false }
        return now.timeIntervalSince(at) < 1.6
    }

    private(set) var histories: [String: UsageHistory] = [:]
    private(set) var loading: Set<String> = []
    private(set) var errors: [String: String] = [:]
    /// Providers whose scan is still running daemon-side: either the reply
    /// said `partial`, or it never came inside the (generous) timeout. The
    /// card keeps its skeleton and waits for `usage_history_ready` rather
    /// than accusing the core of being broken on a first, cold scan.
    private(set) var scanning: Set<String> = []

    /// How many times a cold first load is retried on its own before the
    /// card admits an error; a `usage_history_ready` event short-circuits
    /// the wait.
    static let coldRetries = 2
    static let coldRetryDelay: TimeInterval = 6

    @ObservationIgnored private var attempts: [String: Int] = [:]

    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var lastEventID: String?
    @ObservationIgnored private var observing = false
    @ObservationIgnored private var isOpen = false
    @ObservationIgnored private var errorClear: DispatchWorkItem?

    init(core: CoreModel) {
        self.core = core
    }

    // MARK: Lifecycle

    func windowDidOpen() {
        isOpen = true
        now = Date()
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        observeCore()
        loadAll()
        loadProviderRows()
    }

    func windowDidClose() {
        isOpen = false
        ticker?.invalidate()
        ticker = nil
    }

    private func tick() {
        now = Date()
        reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        // Expired pulses go away so the overlay is not kept alive for nothing.
        resetPulses = resetPulses.filter { now.timeIntervalSince($0.value) < 3 }
        focusPulses = focusPulses.filter { now.timeIntervalSince($0.value) < 3 }
        // Throttled per provider inside `loadBurners`.
        for provider in providers where !provider.isSignedOut { loadBurners(for: provider) }
    }

    /// Watches the daemon's events and connection: a `quota_reset` triggers
    /// the flourish and a reload; reconnecting reloads too.
    private func observeCore() {
        guard !observing else { return }
        observing = true
        track()
    }

    private func track() {
        withObservationTracking {
            _ = core.lastEvent?.id
            _ = core.isLive
            _ = core.usage.count
            _ = core.settings?.generation
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.coreDidChange()
                self.track()
            }
        }
    }

    private var wasLive = false
    private var knownProviders: [String] = []

    private func coreDidChange() {
        if let event = core.lastEvent, event.id != lastEventID {
            lastEventID = event.id
            if event.kind == "quota_reset" {
                let provider = event.provider ?? event.label?.lowercased() ?? ""
                resetPulses[provider] = Date()
                if !provider.isEmpty {
                    for match in core.usage where match.id == provider {
                        load(provider: match, force: true)
                    }
                }
            }
            if event.kind == CoreEvent.usageHistoryReadyKind {
                historyDidBecomeReady(provider: event.provider, range: event.range)
            }
        }
        // A pushed settings document can carry a range or metric written
        // from the Settings page: the pendings this window set are now
        // facts, and a range change means the cards need the other range.
        let generation = core.settings?.generation
        if generation != seenSettingsGeneration {
            seenSettingsGeneration = generation
            pendingRange = nil
            pendingMetric = nil
            loadAll()
        }
        let live = core.isLive
        let ids = core.usage.map(\.identity)
        if (live && !wasLive) || ids != knownProviders {
            loadAll()
            loadProviderRows()
        }
        wasLive = live
        knownProviders = ids
    }

    // MARK: Data

    var isLive: Bool { core.isLive }

    /// Every provider the daemon reports, signed-out ones included: the
    /// card says how to fix that.
    var providers: [CoreProviderUsage] { core.isLive ? core.usage : [] }

    var refreshedAt: Date? { core.state?.usage?.refreshedAt.map { Date(timeIntervalSince1970: $0) } }

    /// Caches key by `identity` (`id|instance`) so two accounts of one
    /// provider keep separate histories; the daemon's `usage_history`
    /// still takes the bare provider id.
    private func key(_ provider: CoreProviderUsage) -> String { provider.identity + "|" + range.rawValue }

    func history(for provider: CoreProviderUsage) -> UsageHistory? { histories[key(provider)] }

    func isLoading(_ provider: CoreProviderUsage) -> Bool { loading.contains(key(provider)) }

    /// The daemon is still scanning: what is shown (if anything) is partial.
    func isScanning(_ provider: CoreProviderUsage) -> Bool { scanning.contains(key(provider)) }

    func error(for provider: CoreProviderUsage) -> String? { errors[key(provider)] }

    /// The scan ran and this Mac has no transcripts for the provider at
    /// all — a different thing from a range with nothing in it.
    func hasNoLocalRecords(_ provider: CoreProviderUsage) -> Bool {
        guard let history = history(for: provider) else { return false }
        return history.hasNoLocalRecords && !isScanning(provider)
    }

    func loadAll() {
        guard isOpen, core.isLive else { return }
        for provider in core.usage where !provider.isSignedOut {
            load(provider: provider)
        }
    }

    func load(provider: CoreProviderUsage, force: Bool = false) {
        guard core.isLive else { return }
        let key = key(provider)
        if !force, histories[key] != nil || loading.contains(key) { return }
        if force { attempts[key] = 0 }
        loading.insert(key)
        errors[key] = nil
        let range = self.range
        Task { [weak self] in
            guard let self else { return }
            do {
                let history = try await self.core.usageHistory(provider: provider.id, range: range)
                self.histories[key] = history
                // The daemon answered from what it had while its scan runs
                // on: keep the skeleton and wait to be told it landed.
                if history.partial {
                    self.scanning.insert(key)
                    self.retryCold(provider: provider, key: key)
                } else {
                    self.scanning.remove(key)
                    self.attempts[key] = 0
                }
            } catch {
                // A cold scan can outlive even the long timeout. That is
                // the core being slow, not the core being wrong: hold the
                // skeleton, ask again, and only give up after a couple of
                // tries. Anything else (a refusal, an unknown provider) is
                // shown at once.
                let cold = (error as? CoreClientError) == .timeout && self.histories[key] == nil
                if cold, (self.attempts[key] ?? 0) < Self.coldRetries {
                    self.scanning.insert(key)
                    self.retryCold(provider: provider, key: key)
                } else {
                    self.scanning.remove(key)
                    self.errors[key] = Self.describe(error)
                }
            }
            self.loading.remove(key)
        }
    }

    /// Asks again after a pause, unless a `usage_history_ready` event has
    /// already done it. Counted, so a daemon that never finishes still
    /// ends in an honest error row rather than a skeleton forever.
    private func retryCold(provider: CoreProviderUsage, key: String) {
        attempts[key] = (attempts[key] ?? 0) + 1
        guard (attempts[key] ?? 0) <= Self.coldRetries else {
            scanning.remove(key)
            if histories[key] == nil { errors[key] = "The monitor is still scanning transcripts. Try Refresh in a moment." }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.coldRetryDelay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isOpen, self.scanning.contains(key) else { return }
                self.loading.insert(key)
                Task { [weak self] in
                    guard let self else { return }
                    await self.reload(provider: provider, key: key)
                }
            }
        }
    }

    /// One more `usage_history` for a scan that was still running.
    private func reload(provider: CoreProviderUsage, key: String) async {
        do {
            let history = try await core.usageHistory(provider: provider.id, range: range)
            histories[key] = history
            if history.partial {
                retryCold(provider: provider, key: key)
            } else {
                scanning.remove(key)
                errors[key] = nil
                attempts[key] = 0
            }
        } catch {
            if (attempts[key] ?? 0) < Self.coldRetries {
                retryCold(provider: provider, key: key)
            } else {
                scanning.remove(key)
                if histories[key] == nil { errors[key] = Self.describe(error) }
            }
        }
        loading.remove(key)
    }

    /// `usage_history_ready {provider, range?}`: the daemon's background
    /// scan landed. Only the ranges this window is showing are re-read; a
    /// daemon that never sends the event costs nothing (the retry above
    /// covers it).
    private func historyDidBecomeReady(provider: String?, range: String?) {
        guard isOpen else { return }
        if let range, !range.isEmpty, range != self.range.rawValue { return }
        // The event names a provider id; every instance of it is re-asked.
        let providers = (provider?.isEmpty == false) ? core.usage.filter { $0.id == provider } : core.usage
        for provider in providers {
            let key = key(provider)
            scanning.remove(key)
            attempts[key] = 0
            guard histories[key] != nil || errors[key] != nil || loading.contains(key) else { continue }
            loading.insert(key)
            Task { [weak self] in
                guard let self else { return }
                await self.reload(provider: provider, key: key)
            }
        }
    }

    // MARK: Actions

    /// Settings › Usage from this window: the app menu's selector builds
    /// the Settings window if it has never been shown, then the window's
    /// controller (its delegate) selects the page.
    func openUsageSettings() {
        NSApp.sendAction(Selector(("openSettings:")), to: nil, from: nil)
        if let controller = NSApp.windows
            .first(where: { $0.identifier?.rawValue == "settings" })?
            .delegate as? SettingsWindowController {
            controller.show(page: .usage)
        }
    }

    /// `claude_plan_limits_enabled`, consent-stamped the same way the
    /// Settings page writes it: the consent version lands first so a
    /// consent-aware core sees it already in the document.
    var claudePlanLimitsEnabled: Bool { document?.bool("claude_plan_limits_enabled") ?? false }

    func enableClaudePlanLimits() {
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.core.setSetting("claude_plan_limits_consent_version", value: .number(1))
                let reply = try await self.core.setSetting("claude_plan_limits_enabled", value: .bool(true))
                if !reply.ok {
                    self.show(error: reply.error?.message ?? reply.error?.code ?? "Plan limits stayed off")
                }
            } catch {
                self.show(error: "Plan limits not enabled: \(Self.describe(error))")
            }
        }
    }

    /// `refresh_usage` for every provider, then fresh histories.
    func refresh() {
        guard core.isLive, !refreshing else { return }
        refreshing = true
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.core.refreshUsage()
                for provider in self.core.usage where !provider.isSignedOut {
                    self.load(provider: provider, force: true)
                }
            } catch {
                self.show(error: "Refresh failed: \(Self.describe(error))")
            }
            self.refreshing = false
        }
    }

    func forecast(for provider: CoreProviderUsage, window: CoreUsageWindow) -> UsageForecast {
        Self.forecast(for: provider, window: window, core: core, now: now)
    }

    /// The forecast every usage surface reads: the window's own daemon
    /// forecast (else the provider's, else a local fit), then made aware
    /// of what is running — a pace with no agent working here holds
    /// instead of promising a run-out, and the working count rides along
    /// for "room for one more".
    static func forecast(for provider: CoreProviderUsage, window: CoreUsageWindow,
                         core: CoreModel, now: Date) -> UsageForecast {
        // A window's own `forecast` wins. The provider-level one is about
        // the daemon's 5h-convention primary; other windows only get its
        // pace word.
        let primary = window.id == Self.conventionalWindow(of: provider)?.id
        let daemon = window.forecast
            ?? (primary ? provider.forecast : provider.forecast.map { CoreUsageForecast(exhaustsAt: nil, pace: $0.pace) })
        let samples = core.usageSamples.samples(provider: provider.identity, window: window.name)
        let forecast = UsageForecaster.forecast(window: window, daemon: daemon, samples: samples, now: now.timeIntervalSince1970)
        // A hub account is spent by whoever uses the proxy, not by this
        // Mac's agents: they neither pace it nor hold it idle.
        guard core.isLive, !UsageSourceNotes.isHubInstance(provider.instance) else { return forecast }
        return SessionAwarePace.adjust(forecast, working: workingAgents(provider: provider.id, core: core))
    }

    /// This Mac's sessions of `provider` that are working right now.
    static func workingAgents(provider: String, core: CoreModel) -> Int {
        core.sessions.filter { $0.provider == provider && !$0.isRemote && SessionActivity.reduce($0) == .working }.count
    }

    // MARK: Who is burning the window

    /// Provider identity → this Mac's sessions ranked by the tokens they
    /// spent since the card's headline window opened.
    private(set) var burners: [String: [WindowBurner]] = [:]
    @ObservationIgnored private var burnersFetchedAt: [String: Date] = [:]
    nonisolated static let burnersInterval: TimeInterval = 30

    /// True when the daemon's reply budget ran out before every session's
    /// transcript was read: the ranking would be missing someone.
    nonisolated static func burnersStillReading(_ gaps: [String: String]) -> Bool {
        gaps.values.contains("reading")
    }

    func burners(for provider: CoreProviderUsage) -> [WindowBurner] { burners[provider.identity] ?? [] }

    /// Asks `session_usage` for the provider's local sessions with the
    /// headline window's start as `since`, at most every
    /// `burnersInterval`. The share is of the tokens those sessions spent
    /// — what this Mac can see — not of the provider's percentage.
    /// A reply still `reading` a session keeps the ranking it had (one
    /// missing that session would misstate every share) and asks again
    /// soon; a failed one waits the interval like an answer.
    func loadBurners(for provider: CoreProviderUsage, force: Bool = false) {
        guard core.isLive, let window = Self.featuredWindow(of: provider),
              let resetsAt = window.resetsAt,
              let span = UsageWindowLabel.windowSpan(id: window.key, name: window.name) else { return }
        let identity = provider.identity
        if !force, let at = burnersFetchedAt[identity], now.timeIntervalSince(at) < Self.burnersInterval { return }
        let sessions = core.sessions.filter { $0.provider == provider.id && !$0.isRemote }
        guard !sessions.isEmpty else {
            burners[identity] = []
            return
        }
        burnersFetchedAt[identity] = now
        let since = resetsAt - span
        let labels = Dictionary(sessions.map { ($0.id, $0.displayLabel) }, uniquingKeysWith: { first, _ in first })
        Task { [weak self] in
            guard let self else { return }
            do {
                let document = try await self.core.sessionUsage(ids: Array(labels.keys.prefix(SessionUsageStore.batchLimit)), since: since)
                if Self.burnersStillReading(document.gaps) {
                    self.burnersFetchedAt[identity] = self.now.addingTimeInterval(SessionUsageStore.readingRetry - Self.burnersInterval)
                    return
                }
                self.burners[identity] = WindowBurner.rank(document.sessions.compactMap { id, usage in
                    usage.tokensSince.map { (id: id, label: labels[id] ?? id, tokens: $0) }
                })
            } catch {
                // The send's stamp stands, so the one-second clock does not
                // resend while the daemon is still working on this one.
            }
        }
    }

    /// The window the card leads with: `primaryWindow`, the same
    /// most-exhausted pick every surface uses.
    static func featuredWindow(of provider: CoreProviderUsage) -> CoreUsageWindow? {
        primaryWindow(of: provider)
    }

    /// The window every surface leads with — the card's headline, the
    /// panel row's big number, the menu-bar meter: the daemon's
    /// `constrained` pick when it names a real window (least headroom of
    /// the applicable measured lanes), the same least-headroom rule
    /// computed locally when it does not, else the 5h convention. A
    /// weekly lane at 100 % outranks a 5h lane with headroom: the tighter
    /// constraint is always the story, never the shorter clock.
    static func primaryWindow(of provider: CoreProviderUsage) -> CoreUsageWindow? {
        provider.headlineWindow
    }

    /// The 5h convention: what the pick would be before exhaustion is
    /// consulted — the baseline the card's "Watching it" note compares
    /// against when the constrained pick differs.
    static func conventionalWindow(of provider: CoreProviderUsage) -> CoreUsageWindow? {
        provider.conventionalWindow
    }

    /// A window's reset as the Usage Center says it — under a ring, at
    /// the end of a combined row: `PanelStore.countdown`, so a broken
    /// source names its fix ("Reconnect Claude") once the reset is past.
    /// Nil when there is no window or it names no reset.
    static func resetText(_ window: CoreUsageWindow?, of provider: CoreProviderUsage, now: Date) -> String? {
        window.flatMap { PanelStore.countdown(to: $0.resetsAt, now: now, fix: provider.staleFix) }
    }

    /// The caption under a card's headline percent: "5h window · resets
    /// in 1h 02m", the fix in place of a broken source's past reset.
    static func headlineResetLine(_ window: CoreUsageWindow, of provider: CoreProviderUsage, now: Date) -> String {
        let reset = resetText(window, of: provider, now: now) ?? "no reset time"
        return "\(window.longName) window · \(reset)"
    }

    func isCelebrating(_ provider: String) -> Bool {
        guard let at = resetPulses[provider] else { return false }
        return now.timeIntervalSince(at) < 1.6
    }

    // MARK: Provider connections (W06)

    /// `list_providers` rows keyed by identity (`id` or `id|instance`) —
    /// the inspect/manage surface (enabled flag, consents, credential
    /// availability).
    private(set) var providerRows: [String: ProviderRow] = [:]
    /// A toggle while its write is in flight: a second tap can't stack.
    private var managing: Set<String> = []

    func row(for identity: String) -> ProviderRow? { providerRows[identity] }

    func loadProviderRows() {
        guard core.isLive else { providerRows = [:]; return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let rows = try await self.core.listProviders()
                self.providerRows = Dictionary(
                    uniqueKeysWithValues: rows.map { ($0.identity, $0) }
                )
            } catch {
                // Inspection is best-effort: without it the cards still
                // show quota state, just without the manage row.
            }
        }
    }

    func setProviderEnabled(_ row: ProviderRow, _ on: Bool) {
        guard !managing.contains(row.identity) else { return }
        managing.insert(row.identity)
        Task { [weak self] in
            guard let self else { return }
            defer { self.managing.remove(row.identity) }
            do {
                let updated = try await self.core.setProviderEnabled(
                    row.id,
                    enabled: on,
                    instance: row.instance == "default" ? nil : row.instance
                )
                self.providerRows[updated.identity] = updated
            } catch {
                self.show(error: "\(row.label): \(Self.describe(error))")
            }
        }
    }

    /// `provider_add_instance`: one more configured account for a
    /// provider the daemon says can hold one. The row comes back
    /// metered-but-empty until the instance's own credential or consent
    /// lands — the card's manage row is where that happens next.
    func addProviderInstance(_ row: ProviderRow, instance: String, label: String?) {
        let trimmed = instance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !managing.contains(row.identity) else { return }
        managing.insert(row.identity)
        Task { [weak self] in
            guard let self else { return }
            defer { self.managing.remove(row.identity) }
            do {
                let labelText = label?.trimmingCharacters(in: .whitespacesAndNewlines)
                let added = try await self.core.addProviderInstance(
                    row.id,
                    instance: trimmed,
                    label: (labelText?.isEmpty ?? true) ? nil : labelText
                )
                self.providerRows[added.identity] = added
                self.loadProviderRows()
            } catch {
                self.show(error: Self.describe(error))
            }
        }
    }

    /// Runs the staged flow behind the provider's current action label —
    /// clipboard import, reconnect, repair. The daemon's own message is
    /// surfaced verbatim; it may be a success note, not only an error.
    func runProviderAction(_ provider: CoreProviderUsage) {
        guard !managing.contains(provider.identity) else { return }
        managing.insert(provider.identity)
        Task { [weak self] in
            guard let self else { return }
            defer { self.managing.remove(provider.identity) }
            do {
                let message = try await self.core.providerAction(
                    provider.id,
                    instance: provider.instance == "default" ? nil : provider.instance
                )
                self.show(error: message)
                self.loadProviderRows()
            } catch {
                self.show(error: Self.describe(error))
            }
        }
    }

    /// Providers mid re-sign-in, keyed by identity — the row's button
    /// spins while the daemon re-pulls the sign-in and force-refreshes.
    private(set) var resigningIn: Set<String> = []

    func isResigningIn(_ provider: CoreProviderUsage) -> Bool {
        resigningIn.contains(provider.identity)
    }

    /// "Re-sign in" / "Update provider" (T3 Code's pattern): asks the
    /// daemon to re-pull whatever sign-in the provider's own tooling
    /// holds — the Claude Code Keychain item, the grok CLI's auth file, a
    /// consented browser session — and force a refresh. The reply's own
    /// message is surfaced verbatim: when the sign-in itself is what
    /// lapsed it names the provider's remedy (`grok login`, the `gemini`
    /// CLI) rather than claiming a reconnect nothing performed. A
    /// `sign_in_url` in the reply means the remedy is a page only the
    /// user can sign in to — it is opened for them.
    func resignIn(_ provider: CoreProviderUsage) {
        guard core.isLive, !resigningIn.contains(provider.identity) else { return }
        resigningIn.insert(provider.identity)
        Task { [weak self] in
            guard let self else { return }
            defer { self.resigningIn.remove(provider.identity) }
            do {
                let result = try await self.core.resignInProvider(
                    provider.id,
                    instance: provider.instance == "default" ? nil : provider.instance
                )
                self.show(error: result.message.isEmpty ? "Re-checking \(provider.id)'s sign-in…" : result.message)
                if let urlString = result.signInURL, let url = URL(string: urlString) {
                    NSWorkspace.shared.open(url)
                }
                self.loadProviderRows()
            } catch {
                self.show(error: Self.describe(error))
            }
        }
    }

    /// Revokes one exact consent; the daemon removes the imported
    /// credential only while it is still the imported one.
    func revokeConsent(providerID: String, consent: ProviderConsentRow) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let reply = try await self.core.providerConsent(
                    action: "revoke",
                    provider: providerID,
                    browser: consent.browser,
                    profile: consent.profile,
                    instance: consent.sourceInstanceID == "default" ? nil : consent.sourceInstanceID
                )
                if !reply.ok {
                    self.show(error: reply.error?.message ?? "Consent revoke refused")
                    return
                }
                self.loadProviderRows()
            } catch {
                self.show(error: "Revoke failed: \(Self.describe(error))")
            }
        }
    }

    private func show(error: String) {
        lastError = error
        errorClear?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.lastError = nil } }
        errorClear = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    static func describe(_ error: Error) -> String {
        if let reply = error as? CoreReplyError {
            return reply.message ?? reply.code
        }
        return "\(error)"
    }

    // MARK: Formatting

    static func fidelityLabel(_ fidelity: String?) -> String {
        switch fidelity?.lowercased() {
        case "official": return "Official"
        case "derived", "estimated": return "Derived"
        case "manual": return "Manual"
        case nil, "": return "Unknown source"
        case let other?: return other.capitalized
        }
    }

    /// "Max 20× · jonathan@… · Official" from whatever the daemon knows.
    static func accountLine(_ provider: CoreProviderUsage, history: UsageHistory?) -> String {
        let account = provider.account ?? history?.account
        var parts: [String] = []
        if let plan = account?.plan, !plan.isEmpty { parts.append(plan) }
        // Account labels are whatever the provider hands over: an email, an
        // org slug, or a bare account UUID. A UUID is shortened the way
        // every other id in the app is, rather than eating the line.
        if let label = account?.label, !label.isEmpty {
            parts.append(SessionLabel.looksLikeUUID(label) ? String(label.prefix(8)) : SessionLabel.shorteningUUIDs(label))
        }
        // A source that is not ready carries the daemon's fix-it hint
        // ("Reconnect Claude · authentication required"); that says more
        // than repeating the badge's word.
        if let action = provider.action, !action.isEmpty {
            parts.append(action)
            if let reason = provider.reason, !reason.isEmpty { parts.append(reason.replacingOccurrences(of: "_", with: " ")) }
            return parts.joined(separator: " · ")
        }
        // With no quota source there is no figure for "Official" to vouch
        // for; the card's own sentence says why.
        if provider.quotaSource {
            parts.append(fidelityLabel(provider.fidelity ?? account?.fidelity))
        }
        return parts.joined(separator: " · ")
    }
}
