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
    let sessionUsage: SessionUsageStore
    @ObservationIgnored let chartCache = UsageChartCache()

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
        get { pendingRange?.value ?? Self.range(forDays: document?.int("usage_graph_days")) }
        set { setRange(newValue) }
    }

    /// The metric the cards lead with: `usage_display_mode`. "percent"
    /// and "sessions" are legal daemon values the legacy menu graphs; the
    /// Usage Center has no such chart, so they read as tokens rather than
    /// rendering a blank window.
    var metric: Metric {
        get { pendingMetric?.value ?? (Metric(rawValue: document?.string("usage_display_mode") ?? "") ?? .tokens) }
        set { setMetric(newValue) }
    }

    private struct PendingChoice<Value> {
        let value: Value
        let request = UUID()
        var accepted = false
        var generation: Int?

        func confirmed(by currentGeneration: Int?, matchingValue: Bool) -> Bool {
            guard accepted else { return false }
            if let generation { return currentGeneration.map { $0 >= generation } ?? false }
            return matchingValue
        }
    }

    private var pendingRange: PendingChoice<UsageHistoryRange>?
    private var pendingMetric: PendingChoice<Metric>?
    private var seenSettingsGeneration: Int?
    @ObservationIgnored var writeSetting: (SettingsPath, JSONValue) async throws -> CoreReply

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
    @discardableResult
    func setRange(_ newValue: UsageHistoryRange) -> Task<Void, Never>? {
        guard newValue != range else { return nil }
        let choice = PendingChoice(value: newValue)
        pendingRange = choice
        let write = writeSetting
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let reply = try await write("usage_graph_days", .number(Double(newValue.days)))
                guard self.pendingRange?.request == choice.request else { return }
                if let refusal = Self.refusal(reply) {
                    self.pendingRange = nil
                    self.show(error: "Range not saved: \(refusal)", action: .range)
                    self.loadAll()
                } else {
                    self.actionSucceeded(.range)
                    self.pendingRange?.accepted = true
                    self.pendingRange?.generation = reply.result?["generation"]?.intValue
                    self.settlePendingChoices()
                    self.loadAll()
                }
            } catch {
                guard self.pendingRange?.request == choice.request else { return }
                self.pendingRange = nil
                self.show(error: "Range not saved: \(Self.describe(error))", action: .range)
                self.loadAll()
            }
        }
        loadAll()
        return task
    }

    /// Write `usage_display_mode`; the cards repaint on the push.
    @discardableResult
    func setMetric(_ newValue: Metric) -> Task<Void, Never>? {
        guard newValue != metric else { return nil }
        let choice = PendingChoice(value: newValue)
        pendingMetric = choice
        let write = writeSetting
        return Task { [weak self] in
            guard let self else { return }
            do {
                let reply = try await write("usage_display_mode", .string(newValue.rawValue))
                guard self.pendingMetric?.request == choice.request else { return }
                if let refusal = Self.refusal(reply) {
                    self.pendingMetric = nil
                    self.show(error: "Metric not saved: \(refusal)", action: .metric)
                } else {
                    self.actionSucceeded(.metric)
                    self.pendingMetric?.accepted = true
                    self.pendingMetric?.generation = reply.result?["generation"]?.intValue
                    self.settlePendingChoices()
                }
            } catch {
                guard self.pendingMetric?.request == choice.request else { return }
                self.pendingMetric = nil
                self.show(error: "Metric not saved: \(Self.describe(error))", action: .metric)
            }
        }
    }

    private func settlePendingChoices() {
        if let pendingRange, pendingRange.confirmed(by: core.settings?.generation,
            matchingValue: document?.int("usage_graph_days") == pendingRange.value.days) {
            self.pendingRange = nil
        }
        if let pendingMetric, pendingMetric.confirmed(by: core.settings?.generation,
            matchingValue: document?.string("usage_display_mode") == pendingMetric.value.rawValue) {
            self.pendingMetric = nil
        }
    }
    var overviewGraph: CoreUsageGraph?
    var overviewGraphError: String?
    @ObservationIgnored private var overviewRequest: Task<Void, Never>?
    @ObservationIgnored private var overviewRequestID: UUID?

    @ObservationIgnored var readOverviewGraph: () async throws -> CoreUsageGraphDocument
    @ObservationIgnored private var overviewFollowUp = false
    @ObservationIgnored private var overviewContinuation: UUID?
    @ObservationIgnored var scheduleOverviewContinuation: (@escaping @MainActor () -> Void) -> Void = { resume in
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            MainActor.assumeIsolated { resume() }
        }
    }

    private func continueOverviewIfNeeded() {
        guard isOpen, core.isLive, !tokenHistoryOff, (overviewGraph?.readingFiles ?? 0) > 0,
              overviewContinuation == nil else { return }
        let generation = UUID()
        overviewContinuation = generation
        scheduleOverviewContinuation { [weak self] in
            guard let self, self.overviewContinuation == generation else { return }
            self.overviewContinuation = nil
            guard (self.overviewGraph?.readingFiles ?? 0) > 0 else { return }
            self.loadOverviewGraph()
        }
    }

    @discardableResult
    func loadOverviewGraph(force: Bool = false) -> Task<Void, Never>? {
        guard isOpen, core.isLive, !tokenHistoryOff else { return nil }
        if let overviewRequest {
            if force { overviewFollowUp = true }
            return overviewRequest
        }
        let request = UUID()
        overviewRequestID = request
        overviewRequest = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            defer {
                if self.overviewRequestID == request {
                    self.overviewRequest = nil
                    self.continueOverviewIfNeeded()
                }
            }
            repeat {
                self.overviewFollowUp = false
                do {
                    let document = try await self.readOverviewGraph()
                    guard !Task.isCancelled, self.overviewRequestID == request, !self.tokenHistoryOff else { return }
                    if self.overviewFollowUp { continue }
                    self.overviewGraph = UsageSourceReading.providerGraph(document.graph)
                    self.overviewGraphError = nil
                } catch {
                    guard !Task.isCancelled, self.overviewRequestID == request, !self.tokenHistoryOff else { return }
                    if self.overviewFollowUp { continue }
                    self.overviewGraphError = Self.describe(error)
                }
            } while self.overviewFollowUp && self.isOpen && self.core.isLive && !self.tokenHistoryOff
        }
        return overviewRequest
    }

    var now = Date()
    var refreshing = false
    private(set) var historyDisabled = false
    var tokenHistoryOff: Bool { historyDisabled || document?.bool("token_history_enabled") == false }

    func enableTokenHistory() {
        Task { [weak self] in
            guard let self else { return }
            do {
                let reply = try await self.writeSetting("token_history_enabled", .bool(true))
                if let refusal = Self.refusal(reply) {
                    self.show(error: refusal, action: .refresh)
                    return
                }
                self.historyDisabled = false
                for provider in self.historyProviders { self.load(provider: provider, force: true) }
            } catch { self.show(error: Self.describe(error), action: .refresh) }
        }
    }

    enum NoticeAction: Equatable {
        case range, metric, refresh, planLimits
        case providerEnabled(String), usageConsent(String), addInstance(String)
        case providerAction(String), resignIn(String)
        case revokeConsent(ConsentRevocation)
    }

    struct ConsentRevocation: Equatable {
        let provider: String
        let instance: String?
        let browser: String?
        let profile: String?
    }

    struct Notice: Equatable {
        let id = UUID()
        let action: NoticeAction
        let text: String
        let isFailure: Bool
    }

    private(set) var notice: Notice?
    var lastError: String? { notice?.isFailure == true ? notice?.text : nil }
    @ObservationIgnored var copyNoticeText: (String) -> Void = { text in
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    @ObservationIgnored var scheduleNoticeExpiry: (@escaping @MainActor () -> Void) -> Void = { expire in
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            MainActor.assumeIsolated { expire() }
        }
    }
    var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    /// Account identity → when its `quota_reset` arrived; the card celebrates for ~1.4 s.
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
        let identity = Self.identity(for: provider, in: providers)
        focusProvider = identity
        focusPulses[identity] = Date()
    }

    /// The card a drill names: an identity (`id|instance`) is taken as it
    /// is, so the second account of a provider is not mistaken for the
    /// first; a bare provider id lands on that provider's first card.
    nonisolated static func identity(for provider: String, in usage: [CoreProviderUsage]) -> String {
        if usage.contains(where: { $0.identity == provider }) { return provider }
        return usage.first { $0.id == provider }?.identity ?? provider
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
    @ObservationIgnored private var historySequence: UInt64 = 0
    @ObservationIgnored private var historyRequests: [String: UInt64] = [:]
    @ObservationIgnored private var dirtyHistoryKeys: Set<String> = []
    private(set) var resetSaveFailure: String?
    @ObservationIgnored var readResetStatus: (Bool) async throws -> CoreReply
    @ObservationIgnored private var resetStatusRequest: UInt64 = 0

    @discardableResult
    func loadResetStatus(retry: Bool = false) -> Task<Void, Never> {
        resetStatusRequest &+= 1
        let request = resetStatusRequest
        return Task { [weak self] in
            guard let self else { return }
            do {
                let reply = try await self.readResetStatus(retry)
                guard self.resetStatusRequest == request else { return }
                guard reply.ok else {
                    if retry { self.resetSaveFailure = Self.refusal(reply) }
                    return
                }
                let persistence = reply.result?["persistence"]
                self.resetSaveFailure = persistence?["dirty"]?.boolValue == true
                    ? persistence?["error"]?.stringValue : nil
            } catch {
                if self.resetStatusRequest == request, retry { self.resetSaveFailure = error.localizedDescription }
            }
        }
    }

    @ObservationIgnored var readHistory: (String, UsageHistoryRange) async throws -> UsageHistory
    @ObservationIgnored var readHistoryStatus: (String, UsageHistoryRange) async throws -> UsageHistory
    @ObservationIgnored var readProviderRows: () async throws -> [ProviderRow]
    @ObservationIgnored var revokeProviderConsent: (ConsentRevocation) async throws -> CoreReply
    @ObservationIgnored var scheduleColdRetry: (@escaping @MainActor () -> Void) -> Void = { retry in
        DispatchQueue.main.asyncAfter(deadline: .now() + UsageCenterStore.coldRetryDelay) {
            MainActor.assumeIsolated { retry() }
        }
    }

    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var lastEventSequence = 0
    @ObservationIgnored private var gapSeenWhileClosed = false
    @ObservationIgnored private var observing = false
    @ObservationIgnored private var isOpen = false
    // Keep quota readings through a monitor restart.
    private var lastUsage: CoreUsage?
    private(set) var usageSnapshotReceivedAt: Double = Date().timeIntervalSince1970

    init(core: CoreModel, sessionUsage: SessionUsageStore? = nil) {
        self.core = core
        readOverviewGraph = { try await core.usageGraph(days: 30, metric: "tokens") }
        self.sessionUsage = sessionUsage ?? SessionUsageStore(core: core)
        readResetStatus = { retry in try await core.send("reset_status", args: retry ? ["retry": .bool(true)] : [:]) }
        writeSetting = { try await core.setSetting($0, value: $1) }
        readHistory = { try await core.usageHistory(provider: $0, range: $1) }
        readHistoryStatus = { try await core.usageHistory(provider: $0, range: $1, observe: true) }
        readProviderRows = { try await core.listProviders() }
        revokeProviderConsent = { request in
            try await core.providerConsent(action: "revoke", provider: request.provider,
                browser: request.browser, profile: request.profile, instance: request.instance)
        }
        lastUsage = core.isLive ? core.state?.usage : nil
        usageSnapshotReceivedAt = core.lastStateAt?.timeIntervalSince1970 ?? Date().timeIntervalSince1970
    }

    // MARK: Lifecycle

    @discardableResult
    func windowDidOpen() -> [Task<Void, Never>] {
        // Consume retained completions while closed so only changed caches reload.
        // A lost event is remembered until all ranges can be reconciled below.
        if !isOpen { coreDidChange() }
        isOpen = true
        rememberUsage()
        now = Date()
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        observeCore()
        let read = core.readEvents(after: lastEventSequence)
        let needsReconciliation = read.hasGap || gapSeenWhileClosed
        gapSeenWhileClosed = false
        lastEventSequence = core.eventSequence
        var tasks: [Task<Void, Never>] = []
        if needsReconciliation {
            tasks = reconcileHistory()
        } else {
            tasks = historyProviders.compactMap {
                let historyKey = key($0)
                let retry = !loading.contains(historyKey) && (errors[historyKey] != nil || scanning.contains(historyKey))
                return load(provider: $0, force: retry)
            }
        }
        if !tokenHistoryOff { sessionUsage.refresh(ids: openSessions.map(\.id)) }
        loadOverviewGraph()
        tasks.append(loadResetStatus())
        loadProviderRows()
        return tasks
    }

    private func reconcileHistory() -> [Task<Void, Never>] {
        guard isOpen else { return [] }
        loadOverviewGraph(force: true)
        var tasks: [Task<Void, Never>] = []
        resetPulses.removeAll()
        for provider in historyProviders {
            for range in UsageHistoryRange.allCases {
                if let task = load(provider: provider, force: true, range: range) { tasks.append(task) }
            }
        }
        return tasks
    }

    func windowDidClose() {
        isOpen = false
        overviewRequest?.cancel()
        overviewRequest = nil
        overviewRequestID = nil
        overviewFollowUp = false
        overviewContinuation = nil
        ticker?.invalidate()
        ticker = nil
    }

    private func tick() {
        now = Date()
        if !tokenHistoryOff { sessionUsage.refresh(ids: openSessions.map(\.id)) }
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

    /// What the Usage Center wakes for: an event, liveness, the usage
    /// slice and the settings document — not a frame that only moved the
    /// sessions or the daemon's clock.
    static func observedFacts(_ core: CoreModel) {
        _ = core.eventSequence
        _ = core.isLive
        _ = core.usage
        _ = core.settings?.generation
    }

    private func track() {
        withObservationTracking {
            Self.observedFacts(core)
        } onChange: { [weak self] in
            MainActor.assumeIsolated { self?.rememberUsage() }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.coreDidChange()
                self.track()
            }
        }
    }

    private var wasLive = false
    private var knownProviders: [String] = []

    @discardableResult
    func coreDidChange() -> [Task<Void, Never>] {
        if tokenHistoryOff {
            overviewRequest?.cancel()
            overviewRequest = nil
            overviewRequestID = nil
            overviewFollowUp = false
        }
        rememberUsage()
        let read = core.readEvents(after: lastEventSequence)
        let events = read.hasGap ? [] : read.events
        lastEventSequence = core.eventSequence
        var reconciliationTasks: [Task<Void, Never>] = []
        if read.hasGap, !isOpen { gapSeenWhileClosed = true }
        if read.hasGap, isOpen {
            reconciliationTasks = reconcileHistory()
            loadResetStatus()
            loadProviderRows()
        }
        var historyEvents: [CoreEvent] = []
        for event in events {
            if event.kind == "reset_save_failed" || event.kind == "reset_saved" { loadResetStatus() }
            if event.kind == "quota_reset" {
                if !historyEvents.isEmpty {
                    historyDidComplete(historyEvents)
                    historyEvents.removeAll(keepingCapacity: true)
                }
                let provider = event.provider ?? event.label?.lowercased() ?? ""
                let instance = event.instance ?? "default"
                let identity = instance.isEmpty || instance == "default" ? provider : "\(provider)|\(instance)"
                if !provider.isEmpty {
                    resetPulses[identity] = Date()
                    if let historyProvider = historyProviders.first(where: { $0.id == provider }) {
                        load(provider: historyProvider, force: true)
                    }
                }
            }
            if event.kind == CoreEvent.usageHistoryReadyKind || event.kind == CoreEvent.usageHistoryFailedKind {
                historyEvents.append(event)
            }
        }
        if !historyEvents.isEmpty { historyDidComplete(historyEvents) }
        // A pushed settings document can carry a range or metric written
        // from the Settings page. A pending choice becomes a fact only once
        // its own accepted write generation has arrived.
        let generation = core.settings?.generation
        if generation != seenSettingsGeneration {
            seenSettingsGeneration = generation
            settlePendingChoices()
            loadAll()
        }
        let live = core.isLive
        if !live && wasLive {
            providerRowsGeneration += 1
            providerRows = [:]
        }
        let ids = core.usage.map(\.identity)
        var resumed: [Task<Void, Never>] = reconciliationTasks
        if live && !wasLive && isOpen {
            // A retry that came due while disconnected could not finish.
            // Resume its partial history, including an earlier graph range.
            for provider in historyProviders {
                for range in UsageHistoryRange.allCases where scanning.contains(key(provider, range: range)) {
                    if let task = load(provider: provider, force: true, range: range) { resumed.append(task) }
                }
            }
        }
        if (live && !wasLive) || ids != knownProviders {
            loadAll()
            loadProviderRows()
        }
        wasLive = live
        knownProviders = ids
        return resumed
    }

    // MARK: Data

    func providerTitle(_ provider: CoreProviderUsage) -> String {
        let name = ProviderStyle.style(for: provider.id, document: document).name
        guard providers.filter({ $0.id == provider.id }).count > 1 else { return name }
        let account = provider.instanceLabel ?? provider.account?.label ?? provider.instance.map(UsageSourceNotes.instanceBadge)
        return account.map { name + " · " + $0 } ?? name
    }

    func quotaPace(for provider: CoreProviderUsage) -> [String: Double] {
        var values: [String: Double] = [:]
        for window in provider.windows {
            if let reset = window.resetsAt, let span = UsageWindowLabel.windowSpan(id: window.id, name: window.name), span > 0 {
                let remaining = reset - now.timeIntervalSince1970
                let elapsed = (1 - remaining / span) * 100
                values[window.name] = min(100, max(0, elapsed))
            }
        }
        return values
    }

    var openSessions: [CoreSession] {
        core.allSessions.filter { [.working, .waiting, .idle].contains(SessionActivity.reduce($0)) }
    }

    var isLive: Bool { core.isLive }

    /// Every provider the daemon reports, signed-out ones included: the
    /// card says how to fix that.
    var providers: [CoreProviderUsage] { core.isLive ? core.usage : lastUsage?.providers ?? [] }

    var refreshedAt: Date? {
        let reading = core.isLive ? core.state?.usage : lastUsage
        return reading?.refreshedAt.map { Date(timeIntervalSince1970: $0) }
    }

    private func rememberUsage() {
        guard core.isLive, let usage = core.state?.usage else { return }
        if usage != lastUsage {
            usageSnapshotReceivedAt = core.lastStateAt?.timeIntervalSince1970 ?? Date().timeIntervalSince1970
        }
        lastUsage = usage
    }

    /// Transcript history combines this Mac's configured homes for a provider.
    /// Prefer the local/default card; a named-only setup still gets one history.
    var historyProviders: [CoreProviderUsage] {
        var order: [String] = []
        var selected: [String: CoreProviderUsage] = [:]
        for provider in providers where supportsLocalHistory(provider) && !provider.isSignedOut && !UsageSourceNotes.isHubInstance(provider.instance) {
            if selected[provider.id] == nil {
                order.append(provider.id)
                selected[provider.id] = provider
            } else if provider.identity == provider.id {
                selected[provider.id] = provider
            }
        }
        return order.compactMap { selected[$0] }
    }

    func supportsLocalHistory(_ provider: CoreProviderUsage) -> Bool {
        provider.id != "factory"
    }

    func ownsLocalHistory(_ provider: CoreProviderUsage) -> Bool {
        historyProviders.first { $0.id == provider.id }?.identity == provider.identity
    }

    private func key(_ provider: CoreProviderUsage, range: UsageHistoryRange? = nil) -> String {
        provider.id + "|" + (range ?? self.range).rawValue
    }

    func history(for provider: CoreProviderUsage) -> UsageHistory? {
        ownsLocalHistory(provider) ? histories[key(provider)] : nil
    }

    func isLoading(_ provider: CoreProviderUsage) -> Bool {
        ownsLocalHistory(provider) && loading.contains(key(provider))
    }

    /// The daemon is still scanning: what is shown (if anything) is partial.
    func isScanning(_ provider: CoreProviderUsage) -> Bool { ownsLocalHistory(provider) && scanning.contains(key(provider)) }

    func error(for provider: CoreProviderUsage) -> String? { ownsLocalHistory(provider) ? errors[key(provider)] : nil }

    /// The scan ran and this Mac has no transcripts for the provider at
    /// all — a different thing from a range with nothing in it.
    func hasNoLocalRecords(_ provider: CoreProviderUsage) -> Bool {
        guard error(for: provider) == nil, let history = history(for: provider) else { return false }
        return history.hasNoLocalRecords && !isScanning(provider)
    }

    func loadAll() {
        guard isOpen, core.isLive else { return }
        for provider in historyProviders {
            load(provider: provider)
        }
    }

    @discardableResult
    func load(provider: CoreProviderUsage, force: Bool = false, range: UsageHistoryRange? = nil) -> Task<Void, Never>? {
        guard core.isLive, ownsLocalHistory(provider) else { return nil }
        let range = range ?? self.range
        let key = key(provider, range: range)
        let needsRefresh = force || dirtyHistoryKeys.contains(key)
        if !needsRefresh, histories[key] != nil || loading.contains(key) { return nil }
        dirtyHistoryKeys.remove(key)
        if needsRefresh { attempts[key] = 0 }
        loading.insert(key)
        errors[key] = nil
        let request = beginHistoryRequest(key: key)
        return Task { [weak self] in
            guard let self else { return }
            do {
                let history = try await self.readHistory(provider.id, range)
                guard self.historyRequests[key] == request else { return }
                self.histories[key] = history
                // The daemon answered from what it had while its scan runs
                // on: keep the skeleton and wait to be told it landed.
                if history.partial {
                    self.scanning.insert(key)
                    self.retryCold(provider: provider, key: key, range: range, request: request)
                } else {
                    self.scanning.remove(key)
                    self.attempts[key] = 0
                }
            } catch {
                guard self.historyRequests[key] == request else { return }
                // A cold scan can outlive even the long timeout. That is
                // the core being slow, not the core being wrong: hold the
                // skeleton, ask again, and only give up after a couple of
                // tries. Anything else (a refusal, an unknown provider) is
                // shown at once.
                let cold = (error as? CoreClientError) == .timeout && self.histories[key] == nil
                if cold, (self.attempts[key] ?? 0) < Self.coldRetries {
                    self.scanning.insert(key)
                    self.retryCold(provider: provider, key: key, range: range, request: request)
                } else {
                    self.scanning.remove(key)
                    if self.histories[key] != nil { self.dirtyHistoryKeys.insert(key) }
                    self.errors[key] = Self.describe(error)
                }
            }
            self.loading.remove(key)
        }
    }

    /// A newer read owns this key, including its scan and loading state.
    private func beginHistoryRequest(key: String) -> UInt64 {
        historySequence &+= 1
        historyRequests[key] = historySequence
        return historySequence
    }

    /// Retry only the request that still owns the card.
    private func retryCold(provider: CoreProviderUsage, key: String, range: UsageHistoryRange, request: UInt64) {
        attempts[key] = (attempts[key] ?? 0) + 1
        guard (attempts[key] ?? 0) <= Self.coldRetries else {
            scanning.remove(key)
            dirtyHistoryKeys.insert(key)
            errors[key] = "The monitor is still scanning transcripts. Try Refresh in a moment."
            return
        }
        scheduleColdRetry { [weak self] in
            guard let self, self.isOpen, self.core.isLive, self.scanning.contains(key),
                  self.historyRequests[key] == request,
                  let owner = self.historyProviders.first(where: { $0.id == provider.id }) else { return }
            self.loading.insert(key)
            let next = self.beginHistoryRequest(key: key)
            Task { [weak self] in
                guard let self else { return }
                await self.reload(provider: owner, key: key, range: range, request: next)
            }
        }
    }

    /// One more `usage_history` for a scan that was still running. The
    /// range is the one `key` was made for: asking for whichever range the
    /// toolbar shows by now would file a month under the week's key.
    private func reload(provider: CoreProviderUsage, key: String, range: UsageHistoryRange,
                        request: UInt64, observeOnly: Bool = false) async {
        do {
            let read = observeOnly ? readHistoryStatus : readHistory
            let history = try await read(provider.id, range)
            guard historyRequests[key] == request else { return }
            historyDisabled = false
            histories[key] = history
            errors[key] = nil
            if history.partial {
                scanning.insert(key)
                if !observeOnly { retryCold(provider: provider, key: key, range: range, request: request) }
            } else {
                scanning.remove(key)
                dirtyHistoryKeys.remove(key)
                attempts[key] = 0
            }
        } catch {
            guard historyRequests[key] == request else { return }
            if (error as? CoreReplyError)?.isTokenHistoryDisabled == true {
                historyDisabled = true
                histories[key] = nil
            }
            if !observeOnly, (error as? CoreClientError) == .timeout, (attempts[key] ?? 0) < Self.coldRetries {
                scanning.insert(key)
                retryCold(provider: provider, key: key, range: range, request: request)
            } else {
                scanning.remove(key)
                dirtyHistoryKeys.insert(key)
                errors[key] = Self.describe(error)
            }
        }
        loading.remove(key)
    }

    /// Failure facts invalidate memory; observation checks for newer success without retrying work.
    private func historyDidComplete(_ events: [CoreEvent]) {
        loadOverviewGraph(force: true)
        for provider in historyProviders {
            var outcomes: [UsageHistoryRange: Bool] = [:]
            for event in events {
                guard event.provider == nil || event.provider == "" || event.provider == provider.id else { continue }
                let ranges: [UsageHistoryRange]
                if let range = event.range, !range.isEmpty {
                    guard let resolved = UsageHistoryRange(rawValue: range) else { continue }
                    ranges = [resolved]
                } else {
                    ranges = UsageHistoryRange.allCases
                }
                for range in ranges { outcomes[range] = event.kind == CoreEvent.usageHistoryFailedKind }
            }
            for range in UsageHistoryRange.allCases {
                guard let observeOnly = outcomes[range] else { continue }
                let key = key(provider, range: range)
                dirtyHistoryKeys.insert(key)
                guard isOpen, range == self.range else { continue }
                scanning.remove(key)
                attempts[key] = 0
                guard histories[key] != nil || errors[key] != nil || loading.contains(key) else { continue }
                dirtyHistoryKeys.remove(key)
                loading.insert(key)
                let request = beginHistoryRequest(key: key)
                Task { [weak self] in
                    guard let self else { return }
                    await self.reload(provider: provider, key: key, range: range, request: request, observeOnly: observeOnly)
                }
            }
        }
    }

    // MARK: Actions

    /// Settings › Agents & Usage from this window: the app menu's selector builds
    /// the Settings window if it has never been shown, then the window's
    /// controller (its delegate) selects the page.
    func openUsageSettings() {
        NSApp.sendAction(Selector(("openSettings:")), to: nil, from: nil)
        if let controller = NSApp.windows
            .first(where: { $0.identifier?.rawValue == "settings" })?
            .delegate as? SettingsWindowController {
            controller.show(chapter: .usage)
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
                    self.show(error: reply.error?.message ?? reply.error?.code ?? "Plan limits stayed off", action: .planLimits)
                } else {
                    self.actionSucceeded(.planLimits)
                }
            } catch {
                self.show(error: "Plan limits not enabled: \(Self.describe(error))", action: .planLimits)
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
                self.loadOverviewGraph(force: true)
                self.actionSucceeded(.refresh)
                for provider in self.historyProviders {
                    self.load(provider: provider, force: true)
                }
            } catch {
                self.show(error: "Refresh failed: \(Self.describe(error))", action: .refresh)
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
        // the daemon's 5h-convention primary. Another lane never borrows the primary's pace word: "under" on
        // the 5h lane says nothing about a weekly lane at 97 %.
        if !core.isLive || provider.isStale {
            let reason = core.isLive ? "stale_samples" : "monitor_offline"
            return UsageForecast(window: window.name, usedPct: window.usedPct, resetsAt: window.resetsAt,
                                 verdict: window.usedPct == nil ? .unmeasured : .guarded(reason: reason),
                                 ratePctPerHour: nil, source: .none, pace: "guarded", guardReason: reason)
        }
        let primary = window.id == Self.conventionalWindow(of: provider)?.id
        let daemon = window.forecast ?? (primary ? provider.forecast : nil)
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
    @ObservationIgnored private var providerRowsGeneration: UInt64 = 0
    /// A toggle while its write is in flight: a second tap can't stack.
    private var managing: Set<String> = []

    func row(for identity: String) -> ProviderRow? { providerRows[identity] }

    /// The rows keyed by identity. Two rows that claim one identity must
    /// not take the app down (a trap on a duplicate key): the first stays.
    nonisolated static func rowsByIdentity(_ rows: [ProviderRow]) -> [String: ProviderRow] {
        Dictionary(rows.map { ($0.identity, $0) }, uniquingKeysWith: { first, _ in first })
    }

    @discardableResult
    func loadProviderRows() -> Task<Void, Never>? {
        providerRowsGeneration += 1
        let generation = providerRowsGeneration
        guard core.isLive else { providerRows = [:]; return nil }
        let hello = core.hello
        let read = readProviderRows
        return Task { [weak self] in
            guard let self else { return }
            do {
                let rows = try await read()
                guard self.core.isLive, self.providerRowsGeneration == generation,
                      self.core.hello == hello else { return }
                self.providerRows = Self.rowsByIdentity(rows)
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
                self.actionSucceeded(.providerEnabled(row.identity))
            } catch {
                self.show(error: "\(row.label): \(Self.describe(error))", action: .providerEnabled(row.identity))
            }
        }
    }

    /// The per-provider usage switch: the person turning one provider's
    /// usage read on (after reading the row's own sentence on the card) or
    /// back off. Nothing is asked of the provider until this lands.
    func setUsageConsent(_ row: ProviderRow, _ on: Bool) {
        guard !managing.contains(row.identity) else { return }
        managing.insert(row.identity)
        Task { [weak self] in
            guard let self else { return }
            defer { self.managing.remove(row.identity) }
            do {
                let updated = try await self.core.setProviderUsageConsent(
                    row.id,
                    enabled: on,
                    source: "usage_center",
                    instance: row.instance == "default" ? nil : row.instance
                )
                self.providerRows[updated.identity] = updated
                self.actionSucceeded(.usageConsent(row.identity))
            } catch {
                self.show(error: "\(row.label): \(Self.describe(error))", action: .usageConsent(row.identity))
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
                self.actionSucceeded(.addInstance(row.identity))
                self.loadProviderRows()
            } catch {
                self.show(error: Self.describe(error), action: .addInstance(row.identity))
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
                self.actionSucceeded(.providerAction(provider.identity), message: message)
                self.loadProviderRows()
            } catch {
                self.show(error: Self.describe(error), action: .providerAction(provider.identity))
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
                self.actionSucceeded(.resignIn(provider.identity), message: result.message.isEmpty ? "Re-checking \(provider.id)'s sign-in…" : result.message)
                if let urlString = result.signInURL, let url = URL(string: urlString) {
                    DesktopServices.automatic.open(url)
                }
                self.loadProviderRows()
            } catch {
                self.show(error: Self.describe(error), action: .resignIn(provider.identity))
            }
        }
    }

    // MARK: Fix sign-in

    /// Providers waiting on `provider_sign_in`, keyed by identity — the
    /// button spins while the daemon works (a Claude renewal is a real call
    /// the daemon allows 90 s).
    private(set) var fixingSignIn: Set<String> = []

    /// What the last Fix sign-in click said, on the card where it was
    /// clicked: the daemon's own sentence, kept long enough to read and to
    /// act on (the banner clears after four seconds).
    struct SignInNote: Equatable {
        /// How the sentence reads: a thing that is done, something left for
        /// the person (finish the sign-in in the terminal that opened, read
        /// the advice), or plain information (a staged action's own words).
        enum Tone: Equatable { case done, todo, info }
        let text: String
        let tone: Tone
        var needsPerson: Bool { tone == .todo }
    }
    private(set) var signInNotes: [String: SignInNote] = [:]
    @ObservationIgnored private var signInNoteClear: [String: DispatchWorkItem] = [:]
    /// How long a note stays under its card.
    nonisolated static let signInNoteLife: TimeInterval = 45

    func isFixingSignIn(_ provider: CoreProviderUsage) -> Bool {
        fixingSignIn.contains(provider.identity)
    }

    /// What a Fix sign-in reply is shown as: the daemon's sentence as it is,
    /// or a plain fallback if it sent none.
    nonisolated static func signInNote(for result: ProviderSignInResult) -> SignInNote {
        let words = result.message.trimmingCharacters(in: .whitespacesAndNewlines)
        let tone: SignInNote.Tone = result.outcome == .staged ? .info : (result.outcome.needsPerson ? .todo : .done)
        return SignInNote(text: words.isEmpty ? "Checked \(result.provider)'s sign-in." : words, tone: tone)
    }

    /// "Fix sign-in": asks the daemon to do the best automatic thing for
    /// this provider — re-read what its tooling holds, ask Claude Code to
    /// renew its own sign-in, or open your terminal on the provider's own
    /// login — and shows the sentence it answers with. A click, never run
    /// on open. Afterwards the card is read again; the daemon has already
    /// forced the provider's usage refresh, so the card flips on its own
    /// the moment the new sign-in lands. A `sign_in_url` means the remedy is
    /// a page only the person can sign in to, and it is opened for them.
    func fixSignIn(_ provider: CoreProviderUsage) {
        guard core.isLive, !fixingSignIn.contains(provider.identity) else { return }
        fixingSignIn.insert(provider.identity)
        Task { [weak self] in
            guard let self else { return }
            defer { self.fixingSignIn.remove(provider.identity) }
            do {
                let result = try await self.core.signInProvider(
                    provider.id,
                    instance: provider.instance == "default" ? nil : provider.instance
                )
                self.note(signIn: Self.signInNote(for: result), for: provider.identity)
                if let urlString = result.signInURL, let url = URL(string: urlString) {
                    DesktopServices.automatic.open(url)
                }
                self.loadProviderRows()
            } catch {
                self.note(signIn: SignInNote(text: Self.describe(error), tone: .todo), for: provider.identity)
            }
        }
    }

    private func note(signIn note: SignInNote, for identity: String) {
        signInNotes[identity] = note
        signInNoteClear[identity]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.signInNotes[identity] = nil }
        }
        signInNoteClear[identity] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.signInNoteLife, execute: work)
    }

    /// Revokes one exact consent; the daemon removes the imported
    /// credential only while it is still the imported one.
    @discardableResult
    func revokeConsent(providerID: String, consent: ProviderConsentRow) -> Task<Void, Never> {
        let request = ConsentRevocation(provider: providerID,
            instance: consent.sourceInstanceID == "default" ? nil : consent.sourceInstanceID,
            browser: consent.browser, profile: consent.profile)
        let revoke = revokeProviderConsent
        return Task { [weak self] in
            guard let self else { return }
            do {
                let reply = try await revoke(request)
                if !reply.ok {
                    self.show(error: reply.error?.message ?? "Consent revoke refused", action: .revokeConsent(request))
                    return
                }
                self.actionSucceeded(.revokeConsent(request))
                self.loadProviderRows()
            } catch {
                self.show(error: "Revoke failed: \(Self.describe(error))", action: .revokeConsent(request))
            }
        }
    }

    func show(error: String, action: NoticeAction) {
        notice = Notice(action: action, text: error, isFailure: true)
    }

    func actionSucceeded(_ action: NoticeAction, message: String? = nil) {
        if let notice, notice.isFailure, notice.action != action { return }
        notice = nil
        guard let message, !message.isEmpty else { return }
        let shown = Notice(action: action, text: message, isFailure: false)
        notice = shown
        scheduleNoticeExpiry { [weak self] in
            guard self?.notice?.id == shown.id else { return }
            self?.notice = nil
        }
    }

    func dismissNotice() { notice = nil }

    func copyNotice() {
        guard let notice else { return }
        copyNoticeText(notice.text)
    }

    /// Why the daemon refused a write, or nil when it took it. A refused
    /// `set_setting` is a reply, not a thrown error, and the toolbar must
    /// not keep showing a choice the daemon did not keep.
    nonisolated static func refusal(_ reply: CoreReply) -> String? {
        guard !reply.ok else { return nil }
        return reply.error?.message ?? reply.error?.code ?? "refused"
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
        // A provider that is off says so on its card; the line keeps only
        // who the account is.
        if provider.usageIsOff { return parts.joined(separator: " · ") }
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
