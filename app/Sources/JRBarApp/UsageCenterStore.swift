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
        // A window's own `forecast` wins. The provider-level one is about
        // the primary (5h) window; other windows only get its pace word.
        let primary = window.id == (provider.windows.first { $0.name.lowercased() == "5h" }?.id ?? provider.windows.first?.id)
        let daemon = window.forecast
            ?? (primary ? provider.forecast : provider.forecast.map { CoreUsageForecast(exhaustsAt: nil, pace: $0.pace) })
        let samples = core.usageSamples.samples(provider: provider.identity, window: window.name)
        return UsageForecaster.forecast(window: window, daemon: daemon, samples: samples, now: now.timeIntervalSince1970)
    }

    /// The window the card leads with: 5h when reported, else the first.
    static func primaryWindow(of provider: CoreProviderUsage) -> CoreUsageWindow? {
        provider.windows.first { $0.name.lowercased() == "5h" } ?? provider.windows.first
    }

    func isCelebrating(_ provider: String) -> Bool {
        guard let at = resetPulses[provider] else { return false }
        return now.timeIntervalSince(at) < 1.6
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
        parts.append(fidelityLabel(provider.fidelity ?? account?.fidelity))
        return parts.joined(separator: " · ")
    }
}
