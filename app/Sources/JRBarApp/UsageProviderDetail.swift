import JRBarCore
import JRBarUI
import SwiftUI

struct UsageProviderDetail: View {
    let provider: CoreProviderUsage
    @Bindable var store: UsageCenterStore
    let showCost: Bool
    @ViewState private var inspectedWindow: CoreUsageWindow?

    private var history: UsageHistory? {
        guard var history = store.history(for: provider) else { return nil }
        if ["stale", "failed", "disk_full", "damaged", "over_cap"].contains(provider.tokenHistoryState ?? "") { history.stale = true }
        return history
    }
    private var accent: Color { ProviderStyle.style(for: provider.id, document: store.document).accent }
    private var sessions: [CoreSession] { store.openSessions.filter { $0.provider == provider.id } }

    private var quotaRetry: (() -> Void)? {
        guard provider.isStale || ["failing", "source_idle", "missing_recent"].contains(provider.availability) else { return nil }
        return { store.refresh() }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: JRBarTokens.Space.xxl) {
            quotaRow
            UsageProviderFactsView(facts: facts, showCost: showCost)
            let referenceWindows = UsageSourceNotes.detailWindows(provider.windows)
            if !referenceWindows.isEmpty {
                UsageDetailWindowsLine(windows: referenceWindows, now: store.now, fix: provider.staleFix)
            }
            ForEach(inspections, id: \.window.id) { inspection in
                UsageForecastSummary(inspection: inspection)
            }
            let burners = store.burners(for: provider)
            if !burners.isEmpty, let window = UsageCenterStore.featuredWindow(of: provider) {
                UsageBurnersView(window: window, burners: burners, open: { store.openBurner($0) })
                if let note = store.burnerOpenNote {
                    Text(note).foregroundStyle(JRBarTokens.Ink.secondary)
                }
            }
            if let row = store.row(for: provider.identity) {
                if provider.actionKind == "manage" {
                    UsageProviderConnection(provider: provider, store: store, row: row)
                } else {
                    DisclosureGroup("Connection") {
                        UsageProviderConnection(provider: provider, store: store, row: row)
                    }
                }
            }
            if let note = store.signInNotes[provider.identity] { SignInNoteLine(note: note) }
            Divider()
            if store.supportsLocalHistory(provider) {
                Text("Local history combines this Mac's configured homes. It is shown once per provider and is not attributed to an account.")
                    .font(JRBarTokens.TypeStyle.caption.font).foregroundStyle(JRBarTokens.Ink.secondary)
            }
            HStack {
                SectionHeader(store.metric == .cost && showCost ? "Estimated cost" : "Tokens")
                Spacer()
                Text(store.range.label).foregroundStyle(JRBarTokens.Ink.secondary)
            }
            if store.ownsLocalHistory(provider), let state = UsageHistoryPresentation.state(provider: provider, history: history,
                disabled: store.tokenHistoryOff, loading: store.isLoading(provider) || store.refreshing,
                scanning: store.isScanning(provider), error: store.error(for: provider)) {
                StatusBanner(state.title, kind: state.failure ? .failure : .information, detail: state.detail) {
                    if store.tokenHistoryOff {
                        Button("Turn on") { store.enableTokenHistory() }.disabled(!store.isLive)
                    } else if state.retry {
                        Button("Retry") { store.load(provider: provider, force: true) }.disabled(!store.isLive)
                    }
                }
            }
            if !store.tokenHistoryOff, store.ownsLocalHistory(provider), let history, history.records != 0, !history.days.isEmpty || !history.hours.isEmpty {
                if showCost, store.metric == .cost, history.costIsUnpriced {
                    Text("No price for this usage").foregroundStyle(JRBarTokens.Ink.secondary)
                } else {
                    UsageTokenChart(history: history, range: store.range, accent: accent, metric: showCost ? store.metric : .tokens, cache: store.chartCache)
                }

                if showCost {
                    VStack(alignment: .leading, spacing: JRBarTokens.Space.xs) {
                        SectionHeader("Estimated cost")
                        Text(history.costIsUnpriced ? "No price for this usage" : UsageFormat.cost(history.totalCost, currency: history.pricing?.currency ?? "USD"))
                            .font(JRBarTokens.TypeStyle.title1.font).monospacedDigit()
                    }
                    Text(UsageCardCopy.pricingDisclosure(history))
                        .font(JRBarTokens.TypeStyle.caption.font).foregroundStyle(JRBarTokens.Ink.secondary)
                    if let share = history.cacheShare {
                        Text("\(Int((share * 100).rounded()))% of input from cache")
                            .font(JRBarTokens.TypeStyle.caption.font).foregroundStyle(JRBarTokens.Ink.secondary)
                    }
                    if let savings = history.cacheSavings, savings > 0 {
                        Text("Cache saved \(history.costsApproximate ? "≈ " : "")\(UsageFormat.cost(savings, currency: history.pricing?.currency ?? "USD"))")
                            .font(JRBarTokens.TypeStyle.caption.font).foregroundStyle(JRBarTokens.Ink.secondary)
                    }
                }
                UsageHistoryDetails(history: history, showCost: showCost)
            }
            Divider()
            SectionHeader("Context · open sessions")
            if sessions.isEmpty {
                Text("No open sessions").foregroundStyle(JRBarTokens.Ink.secondary)
            }
            ForEach(sessions) { session in
                UsageSessionContext(session: session, reading: store.tokenHistoryOff ? nil : store.sessionUsage.usage(for: session.id),
                                    gap: store.tokenHistoryOff ? "Token history is off" : store.sessionUsage.gap(for: session.id), accent: accent)
            }
        }
        .overlay(alignment: .topTrailing) {
            if store.isCelebrating(provider.identity) {
                Label("Window reset", systemImage: "arrow.counterclockwise.circle.fill")
                    .font(JRBarTokens.TypeStyle.caption.font).foregroundStyle(JRBarTokens.Ink.reset)
            }
        }
        .popover(item: WindowPresenter.presentation($inspectedWindow)) { window in
            UsageWindowInspectionView(inspection: inspection(for: window))
        }
    }

    var inspections: [UsageWindowInspection] {
        guard provider.quotaSource, !provider.usageIsOff else { return [] }
        return UsageSourceNotes.ringWindows(provider.windows).map { inspection(for: $0) }
    }

    func inspection(for window: CoreUsageWindow) -> UsageWindowInspection {
        UsageWindowInspection(provider: provider, window: window,
                              forecast: store.forecast(for: provider, window: window), isLive: store.isLive, now: store.now)
    }

    var facts: UsageProviderFacts {
        UsageProviderFacts(provider: provider, history: history, providers: store.providers, isLive: store.isLive, now: store.now)
    }

    var quotaRow: UsageGaugeRow {
        var shown = provider
        shown.windows = UsageSourceNotes.ringWindows(provider.windows)
        return UsageGaugeRow(provider: shown, name: store.providerTitle(provider),
                      now: store.now.timeIntervalSince1970, connected: store.isLive,
                      accent: accent, style: .detail, pace: pace,
                      forecasts: Dictionary(inspections.map { ($0.window.id, $0.displayForecast) }, uniquingKeysWith: { first, _ in first }),
                      onInspect: { inspectedWindow = $0 },
                      onAction: { store.runProviderAction(provider) }, onRetry: quotaRetry)
    }

    private var pace: [String: Double] { store.quotaPace(for: provider) }

}

/// Cache status describes local history, independently of quota collection.
enum UsageHistoryPresentation {
    struct State: Equatable {
        let title: String
        let detail: String?
        var failure = false
        var retry = false
    }

    static func state(provider: CoreProviderUsage, history: UsageHistory?, disabled: Bool,
                      loading: Bool, scanning: Bool, error: String?) -> State? {
        if disabled { return State(title: "Token history is off", detail: nil) }
        switch provider.tokenHistoryState {
        case "disk_full": return State(title: "Disk full", detail: "Free space to resume token history. Last totals stay visible.", failure: true)
        case "damaged": return State(title: "Token history needs repair", detail: "The cache is damaged. Recovery will retry from local transcripts.", failure: true, retry: true)
        case "over_cap": return State(title: "Token history reached its size limit", detail: "Local token history exceeded its 4 GB cache limit. Last totals stay visible.", failure: true)
        case "failed": return State(title: "Token history refresh failed", detail: error ?? "Showing the last totals.", failure: true, retry: true)
        case "building": return State(title: "Building token history", detail: "Showing records read so far.")
        case "stale": return State(title: "Token history is stale", detail: "Showing the last totals.", retry: true)
        default: break
        }
        if let error { return State(title: "Token history refresh failed", detail: error, failure: true, retry: true) }
        if scanning || history?.partial == true || (history?.readingFiles ?? 0) > 0 {
            return State(title: "Scanning local history", detail: "Showing records read so far.")
        }
        if history?.stale == true { return State(title: "Token history is stale", detail: "Showing the last totals.", retry: true) }
        if loading { return State(title: "Refreshing token history", detail: nil) }
        if history == nil || history?.records == 0 || (history?.days.isEmpty == true && history?.hours.isEmpty == true) {
            return State(title: "No token history yet", detail: "Local session records will appear here.")
        }
        return nil
    }
}

struct UsageSessionContext: View {
    let session: CoreSession
    let reading: SessionUsage?
    let gap: String?
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: JRBarTokens.Space.sm) {
            HStack {
                Text(session.displayLabel).lineLimit(1)
                Spacer()
                if let tokens = reading?.contextTokens, let window = reading?.contextWindow, window > 0 {
                    Text("\(UsageFormat.tokens(tokens)) / \(UsageFormat.tokens(window))")
                        .monospacedDigit().foregroundStyle(JRBarTokens.Ink.secondary)
                        .accessibilityLabel("Context: \(tokens) of \(window) tokens")
                } else {
                    Text(gap ?? "No context reading").font(JRBarTokens.TypeStyle.caption.font)
                        .foregroundStyle(JRBarTokens.Ink.secondary)
                }
            }
            if let tokens = reading?.contextTokens, let window = reading?.contextWindow, window > 0 {
                JRBarGauge(value: Double(tokens) / Double(window) * 100, tint: accent, height: 6)
            }
        }
    }
}

struct UsageForecastSummary: View {
    let inspection: UsageWindowInspection

    var body: some View {
        VStack(alignment: .leading, spacing: JRBarTokens.Space.sm) {
            HStack(spacing: JRBarTokens.Space.sm) {
                Text(inspection.window.longName).font(JRBarTokens.TypeStyle.headline.font)
                if inspection.showsVerdict {
                    StatusBadge(inspection.verdictText, tint: inspection.verdictColor)
                        .preference(key: UsageForecastEvidence.self, value: [inspection.window.id + ".verdict": inspection.displayForecast])
                }
            }
            Text(inspection.summaryText).font(JRBarTokens.TypeStyle.callout.font)
                .preference(key: UsageForecastEvidence.self, value: [inspection.window.id + ".headline": inspection.displayForecast])
                .fixedSize(horizontal: false, vertical: true)
            if let projected = inspection.projectedText {
                Text(projected).font(JRBarTokens.TypeStyle.caption.font).foregroundStyle(JRBarTokens.Ink.secondary)
            }
            if let evidence = inspection.forecastEvidence {
                Text(evidence).font(JRBarTokens.TypeStyle.caption.font).foregroundStyle(JRBarTokens.Ink.secondary)
            }
            if inspection.readingNotice == nil,
               let room = SessionAwarePace.roomText(inspection.displayForecast, now: inspection.now.timeIntervalSince1970) {
                Text(room).font(JRBarTokens.TypeStyle.caption.font).foregroundStyle(JRBarTokens.Ink.secondary)
            }
            if let budget = inspection.budget { UsageResetBudgetView(budget: budget) }
        }
        .accessibilityElement(children: .combine)
    }
}
