import Charts
import JRBarCore
import SwiftUI

/// The Usage Center: one card per provider with its quota windows as
/// rings, the forecast line, a Swift Charts history and the cost estimate.
struct UsageCenterView: View {
    @Bindable var store: UsageCenterStore

    var body: some View {
        Group {
            if !store.isLive {
                WindowEmptyState(symbol: "bolt.horizontal.circle", title: "Monitor not connected",
                                 text: "Usage comes from the monitor. The cards fill in as soon as the socket is live.",
                                 tint: .orange)
            } else if store.providers.isEmpty {
                WindowEmptyState(symbol: "chart.xyaxis.line", title: "No usage yet",
                                 text: "No provider has reported a quota window. Metering is turned on from Settings › Usage.",
                                 actionTitle: "Open Usage settings…", action: { store.openUsageSettings() })
            } else {
                ScrollViewReader { proxy in
                    SnapshotScrollView {
                        LazyVStack(spacing: 16) {
                            statusLine
                            if store.providers.count > 1 {
                                CombinedUsageCard(providers: store.providers, store: store)
                            }
                            // Keyed by identity: two accounts of one provider
                            // (a hub account beside the local one) share `id`,
                            // and a ForEach keyed by `id` drew the first twice.
                            ForEach(store.providers, id: \.identity) { provider in
                                ProviderUsageCard(provider: provider, store: store)
                                    .id(provider.identity)
                            }
                        }
                        .padding(WindowMetrics.margin)
                    }
                    // The panel's per-provider drill: scroll the card into
                    // view and flash it. `focusPulses` is the trigger so a
                    // repeat click on the same provider still scrolls; the
                    // focus is consumed so a later plain open does not
                    // re-scroll to it.
                    .onChange(of: store.focusPulses) {
                        guard let target = store.focusProvider else { return }
                        store.focusProvider = nil
                        // `focusProvider` is already an identity (see
                        // UsageCenterStore.focus) so a duplicate provider
                        // id scrolls to a real card either way.
                        if store.reduceMotion {
                            proxy.scrollTo(target)
                        } else {
                            withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(target) }
                        }
                    }
                    // A focus set before the window existed (panel drill
                    // opening the Usage Center for the first time) still
                    // scrolls, once the cards are laid out.
                    .onAppear {
                        guard let target = store.focusProvider else { return }
                        store.focusProvider = nil
                        DispatchQueue.main.async { proxy.scrollTo(target) }
                    }
                }
            }
        }
        .frame(minWidth: 640, minHeight: 440)
        .background(Color(nsColor: .windowBackgroundColor))
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Range", selection: $store.range) {
                    ForEach(UsageHistoryRange.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .help("How far back the graph and the cost estimate reach")
            }
            ToolbarItem(placement: .automatic) {
                Picker("Metric", selection: $store.metric) {
                    ForEach(UsageCenterStore.Metric.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .help("Graph tokens or the estimated cost")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    store.refresh()
                } label: {
                    if store.refreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(!store.isLive || store.refreshing)
                .help("Ask the monitor to re-read every provider (⌘R)")
                .keyboardShortcut("r", modifiers: .command)
            }
        }
        .overlay(alignment: .bottom) {
            if let error = store.lastError {
                WindowStatusCapsule(text: error, isError: true)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: store.lastError == nil)
    }

    private var statusLine: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 9, weight: .semibold))
            if let at = store.refreshedAt, let elapsed = PanelStore.elapsed(since: at, now: store.now) {
                Text("Updated \(elapsed) ago")
            } else {
                Text("Waiting for the first usage read")
            }
            Spacer()
            Text("Costs are estimates from list prices, not invoices")
        }
        .font(.caption)
        .foregroundStyle(.tertiary)
        .monospacedDigit()
        .padding(.horizontal, 4)
    }
}

// MARK: - Card

struct ProviderUsageCard: View {
    let provider: CoreProviderUsage
    @Bindable var store: UsageCenterStore

    private var style: ProviderStyle { ProviderStyle.style(for: provider.id, document: store.document) }
    private var history: UsageHistory? { store.history(for: provider) }
    private var celebrating: Bool { store.isCelebrating(provider.id) }
    /// The panel drilled straight here: the same accent flash as
    /// `quota_reset`, without the "Window reset" badge.
    private var focused: Bool { store.isFocused(provider) }
    private var flashing: Bool { celebrating || focused }
    /// The window the card leads with: the daemon's constrained pick when
    /// it names one, else the 5h convention (S6.4).
    private var primary: CoreUsageWindow? { UsageCenterStore.featuredWindow(of: provider) }
    /// The name-convention window — the pick the explanation compares
    /// against before it needs defending.
    private var conventional: CoreUsageWindow? { UsageCenterStore.conventionalWindow(of: provider) }
    /// Two accounts of one provider get an instance badge so the cards
    /// are not twins with no way to tell them apart.
    private var duplicated: Bool { store.providers.filter { $0.id == provider.id }.count > 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if provider.isSignedOut {
                SignedOutRow(provider: provider, name: style.name, store: store)
            } else if provider.windows.isEmpty {
                Text(noWindowsLine).font(.callout).foregroundStyle(.secondary)
            } else {
                // Rings on the left, the reading on the right, so the card
                // does not leave half its width empty.
                HStack(alignment: .top, spacing: 18) {
                    windows
                    forecastLine
                        .frame(maxWidth: 320, alignment: .leading)
                        .padding(.top, 6)
                }
                let detail = UsageSourceNotes.detailWindows(provider.windows)
                if !detail.isEmpty {
                    UsageDetailWindowsLine(windows: detail, now: store.now, fix: provider.staleFix)
                }
            }
            if let readings = readingsLine {
                Text(readings)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let row = store.row(for: provider.identity) {
                Divider().opacity(0.6)
                connectionSection(row)
            }
            // A hub account's card has no graph: the token history is this
            // Mac's own transcripts, which belong to the local card.
            if !provider.isSignedOut && !UsageSourceNotes.isHubInstance(provider.instance) {
                Divider().opacity(0.6)
                historySection
            }
        }
        // The quota_reset / focus flourish: a brief wash of the accent
        // that fades out.
        .windowCard(padding: 18, highlight: flashing ? style.accent : nil)
        .overlay(alignment: .topTrailing) {
            if celebrating {
                Label("Window reset", systemImage: "arrow.counterclockwise.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(style.accent)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(style.accent.opacity(0.14), in: Capsule())
                    .padding(12)
                    .transition(store.reduceMotion ? .opacity : .scale(scale: 0.8).combined(with: .opacity))
            }
        }
        .animation(store.reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.45, dampingFraction: 0.75), value: flashing)
        .accessibilityElement(children: .contain)
    }

    /// The inspect/manage row: the enabled toggle, the daemon's current
    /// fix-it action as a working button, and any granted browser
    /// consents with a working revoke. All of it is the daemon's own
    /// `list_providers`/`provider_consent`/`provider_action` truth.
    @ViewBuilder
    private func connectionSection(_ row: ProviderRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Toggle(
                    "Metering",
                    isOn: Binding(
                        get: { row.enabled },
                        set: { store.setProviderEnabled(row, $0) }
                    )
                )
                .controlSize(.small)
                .toggleStyle(.checkbox)
                .help("Enable or disable this provider's quota collection")
                if let action = provider.action, !action.isEmpty {
                    Button(action) { store.runProviderAction(provider) }
                        .controlSize(.small)
                        .help(provider.reason?.replacingOccurrences(of: "_", with: " ") ?? action)
                }
                ResignInButton(provider: provider, store: store)
                Spacer()
                if row.supportsInstances {
                    AddAccountButton(providerID: provider.id, row: row, store: store)
                }
                if row.importedCredential {
                    Text("imported session")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .help("This credential came from a consented browser import; revoking the consent removes it while it is still the imported value.")
                }
            }
            if !row.consents.isEmpty {
                ForEach(Array(row.consents.enumerated()), id: \.offset) { _, consent in
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.shield")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("\(consent.browser) · \(consent.profile)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(consent.fields.joined(separator: ", "))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Button("Revoke") { store.revokeConsent(providerID: provider.id, consent: consent) }
                            .controlSize(.mini)
                            .help("Stop every future read of \(consent.browser) \(consent.profile); imported data is removed only while it is still the imported value")
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            ProviderTile(style: style, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(style.name).font(.title3.weight(.semibold))
                    if duplicated, let instance = provider.instance, !instance.isEmpty, instance != "default" {
                        Text(UsageSourceNotes.instanceBadge(instance))
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.primary.opacity(0.08), in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                    if let badge = stateBadge {
                        Text(badge.text)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(badge.color.opacity(0.15), in: Capsule())
                            .foregroundStyle(badge.color)
                    }
                    if let incident = provider.incident, !incident.isEmpty {
                        Text("Incident")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.15), in: Capsule())
                            .foregroundStyle(.orange)
                            .help("The provider's status feed reports: \(incident)")
                    }
                }
                Text(accountText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let primary {
                VStack(alignment: .trailing, spacing: 1) {
                    Text((provider.isDerived && !primary.isUnknown ? "~" : "") + primary.percentText)
                        .font(.system(size: 26, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(UsageColors.level(primary.usedPct, accent: style.accent))
                        .contentTransition(.numericText())
                        .help(primary.isUnknown ? "\(style.name) reports this window without a number" : "")
                    Text(UsageCenterStore.headlineResetLine(primary, of: provider, now: store.now))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                    // The pick explains itself when it is not the window
                    // the 5h convention would have led with (S6.4).
                    if let constrained = provider.constrained, primary.id != conventional?.id {
                        Text("Watching it — \(constrained.explanation)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .animation(PanelMotion.crossfade(reduced: store.reduceMotion), value: primary.usedPct)
            }
        }
    }

    /// The account line, with where the numbers came from when that is not
    /// the provider's own endpoint ("Max 20× · official · via Claude Code").
    private var accountText: String {
        let line = UsageCenterStore.accountLine(provider, history: history)
        guard let caption = UsageSourceNotes.sourceCaption(provider) else { return line }
        return line + " · " + caption
    }

    private var stateBadge: (text: String, color: Color)? {
        if provider.isSignedOut { return ("Not signed in", .secondary) }
        switch provider.state?.lowercased() {
        case "warning": return ("Near limit", .orange)
        case "exhausted", "blocked", "limited": return ("Limited", .red)
        case "stale": return ("Stale", .secondary)
        case "disabled", "off": return ("Off", .secondary)
        case "source_not_found", "error", "unavailable": return ("Needs setup", .orange)
        default: return nil
        }
    }

    /// The provider's own counters as one caption under the rings: tokens
    /// counted at the snapshot's `observed_at`, the daemon's cost estimate
    /// ("est." — the disclosure's own word, an estimate and never an
    /// invoice), a credit balance when the provider banks in credits, and
    /// how old the reading is. Every part rides `fidelity`/`state`: a
    /// stale card keeps its "Stale" badge and this line still names the
    /// reading's age rather than posing as current.
    private var readingsLine: String? {
        guard !provider.isSignedOut else { return nil }
        var parts: [String] = []
        if let tokens = provider.tokens, tokens.total > 0 {
            var text = "\(UsageFormat.tokens(tokens.total)) tokens"
            if tokens.cachedInput > 0 { text += " · \(UsageFormat.tokens(tokens.cachedInput)) from cache" }
            parts.append(text)
        }
        if let cost = provider.estimatedCostUSD, cost > 0 {
            parts.append("≈ \(UsageFormat.cost(cost)) est.")
        }
        if let credits = provider.creditsRemaining, credits >= 0 {
            parts.append("\(UsageFormat.grouped(credits)) credits left")
        }
        if let resets = UsageSourceNotes.resetCreditsText(provider.resetCredits) {
            parts.append(resets)
        }
        if let observedAt = provider.observedAt,
           let age = PanelStore.elapsed(since: Date(timeIntervalSince1970: observedAt), now: store.now) {
            parts.append("read \(age) ago")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// What stands in for the rings when the daemon reports no window: the
    /// state word's own sentence, not a flat "nothing here".
    private var noWindowsLine: String {
        if let line = UsageSourceNotes.noQuotaLine(provider, name: style.name) { return line }
        switch provider.state?.lowercased() {
        case "disabled", "off":
            return "Turned off: the monitor is not collecting \(style.name) usage."
        case "source_not_found", "error", "unavailable":
            return provider.action.map { "\($0) to see quota windows here." }
                ?? "The monitor could not read \(style.name)'s usage source."
        default:
            return "No quota window reported yet."
        }
    }

    /// The primary window leads, so the ring under the headline percent is
    /// the one the headline is about; the rest keep the daemon's order.
    private var orderedWindows: [CoreUsageWindow] {
        let rings = UsageSourceNotes.ringWindows(provider.windows)
        guard let primary, let index = rings.firstIndex(of: primary), index != 0 else { return rings }
        var windows = rings
        windows.remove(at: index)
        return [primary] + windows
    }

    private var windows: some View {
        HStack(alignment: .top, spacing: 14) {
            ForEach(orderedWindows) { window in
                QuotaRing(window: window, forecast: store.forecast(for: provider, window: window), accent: style.accent,
                          now: store.now, reduced: store.reduceMotion,
                          reset: UsageCenterStore.resetText(window, of: provider, now: store.now))
            }
        }
    }

    private var forecastLine: some View {
        let window = primary ?? provider.windows[0]
        let forecast = store.forecast(for: provider, window: window)
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: forecast.isCritical ? "exclamationmark.triangle.fill" : (isQuiet(forecast.verdict) ? "questionmark.circle" : "checkmark.circle"))
                .foregroundStyle(forecast.isCritical ? Color.orange : Color.secondary)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                // The verdict first, as a word you can read across the
                // room; the sentence after it says why.
                Text(forecast.verdictWord())
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Self.verdictTint(forecast).opacity(0.15), in: Capsule())
                    .foregroundStyle(Self.verdictTint(forecast))
                Text(forecast.headline(now: store.now))
                    .font(.callout.weight(forecast.isCritical ? .medium : .regular))
                    .foregroundStyle(forecast.isCritical ? .primary : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(forecastSource(forecast))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                burnersList(window: window)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Amber for a run-out, red for used up, the provider's accent for a
    /// reset that comes first, grey for "no pace" states.
    static func verdictTint(_ forecast: UsageForecast) -> Color {
        switch forecast.verdict {
        case .exhausted: return .red
        case .runsOut: return .orange
        case .comfortable: return forecast.heldIdle ? .secondary : .green
        case .unknown, .guarded, .unmeasured: return .secondary
        }
    }

    /// "Burning this window": this Mac's sessions of the provider ranked by
    /// what they spent since the headline window opened — the share is of
    /// what this Mac can see, never of the provider's percentage.
    @ViewBuilder
    private func burnersList(window: CoreUsageWindow) -> some View {
        let burners = store.burners(for: provider)
        if !burners.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text("Burning the \(window.shortName) window here")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
                ForEach(burners) { burner in
                    HStack(spacing: 6) {
                        Text(burner.label)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 150, alignment: .leading)
                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.primary.opacity(0.07))
                                Capsule().fill(style.accent.opacity(0.6))
                                    .frame(width: max(2, proxy.size.width * burner.share))
                            }
                        }
                        .frame(width: 70, height: 4)
                        Text("\(Int((burner.share * 100).rounded()))% · \(UsageFormat.tokens(burner.tokens))")
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(Color.secondary)
                    }
                    .help("\(burner.label): \(UsageFormat.tokens(burner.tokens)) tokens since the \(window.longName) window opened — \(Int((burner.share * 100).rounded()))% of what this Mac's \(style.name) sessions spent in it")
                }
            }
        }
    }

    /// Verdicts that mean "no number to show" rather than a pace: the
    /// question-mark icon, never the green check.
    private func isQuiet(_ verdict: UsageForecast.Verdict) -> Bool {
        switch verdict {
        case .unknown, .unmeasured, .guarded: return true
        default: return false
        }
    }

    private func forecastSource(_ forecast: UsageForecast) -> String {
        var parts: [String] = []
        if forecast.verdict == .unmeasured {
            // Nothing to pace: the window is real and its balance was never
            // stated, which is a fact about the provider, not a wait.
            return "\(ProviderStyle.style(for: provider.id, document: store.document).name) reports this window without a number"
        }
        switch forecast.source {
        case .daemon: parts.append("Monitor forecast")
        case .local: parts.append("Estimated from the last 45 minutes")
        case .none: parts.append("A pace needs two readings a minute apart")
        }
        if let rate = forecast.rateText { parts.append("burning \(rate)") }
        if let hint = PanelStore.paceHint(forecast.pace), !forecast.heldIdle { parts.append(hint) }
        if let working = forecast.workingAgents, working > 0 {
            parts.append("\(working) agent\(working == 1 ? "" : "s") working here")
        }
        if let room = SessionAwarePace.roomText(forecast, now: store.now.timeIntervalSince1970) { parts.append(room) }
        return parts.joined(separator: " · ")
    }

    // MARK: History

    @ViewBuilder
    private var historySection: some View {
        let title = store.metric == .tokens ? "Tokens" : "Estimated cost"
        let unit = store.range == .week && !(history?.hours.isEmpty ?? true) ? "by hour" : "by day"
        WindowSectionTitle(title: "\(title) \(unit)", symbol: "chart.xyaxis.line") {
            if let history, !history.isEmpty {
                Text(totalsLine(history))
            }
        }
        let scanning = store.isScanning(provider)
        if let error = store.error(for: provider), history == nil {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                Text(error).font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Retry") { store.load(provider: provider, force: true) }.controlSize(.small)
            }
            .padding(.vertical, 12)
        } else if store.hasNoLocalRecords(provider) {
            // The scan finished and found nothing to read on this Mac: say
            // so, rather than drawing thirty days of zero. (The daemon pads
            // its answer with a row per day either way, so this has to be
            // asked before the chart.)
            NoLocalRecordsHint(style: style, provider: provider)
        } else if let history, !history.isEmpty {
            UsageChart(history: history, range: store.range, metric: store.metric, accent: style.accent)
                .frame(height: 170)
            if scanning { ScanningNote() }
            costRow(history)
            if !history.models.isEmpty {
                UsageModelBreakdown(history: history, metric: store.metric, accent: style.accent)
            }
            if history.hours.contains(where: { $0.totalTokens > 0 }) {
                UsagePunchCardView(history: history, accent: style.accent, window: primary, now: store.now)
            }
            if !history.activeDaysNewestFirst.isEmpty {
                UsageDailyTable(history: history)
            }
        } else if store.isLoading(provider) || scanning || history == nil {
            UsageSkeleton(scanning: scanning)
        } else {
            Text("Nothing recorded in this range.")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, minHeight: 80)
        }
    }

    /// The `≈` a dollar figure earns while any of it is priced at a
    /// stand-in rate — dropped when every counted record priced from
    /// its own table row.
    private func approxPrefix(_ history: UsageHistory) -> String {
        history.costsApproximate ? "≈ " : ""
    }

    private func totalsLine(_ history: UsageHistory) -> String {
        let tokens = UsageFormat.tokens(history.totalTokens)
        let cost = UsageFormat.cost(history.totalCost, currency: history.pricing?.currency ?? "USD")
        return "\(tokens) tokens · \(approxPrefix(history))\(cost)"
    }

    private func costRow(_ history: UsageHistory) -> some View {
        let currency = history.pricing?.currency ?? "USD"
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(approxPrefix(history))\(UsageFormat.cost(history.totalCost, currency: currency))")
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                Text("over \(store.range.days) days")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                if let savings = history.cacheSavings, savings > 0, let share = history.cacheShare {
                    HStack(spacing: 5) {
                        Image(systemName: "leaf.fill").foregroundStyle(.green)
                        Text("Cache saved \(approxPrefix(history))\(UsageFormat.cost(savings, currency: currency)) · \(Int((share * 100).rounded()))% of input from cache")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("What the cache reads would have cost at the input price, minus what they cost at the cache price")
                }
            }
            Text(Self.pricingDisclosure(history))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    static func pricingDisclosure(_ history: UsageHistory) -> String {
        guard let pricing = history.pricing else { return "Approximate: the monitor reported no price table for this provider." }
        var text: String
        if pricing.estimated {
            text = "Approximate: list prices"
            if let input = pricing.inputPerMillion, let output = pricing.outputPerMillion {
                text += String(format: " (%@%.2f in / %@%.2f out per M tokens", UsageFormat.currencySymbol(pricing.currency), input, UsageFormat.currencySymbol(pricing.currency), output)
                if let cache = pricing.cacheReadPerMillion { text += String(format: ", %@%.2f cache", UsageFormat.currencySymbol(pricing.currency), cache) }
                text += ")"
            }
            if let model = pricing.model { text += " for \(model)" }
            if let asOf = pricing.asOf { text += ", as of \(asOf)" }
            text += "."
            text += " This model has no table row — priced at the provider's reference rate."
        } else {
            text = "List price"
            if let model = pricing.model { text += " for \(model)" }
            if let input = pricing.inputPerMillion, let output = pricing.outputPerMillion {
                text += String(format: ": %@%.2f in / %@%.2f out", UsageFormat.currencySymbol(pricing.currency), input, UsageFormat.currencySymbol(pricing.currency), output)
                if let cache = pricing.cacheReadPerMillion { text += String(format: " / %@%.2f cache", UsageFormat.currencySymbol(pricing.currency), cache) }
                text += " per M tokens"
            }
            if let asOf = pricing.asOf { text += ", as of \(asOf)" }
            text += "."
        }
        if history.unpricedRecords > 0 {
            let models = history.unpricedModels.isEmpty ? "" : " (\(history.unpricedModels.joined(separator: ", ")))"
            text += " \(history.unpricedRecords) record\(history.unpricedRecords == 1 ? "" : "s")\(models) ha\(history.unpricedRecords == 1 ? "s" : "ve") no price — their tokens are counted but add no dollars."
        }
        return text + " Subscription plans are not billed per token."
    }
}

struct SignedOutRow: View {
    let provider: CoreProviderUsage
    let name: String
    @Bindable var store: UsageCenterStore

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "terminal")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.secondary)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 6) {
                Text("Sign in via the CLI").font(.callout.weight(.medium))
                Text("The monitor reads \(name)'s quota from the CLI's own login. Run its login command in a terminal and the windows appear here on the next refresh.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    // Claude's plan-limit read is consent-gated in the
                    // settings document, not behind a CLI login.
                    if provider.id == "claude", !store.claudePlanLimitsEnabled {
                        Button("Turn on plan limits") { store.enableClaudePlanLimits() }
                            .controlSize(.small)
                            .help("Writes claude_plan_limits_enabled so the monitor may read Claude's plan-limit source")
                    }
                    ResignInButton(provider: provider, store: store)
                    Button("Usage settings…") { store.openUsageSettings() }
                        .controlSize(.small)
                        .help("Opens Settings › Usage, where metering per provider lives")
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Combined view

/// Every provider's quota in one glance — the "view all of my combined
/// usage" surface: one compact row per provider with every window it
/// reports, the fleet's tightest lane named at the top, and the token /
/// cost totals across providers at the bottom. Tapping a row scrolls to
/// that provider's card below.
struct CombinedUsageCard: View {
    let providers: [CoreProviderUsage]
    @Bindable var store: UsageCenterStore

    /// The lane worth the headline: the highest used-percent across every
    /// provider's applicable, measured windows — the daemon's per-provider
    /// `constrained` rule applied across all of them.
    static func worstLane(in providers: [CoreProviderUsage]) -> (provider: CoreProviderUsage, window: CoreUsageWindow)? {
        var worst: (CoreProviderUsage, CoreUsageWindow)?
        for provider in providers {
            for window in provider.windows where window.bindable && window.usedPct != nil {
                if worst == nil || (window.usedPct ?? 0) > (worst?.1.usedPct ?? 0) {
                    worst = (provider, window)
                }
            }
        }
        return worst
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            WindowSectionTitle(title: "All providers", symbol: "square.stack.3d.up") {
                if let worst = Self.worstLane(in: providers) {
                    let style = ProviderStyle.style(for: worst.provider.id, document: store.document)
                    HStack(spacing: 4) {
                        Text("Tightest")
                        Text("\(style.name) \(worst.window.shortName) \(worst.window.percentText)")
                            .fontWeight(.semibold)
                            .foregroundStyle(UsageColors.level(worst.window.usedPct, accent: style.accent))
                    }
                    .help("The tightest window any provider reports — \(worst.window.longName)")
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                ForEach(providers, id: \.identity) { provider in
                    row(provider)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if let totals = totalsLine {
                Divider().opacity(0.6)
                Text(totals)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .windowCard()
        .accessibilityElement(children: .contain)
    }

    /// "182K tokens · ≈ $4.12 est. across providers" — the sums only name
    /// what providers actually reported; a provider without counters adds
    /// nothing rather than an implied zero that looks measured.
    private var totalsLine: String? {
        let tokens = providers.reduce(0) { $0 + ($1.tokens?.total ?? 0) }
        let cost = providers.reduce(0.0) { $0 + ($1.estimatedCostUSD ?? 0) }
        var parts: [String] = []
        if tokens > 0 { parts.append("\(UsageFormat.tokens(tokens)) tokens") }
        if cost > 0 { parts.append("≈ \(UsageFormat.cost(cost)) est.") }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ") + " across providers"
    }

    /// A row with no windows names why: no quota source at all, or the
    /// daemon's state word.
    static func emptyRowWord(_ provider: CoreProviderUsage) -> String {
        guard provider.quotaSource else { return "no quota source" }
        return provider.state?.replacingOccurrences(of: "_", with: " ") ?? "no quota windows"
    }

    /// One provider: its tile and name, then each window as its short
    /// name, a slim continuous bar and the percent, and the leading
    /// window's reset.
    private func row(_ provider: CoreProviderUsage) -> some View {
        let style = ProviderStyle.style(for: provider.id, document: store.document)
        let leading = UsageCenterStore.primaryWindow(of: provider)
        return HStack(spacing: 10) {
            ProviderTile(style: style, size: 20)
            VStack(alignment: .leading, spacing: 0) {
                Text(style.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let tag = UsageSourceNotes.rowTag(provider.instance) {
                    Text(tag)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(width: 104, alignment: .leading)
            if provider.isSignedOut {
                Text("not signed in")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                ResignInButton(provider: provider, store: store)
            } else if provider.windows.isEmpty {
                Text(Self.emptyRowWord(provider))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer(minLength: 4)
            } else {
                // Windows keep their columns across rows: the daemon lists
                // them in the same order for every provider.
                HStack(spacing: 14) {
                    ForEach(UsageSourceNotes.ringWindows(provider.windows).prefix(3)) { window in
                        CombinedWindowGauge(window: window, accent: style.accent)
                    }
                }
                Spacer(minLength: 4)
                Text(UsageCenterStore.resetText(leading, of: provider, now: store.now) ?? "")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .frame(width: 84, alignment: .trailing)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: WindowMetrics.controlRadius, style: .continuous)
            .fill(Color.primary.opacity(0.0001)))
        .contentShape(Rectangle())
        .onTapGesture { store.focus(provider: provider.identity) }
        .help("Scroll to \(style.name)'s card")
        .accessibilityAddTraits(.isButton)
    }
}

/// One window in the combined card: "5h", a slim continuous bar in the
/// level colour and the percent — the panel's quota bar in miniature.
struct CombinedWindowGauge: View {
    let window: CoreUsageWindow
    let accent: Color

    static let barWidth: CGFloat = 40

    private var color: Color { UsageColors.level(window.usedPct, accent: accent) }

    var body: some View {
        HStack(spacing: 5) {
            Text(window.shortName)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 40, alignment: .trailing)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                if let used = window.usedPct {
                    Capsule()
                        .fill(LinearGradient(colors: [color.opacity(0.7), color], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(3, Self.barWidth * CGFloat(min(100, max(0, used)) / 100)))
                }
            }
            .frame(width: Self.barWidth, height: 4)
            Text(window.percentText)
                .font(.caption.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(window.usedPct == nil ? Color.secondary : color)
                .frame(width: 34, alignment: .trailing)
        }
        .help("\(window.longName) window: \(window.spokenPercent)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(window.longName) \(window.spokenPercent)")
    }
}

/// The per-provider "Re-sign in" / "Update provider" button (T3 Code's
/// pattern): asks the daemon to re-pull whatever sign-in the provider's
/// own tooling holds and forces a refresh. The daemon's reply — shown in
/// the window's banner — says what actually happened, including the
/// provider's own remedy when only its CLI or a page can sign in.
struct ResignInButton: View {
    let provider: CoreProviderUsage
    @Bindable var store: UsageCenterStore

    var body: some View {
        Button {
            store.resignIn(provider)
        } label: {
            if store.isResigningIn(provider) {
                ProgressView().controlSize(.small)
            } else {
                Label("Re-sign in", systemImage: "arrow.clockwise")
            }
        }
        .controlSize(.small)
        .disabled(store.isResigningIn(provider) || !store.isLive)
        .help(Self.help(for: provider.id))
    }

    /// What the click actually does for this provider — honest about who
    /// owns the sign-in, so a CLI-owned one never pretends JR-Bar can
    /// re-auth it.
    static func help(for providerID: String) -> String {
        switch providerID {
        case "claude":
            return "Re-read Claude Code's sign-in from the Keychain, then refresh"
        case "codex":
            return "Rescan the Codex CLI's sign-in and sessions, then refresh"
        case "grok":
            return "Re-read the grok CLI's sign-in, then refresh"
        case "devin":
            return "Re-import the consented browser session, then refresh"
        case "openai-api":
            return "Store a copied OpenAI Admin key (read only when you click), then refresh"
        case "gemini", "antigravity", "opencode", "cursor":
            return "Re-check and refresh — the sign-in itself belongs to this provider's own app or CLI"
        default:
            return "Re-check this provider's sign-in and refresh its usage"
        }
    }
}

/// The "Add account" affordance — only offered where the daemon says a
/// second configured instance could read a *different* account (a stored
/// credential or a consented browser session). A popover keeps it light:
/// an instance slug plus an optional display label.
struct AddAccountButton: View {
    let providerID: String
    let row: ProviderRow
    @Bindable var store: UsageCenterStore
    // `ViewState`, not `@State` — the Command Line Tools ship no
    // SwiftUIMacros plugin; the alias names the wrapper directly.
    @ViewState private var open = false
    @ViewState private var instance = ""
    @ViewState private var label = ""

    var body: some View {
        Button {
            open.toggle()
        } label: {
            Label("Add account", systemImage: "plus")
        }
        .controlSize(.small)
        .disabled(!store.isLive)
        .help("Meter a second \(providerID) account — its credential or browser consent is what keeps it from mirroring this one")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Add a \(providerID) account")
                    .font(.headline)
                Text("The instance id distinguishes the account — \"work\", \"personal\". The account's own credential or consented browser session is set up next, from its card's manage row.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 260)
                TextField("Instance id (e.g. work)", text: $instance)
                    .textFieldStyle(.roundedBorder)
                TextField("Label (optional)", text: $label)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Spacer()
                    Button("Cancel") { open = false }
                        .controlSize(.small)
                    Button("Add") {
                        let slug = Self.slug(instance)
                        guard !slug.isEmpty else { return }
                        store.addProviderInstance(row, instance: slug,
                                                  label: label.isEmpty ? nil : label)
                        open = false
                        instance = ""
                        label = ""
                    }
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
                    .disabled(Self.slug(instance).isEmpty)
                }
            }
            .padding(14)
        }
    }

    /// The instance id as the daemon expects it — lowercase slug.
    static func slug(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }
}

// MARK: - Ring

struct QuotaRing: View {
    let window: CoreUsageWindow
    let forecast: UsageForecast
    let accent: Color
    let now: Date
    let reduced: Bool
    /// The window's reset in words (`UsageCenterStore.resetText`): a
    /// countdown, or a broken source's fix once the reset is past; nil
    /// when the window names no reset.
    let reset: String?

    /// Nil when the window has no reading: the ring is drawn as a hairline
    /// round a dash, never as an arc of zero.
    private var fraction: Double? { window.usedPct.map { min(1, max(0, $0 / 100)) } }
    private var color: Color { UsageColors.level(window.usedPct, accent: accent) }
    /// The arc deepens from its start to its tip. The shading begins a
    /// little before twelve o'clock so the start's round cap takes the
    /// start's colour; a nearly full ring is one colour, since its tip
    /// would wrap round into that shading.
    private func arcShading(_ fraction: Double) -> AnyShapeStyle {
        guard fraction < 0.94 else { return AnyShapeStyle(color) }
        return AnyShapeStyle(AngularGradient(colors: [color.opacity(0.7), color], center: .center,
                                             startAngle: .degrees(-8), endAngle: .degrees(max(4, 360 * fraction))))
    }

    /// VoiceOver's line: the window, its reading and its reset.
    private var spokenLine: String { "\(window.longName) window \(window.spokenPercent), \(reset ?? "")" }

    /// Where the window lands at reset at this pace, as a fraction of the
    /// ring — past 1 when it would run out first.
    private var projected: Double? { forecast.projectedAtReset(now: now.timeIntervalSince1970).map { $0 / 100 } }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                if fraction != nil {
                    Circle().stroke(Color.primary.opacity(0.07), lineWidth: 7)
                }
                if let fraction, let projected, projected > fraction + 0.005 {
                    // The ghost arc: where this window stands at the reset
                    // if the pace holds — amber when it would not make it.
                    Circle()
                        .trim(from: fraction, to: min(1, projected))
                        .stroke((projected > 1 ? Color.orange : color).opacity(0.3),
                                style: StrokeStyle(lineWidth: 7, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(reduced ? .easeOut(duration: 0.15) : .spring(response: 0.6, dampingFraction: 0.8), value: projected)
                }
                if let fraction {
                    Circle()
                        .trim(from: 0, to: fraction)
                        .stroke(arcShading(fraction), style: StrokeStyle(lineWidth: 7, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(reduced ? .easeOut(duration: 0.15) : .spring(response: 0.6, dampingFraction: 0.8), value: fraction)
                } else {
                    // A hairline where the track would be: unmistakably not
                    // an empty ring, and no reading dressed as one.
                    Circle()
                        .stroke(Color.secondary.opacity(0.45), lineWidth: 1)
                }
                Text(window.percentText)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(window.isUnknown ? Color.secondary : Color.primary)
                    .contentTransition(.numericText())
            }
            .frame(width: 66, height: 66)
            Text(window.shortName)
                .font(.caption.weight(.semibold))
            Text(reset ?? "no reset time")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
            if window.isUnknown {
                Text("no reading").font(.caption2).foregroundStyle(.secondary)
            } else if let rate = forecast.rateText {
                Text(rate)
                    .font(.caption2)
                    .foregroundStyle(forecast.isCritical ? Color.orange : Color.secondary)
                    .monospacedDigit()
            } else if forecast.verdict == .exhausted {
                Text("used up").font(.caption2).foregroundStyle(.red)
            }
        }
        .frame(width: 96)
        .help(window.isUnknown ? "\(window.longName) window: the provider reports it without a number"
              : "\(window.longName) window: \(window.spokenPercent)"
                + (projected.map { " · at this pace \(Int(($0 * 100).rounded()))% by the reset" } ?? ""))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLine)
    }
}

enum UsageColors {
    /// The level colour, or the secondary ink for a window with no
    /// reading — an unmeasured window is not a calm one, and painting it
    /// the accent would say it is fine.
    static func level(_ pct: Double?, accent: Color) -> Color {
        guard let pct else { return .secondary }
        if pct >= 95 { return .red }
        if pct >= 80 { return .orange }
        return accent
    }
}

// MARK: - Chart

struct UsagePoint: Identifiable {
    let date: Date
    let kind: String
    let value: Double
    var id: String { "\(kind)|\(date.timeIntervalSince1970)" }
}

struct UsageChart: View {
    let history: UsageHistory
    let range: UsageHistoryRange
    let metric: UsageCenterStore.Metric
    let accent: Color

    @ViewState private var selected: Date?

    private var hourly: Bool { range == .week && !history.hours.isEmpty }
    private var unit: Calendar.Component { hourly ? .hour : .day }

    /// The series, bottom of the stack first: cache reads under the
    /// words the model read and wrote, so the accent rides on top.
    static let tokenKinds = ["Cache reads", "Input", "Output"]

    private var points: [UsagePoint] {
        if hourly {
            return history.hours.flatMap { hour -> [UsagePoint] in
                guard let date = hour.date else { return [] }
                return rows(date: date, input: hour.tokensIn, output: hour.tokensOut, cache: hour.cacheRead, cost: hour.costUsd)
            }
        }
        return history.days.flatMap { day -> [UsagePoint] in
            guard let date = day.day else { return [] }
            return rows(date: date, input: day.tokensIn, output: day.tokensOut, cache: day.cacheRead, cost: day.costUsd)
        }
    }

    /// One point per bucket for the line along the top of the stack.
    private var totals: [UsagePoint] {
        let sums = Dictionary(grouping: points, by: \.date).mapValues { $0.reduce(0) { $0 + $1.value } }
        return sums.map { UsagePoint(date: $0.key, kind: "Total", value: $0.value) }.sorted { $0.date < $1.date }
    }

    private func rows(date: Date, input: Int, output: Int, cache: Int, cost: Double) -> [UsagePoint] {
        switch metric {
        case .tokens:
            return [
                UsagePoint(date: date, kind: "Cache reads", value: Double(cache)),
                UsagePoint(date: date, kind: "Input", value: Double(input)),
                UsagePoint(date: date, kind: "Output", value: Double(output)),
            ]
        case .cost:
            return [UsagePoint(date: date, kind: "Cost", value: cost)]
        }
    }

    private var domain: [String] { metric == .tokens ? Self.tokenKinds : ["Cost"] }

    /// Each series fades toward the floor: the accent for what the model
    /// read and wrote, a grey wash for the cache it re-read.
    private var fills: [LinearGradient] {
        let fade = { (top: Color, bottom: Color) in
            LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)
        }
        switch metric {
        case .tokens:
            return [fade(Color.secondary.opacity(0.22), Color.secondary.opacity(0.06)),
                    fade(accent.opacity(0.55), accent.opacity(0.22)),
                    fade(accent.opacity(0.95), accent.opacity(0.55))]
        case .cost:
            return [fade(accent.opacity(0.45), accent.opacity(0.03))]
        }
    }

    /// The bucket under the cursor: "Tue 9 Sep" for a daily chart,
    /// "Tue 14:00" for an hourly one.
    private static let dayTitle: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE d MMM"
        return formatter
    }()

    private static let hourTitle: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE HH:00"
        return formatter
    }()

    /// The bucket the selection landed on, matched at the chart's own
    /// granularity (an hour's point and a day's point both exist for
    /// Tuesday).
    private func bucket(at date: Date) -> (input: Int, output: Int, cache: Int, cost: Double)? {
        let calendar = Calendar.current
        if hourly {
            return history.hours.first { hour in
                hour.date.map { calendar.isDate($0, equalTo: date, toGranularity: .hour) } ?? false
            }.map { ($0.tokensIn, $0.tokensOut, $0.cacheRead, $0.costUsd) }
        }
        return history.days.first { day in
            day.day.map { calendar.isDate($0, equalTo: date, toGranularity: .day) } ?? false
        }.map { ($0.tokensIn, $0.tokensOut, $0.cacheRead, $0.costUsd) }
    }

    /// The selected bucket's total, where the rule meets the line.
    private func total(at date: Date) -> Double? {
        guard let bucket = bucket(at: date) else { return nil }
        return metric == .tokens ? Double(bucket.input + bucket.output + bucket.cache) : bucket.cost
    }

    /// The selection snapped to the bucket it falls in.
    private func snapped(_ date: Date) -> Date {
        Calendar.current.dateInterval(of: unit, for: date)?.start ?? date
    }

    @ViewBuilder
    private func annotation(for date: Date) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text((hourly ? Self.hourTitle : Self.dayTitle).string(from: date))
                .font(.caption.weight(.semibold))
            if let bucket = bucket(at: date) {
                if metric == .tokens {
                    line("Input", UsageFormat.tokens(bucket.input), swatch: accent)
                    line("Output", UsageFormat.tokens(bucket.output), swatch: accent.opacity(0.6))
                    line("Cache reads", UsageFormat.tokens(bucket.cache), swatch: Color.secondary.opacity(0.5))
                    Divider().padding(.vertical, 1)
                    line("Total", UsageFormat.tokens(bucket.input + bucket.output + bucket.cache), bold: true)
                } else {
                    line("Cost", UsageFormat.cost(bucket.cost, currency: history.pricing?.currency ?? "USD"), bold: true)
                }
            }
        }
        .font(.caption2)
        .monospacedDigit()
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(minWidth: 150)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
    }

    private func line(_ name: String, _ value: String, swatch: Color? = nil, bold: Bool = false) -> some View {
        HStack(spacing: 6) {
            if let swatch {
                Circle().fill(swatch).frame(width: 6, height: 6)
            }
            Text(name).foregroundStyle(.secondary)
            Spacer(minLength: 14)
            Text(value).fontWeight(bold ? .semibold : .regular)
        }
    }

    var body: some View {
        Chart {
            ForEach(points) { point in
                AreaMark(
                    x: .value("Time", point.date, unit: unit),
                    y: .value(metric == .tokens ? "Tokens" : "Cost", point.value),
                    stacking: .standard
                )
                .foregroundStyle(by: .value("Kind", point.kind))
                .interpolationMethod(.monotone)
            }
            ForEach(totals) { point in
                LineMark(
                    x: .value("Time", point.date, unit: unit),
                    y: .value("Total", point.value)
                )
                .foregroundStyle(accent)
                .lineStyle(StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                .interpolationMethod(.monotone)
            }
            // Hover a bucket: a rule at the bucket's start, a dot where it
            // meets the line and a card with its figures. No selection, no
            // overlay. Drawn, never animated — nothing to gate on Reduce
            // Motion.
            if let selected {
                let bucket = snapped(selected)
                RuleMark(x: .value("Selected", bucket, unit: unit))
                    .foregroundStyle(Color.primary.opacity(0.25))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) {
                        annotation(for: bucket)
                    }
                if let total = total(at: bucket) {
                    PointMark(x: .value("Selected", bucket, unit: unit), y: .value("Total", total))
                        .symbolSize(38)
                        .foregroundStyle(accent)
                }
            }
        }
        .chartXSelection(value: $selected)
        .chartForegroundStyleScale(domain: domain, range: fills)
        .chartLegend(metric == .tokens ? .visible : .hidden)
        .chartLegend(position: .top, alignment: .leading, spacing: 8)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: hourly ? 7 : 6)) { _ in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.05))
                AxisValueLabel(format: hourly ? .dateTime.weekday(.abbreviated) : (range == .year ? .dateTime.month(.abbreviated) : .dateTime.month(.abbreviated).day()))
                    .font(.caption2)
                    .foregroundStyle(Color.secondary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3])).foregroundStyle(Color.primary.opacity(0.12))
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(metric == .tokens ? UsageFormat.tokens(Int(number)) : UsageFormat.cost(number, currency: history.pricing?.currency ?? "USD"))
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(Color.secondary)
                    }
                }
            }
        }
        .chartPlotStyle { plot in
            plot.clipped()
        }
        .accessibilityLabel("\(metric == .tokens ? "Tokens" : "Cost") over the last \(range.days) days")
    }
}

/// "By model": the range's tokens (or dollars) split by the model each
/// record ran on — why a week cost twice the last one, in one glance. The
/// bars share one scale so a model's length is its share of the range.
struct UsageModelBreakdown: View {
    let history: UsageHistory
    let metric: UsageCenterStore.Metric
    let accent: Color

    static let shown = 6

    /// Each model's share of the range, by the metric the card leads with.
    static func shares(_ models: [UsageHistoryModel], metric: UsageCenterStore.Metric) -> [(model: UsageHistoryModel, share: Double)] {
        let value: (UsageHistoryModel) -> Double = { metric == .cost ? $0.costUsd : Double($0.tokens) }
        let total = models.reduce(0) { $0 + value($1) }
        guard total > 0 else { return models.map { ($0, 0) } }
        return models
            .sorted { value($0) != value($1) ? value($0) > value($1) : $0.model < $1.model }
            .map { ($0, value($0) / total) }
    }

    var body: some View {
        let rows = Self.shares(history.models, metric: metric)
        VStack(alignment: .leading, spacing: 5) {
            Text("By model").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(rows.prefix(Self.shown), id: \.model.id) { row in
                HStack(spacing: 8) {
                    Text(row.model.displayName)
                        .font(.caption)
                        .lineLimit(1)
                        .frame(width: 130, alignment: .leading)
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.07))
                            Capsule().fill(accent.opacity(0.65))
                                .frame(width: max(2, proxy.size.width * row.share))
                        }
                    }
                    .frame(height: 5)
                    Text("\(Int((row.share * 100).rounded()))%")
                        .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .trailing)
                    Text(UsageFormat.tokens(row.model.tokens))
                        .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                    Text(row.model.priced ? (row.model.estimated ? "≈ " : "") + UsageFormat.cost(row.model.costUsd, currency: history.pricing?.currency ?? "USD") : "no price")
                        .font(.caption2).monospacedDigit().foregroundStyle(row.model.priced ? .secondary : .tertiary)
                        .frame(width: 64, alignment: .trailing)
                }
                .help("\(row.model.displayName) (\(row.model.model)): \(UsageFormat.tokens(row.model.tokens)) tokens in \(row.model.records) records"
                      + (row.model.estimated ? " · priced at a stand-in rate" : "")
                      + (row.model.priced ? "" : " · no price table — its dollars are not counted"))
            }
            if rows.count > Self.shown {
                Text("and \(rows.count - Self.shown) more")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.top, 4)
        .accessibilityElement(children: .contain)
    }
}

/// "When you burn it": the last week's hours as a weekday × hour punch
/// card, with the headline window's current span outlined — the rhythm
/// to plan a long run around the next reset by. Dots, not bars: each is
/// one real hour of the week, sized by its share of the busiest hour.
struct UsagePunchCardView: View {
    let history: UsageHistory
    let accent: Color
    /// The window whose span is outlined (the card's headline window).
    let window: CoreUsageWindow?
    let now: Date

    static let dot: CGFloat = 9

    private var card: UsagePunchCard { UsagePunchCard.build(hours: history.hours) }

    /// The cells the headline window has covered so far.
    private var windowCells: Set<UsagePunchCard.Cell> {
        guard let window, let resetsAt = window.resetsAt,
              let span = UsageWindowLabel.windowSpan(id: window.key, name: window.name), span <= 24 * 3600 else { return [] }
        return UsagePunchCard.cells(from: resetsAt - span, to: min(resetsAt, now.timeIntervalSince1970))
    }

    var body: some View {
        let card = card
        let outlined = windowCells
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("When you burn it").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if let window, !outlined.isEmpty {
                    Text("· outlined: the current \(window.shortName) window")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Grid(alignment: .center, horizontalSpacing: 2, verticalSpacing: 2) {
                ForEach(0..<7, id: \.self) { weekday in
                    GridRow {
                        Text(card.weekdayLabels[weekday])
                            .font(.system(size: 8)).foregroundStyle(.tertiary)
                            .frame(width: 26, alignment: .trailing)
                        ForEach(0..<24, id: \.self) { hour in
                            let intensity = card.intensity(weekday, hour)
                            ZStack {
                                Circle().fill(Color.primary.opacity(0.05))
                                if intensity > 0 {
                                    Circle().fill(accent.opacity(0.35 + 0.6 * intensity))
                                        .scaleEffect(0.35 + 0.65 * intensity)
                                }
                                if outlined.contains(UsagePunchCard.Cell(weekday: weekday, hour: hour)) {
                                    Circle().strokeBorder(accent.opacity(0.8), lineWidth: 1)
                                }
                            }
                            .frame(width: Self.dot, height: Self.dot)
                            .help("\(card.weekdayLabels[weekday]) \(String(format: "%02d:00", hour)) · \(UsageFormat.tokens(card.cells[weekday][hour])) tokens")
                        }
                    }
                }
                GridRow {
                    Text("").frame(width: 26)
                    ForEach(0..<24, id: \.self) { hour in
                        Text(hour % 6 == 0 ? "\(hour)" : "")
                            .font(.system(size: 7)).foregroundStyle(.quaternary)
                            .frame(width: Self.dot)
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Tokens by weekday and hour over the last week; busiest hour \(UsageFormat.tokens(card.peak)) tokens")
        }
        .padding(.top, 4)
    }
}

/// "By day": ccusage's daily report — every day in the range that carried
/// anything, newest first, with input, output, cache reads and the cost.
/// Closed until opened; the chart above is the at-a-glance view.
struct UsageDailyTable: View {
    let history: UsageHistory
    @ViewState private var open = false

    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 3) {
                GridRow {
                    Text("Day").gridColumnAlignment(.leading)
                    Text("Input")
                    Text("Output")
                    Text("Cache reads")
                    Text("Total")
                    Text("Cost")
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                ForEach(history.activeDaysNewestFirst) { day in
                    GridRow {
                        Text(day.day.map { Self.dayTitle.string(from: $0) } ?? day.date)
                            .gridColumnAlignment(.leading)
                        Text(UsageFormat.tokens(day.tokensIn))
                        Text(UsageFormat.tokens(day.tokensOut))
                        Text(UsageFormat.tokens(day.cacheRead))
                        Text(UsageFormat.tokens(day.totalTokens)).fontWeight(.medium)
                        Text((history.costsApproximate ? "≈ " : "") + UsageFormat.cost(day.costUsd, currency: history.pricing?.currency ?? "USD"))
                    }
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 4)
            .textSelection(.enabled)
        } label: {
            Text("By day · \(history.activeDaysNewestFirst.count) active day\(history.activeDaysNewestFirst.count == 1 ? "" : "s")")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    private static let dayTitle: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE d MMM"
        return formatter
    }()
}

/// The scan is still running behind a graph that is already drawn.
struct ScanningNote: View {
    var body: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 12, height: 12)
            Text("Still reading transcripts — this will fill in.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.top, 2)
    }
}

/// The provider keeps no transcripts on this Mac, so there is nothing for
/// the graph to draw and never will be until it writes some.
struct NoLocalRecordsHint: View {
    let style: ProviderStyle
    let provider: CoreProviderUsage

    /// A card with no quota has no percentages above to point at.
    private var detail: String {
        guard provider.quotaSource else {
            return "The graph needs transcripts on this Mac, and the monitor found none."
        }
        return "The percentages above come from the provider; the graph needs transcripts on this Mac, and the monitor found none."
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "tray")
                .font(.system(size: 15, weight: .light))
                .foregroundStyle(style.accent.opacity(0.8))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(style.name) reports no local records")
                    .font(.callout.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .windowWell()
        .accessibilityElement(children: .combine)
    }
}

/// A soft grey swell where the graph will be while `usage_history` is
/// in flight, breathing unless Reduce Motion is on.
struct UsageSkeleton: View {
    /// True when the daemon told us its scan is still running: the caption
    /// says so rather than implying the request is merely slow.
    var scanning = false
    @ViewState private var breathing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The swell's shape: a day-like rise and fall, drawn once.
    private static let shape: [Double] = [0.22, 0.3, 0.52, 0.46, 0.7, 0.58, 0.82, 0.64, 0.42, 0.55, 0.36, 0.3]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Canvas { context, size in
                let step = size.width / CGFloat(Self.shape.count - 1)
                let points = Self.shape.enumerated().map { index, value in
                    CGPoint(x: CGFloat(index) * step, y: size.height * CGFloat(1 - value))
                }
                var area = SmoothLine.path(through: points)
                area.addLine(to: CGPoint(x: size.width, y: size.height))
                area.addLine(to: CGPoint(x: 0, y: size.height))
                area.closeSubpath()
                context.fill(area, with: .linearGradient(Gradient(colors: [Color.primary.opacity(0.08), Color.primary.opacity(0.02)]),
                                                         startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            }
            .frame(height: 120)
            HStack(spacing: 6) {
                ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 12, height: 12)
                Text(scanning ? "Reading transcripts — the monitor is still scanning." : "Loading history…")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .opacity(breathing ? 0.55 : 1)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: breathing)
        .onAppear { breathing = true }
        .accessibilityLabel("Loading history")
    }
}

extension UsageFormat {
    static func currencySymbol(_ currency: String) -> String {
        switch currency {
        case "USD": return "$"
        case "EUR": return "€"
        case "GBP": return "£"
        default: return currency + " "
        }
    }
}
