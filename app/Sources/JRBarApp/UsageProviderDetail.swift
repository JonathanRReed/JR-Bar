import JRBarCore
import JRBarUI
import SwiftUI

struct UsageProviderDetail: View {
    let provider: CoreProviderUsage
    @Bindable var store: UsageCenterStore
    let showCost: Bool

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
            UsageGaugeRow(provider: provider, name: store.providerTitle(provider),
                          now: store.now.timeIntervalSince1970, connected: store.isLive,
                          accent: accent, style: .detail, pace: pace,
                          onAction: { store.runProviderAction(provider) },
                          onRetry: quotaRetry)
            if let row = store.row(for: provider.identity) {
                DisclosureGroup("Connection") {
                    UsageProviderConnection(provider: provider, store: store, row: row)
                }
            }
            if let note = store.signInNotes[provider.identity] { SignInNoteLine(note: note) }
            Divider()
            HStack {
                Text(store.metric == .cost && showCost ? "Estimated cost" : "Tokens").font(JRBarTokens.TypeStyle.heading.font)
                Spacer()
                Text(store.range.label).foregroundStyle(JRBarTokens.Ink.secondary)
            }
            if let state = UsageHistoryPresentation.state(provider: provider, history: history,
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
            if !store.tokenHistoryOff, let history, history.records != 0, !history.days.isEmpty || !history.hours.isEmpty {
                if showCost, store.metric == .cost, history.costIsUnpriced {
                    Text("No price for this usage").foregroundStyle(JRBarTokens.Ink.secondary)
                } else {
                    UsageTokenChart(history: history, range: store.range, accent: accent, metric: showCost ? store.metric : .tokens, cache: store.chartCache)
                }

                if showCost {
                    VStack(alignment: .leading, spacing: JRBarTokens.Space.xs) {
                        Text("Estimated cost").font(JRBarTokens.TypeStyle.heading.font)
                        Text(history.costIsUnpriced ? "No price for this usage" : UsageFormat.cost(history.totalCost, currency: history.pricing?.currency ?? "USD"))
                            .font(JRBarTokens.TypeStyle.title1.font).monospacedDigit()
                        Text("List prices, not your invoice").font(JRBarTokens.TypeStyle.caption.font)
                            .foregroundStyle(JRBarTokens.Ink.secondary)
                    }
                }
            }
            Divider()
            Text("Context · open sessions").font(JRBarTokens.TypeStyle.heading.font)
            if sessions.isEmpty {
                Text("No open sessions").foregroundStyle(JRBarTokens.Ink.secondary)
            }
            ForEach(sessions) { session in
                UsageSessionContext(session: session, reading: store.tokenHistoryOff ? nil : store.sessionUsage.usage(for: session.id),
                                    gap: store.tokenHistoryOff ? "Token history is off" : store.sessionUsage.gap(for: session.id), accent: accent)
            }
        }
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
