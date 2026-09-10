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
    var range: UsageHistoryRange {
        didSet {
            UserDefaults.standard.set(range.rawValue, forKey: "usageCenterRange")
            loadAll()
        }
    }
    var metric: Metric = Metric(rawValue: UserDefaults.standard.string(forKey: "usageCenterMetric") ?? "") ?? .tokens {
        didSet { UserDefaults.standard.set(metric.rawValue, forKey: "usageCenterMetric") }
    }
    var now = Date()
    var refreshing = false
    var lastError: String?
    var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    /// Provider → when its `quota_reset` arrived; the card celebrates for ~1.4 s.
    var resetPulses: [String: Date] = [:]

    private(set) var histories: [String: UsageHistory] = [:]
    private(set) var loading: Set<String> = []
    private(set) var errors: [String: String] = [:]

    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var lastEventID: String?
    @ObservationIgnored private var observing = false
    @ObservationIgnored private var isOpen = false
    @ObservationIgnored private var errorClear: DispatchWorkItem?

    init(core: CoreModel) {
        self.core = core
        range = UsageHistoryRange(rawValue: UserDefaults.standard.string(forKey: "usageCenterRange") ?? "") ?? .month
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
                if !provider.isEmpty { load(provider: provider, force: true) }
            }
        }
        let live = core.isLive
        let ids = core.usage.map(\.id)
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

    private func key(_ provider: String) -> String { provider + "|" + range.rawValue }

    func history(for provider: String) -> UsageHistory? { histories[key(provider)] }

    func isLoading(_ provider: String) -> Bool { loading.contains(key(provider)) }

    func error(for provider: String) -> String? { errors[key(provider)] }

    func loadAll() {
        guard isOpen, core.isLive else { return }
        for provider in core.usage where !provider.isSignedOut {
            load(provider: provider.id)
        }
    }

    func load(provider: String, force: Bool = false) {
        guard core.isLive else { return }
        let key = key(provider)
        if !force, histories[key] != nil || loading.contains(key) { return }
        loading.insert(key)
        errors[key] = nil
        let range = self.range
        Task { [weak self] in
            guard let self else { return }
            do {
                let history = try await self.core.usageHistory(provider: provider, range: range)
                self.histories[key] = history
            } catch {
                self.errors[key] = Self.describe(error)
            }
            self.loading.remove(key)
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
                    self.load(provider: provider.id, force: true)
                }
            } catch {
                self.show(error: "Refresh failed: \(Self.describe(error))")
            }
            self.refreshing = false
        }
    }

    func forecast(for provider: CoreProviderUsage, window: CoreUsageWindow) -> UsageForecast {
        // The daemon's `forecast` is about the primary (5h) window; other
        // windows only get its pace word.
        let primary = window.id == (provider.windows.first { $0.name.lowercased() == "5h" }?.id ?? provider.windows.first?.id)
        let daemon = primary ? provider.forecast : provider.forecast.map { CoreUsageForecast(exhaustsAt: nil, pace: $0.pace) }
        let samples = core.usageSamples.samples(provider: provider.id, window: window.name)
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
        if let label = account?.label, !label.isEmpty { parts.append(label) }
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
