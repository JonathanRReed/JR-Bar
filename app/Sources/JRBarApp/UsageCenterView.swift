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
                UsageEmptyState(symbol: "bolt.horizontal.circle", title: "Monitor not connected",
                                text: "Usage comes from the monitor. The cards fill in as soon as the socket is live.")
            } else if store.providers.isEmpty {
                VStack(spacing: 10) {
                    UsageEmptyState(symbol: "chart.bar", title: "No usage yet",
                                    text: "No provider has reported a quota window. Metering is turned on from Settings › Usage.")
                    Button("Open Usage settings…") { store.openUsageSettings() }
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 14) {
                            statusLine
                            if store.providers.count > 1 {
                                CombinedUsageCard(providers: store.providers, store: store)
                            }
                            ForEach(store.providers) { provider in
                                ProviderUsageCard(provider: provider, store: store)
                                    .id(provider.identity)
                            }
                        }
                        .padding(18)
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
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 12)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: store.lastError == nil)
    }

    private var statusLine: some View {
        HStack(spacing: 6) {
            if let at = store.refreshedAt, let elapsed = PanelStore.elapsed(since: at, now: store.now) {
                Text("Updated \(elapsed) ago")
            } else {
                Text("Waiting for the first usage read")
            }
            Text("·").foregroundStyle(.quaternary)
            Text("Costs are estimates from list prices, not invoices.")
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.tertiary)
        .monospacedDigit()
        .padding(.horizontal, 2)
    }
}

struct UsageEmptyState: View {
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
            Text(title).font(.title3.weight(.semibold))
            Text(text)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
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
            }
            if let readings = readingsLine {
                Text(readings)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let row = store.row(for: provider.identity) {
                Divider()
                connectionSection(row)
            }
            if !provider.isSignedOut {
                Divider()
                historySection
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(flashing ? style.accent.opacity(0.7) : Color.primary.opacity(0.07), lineWidth: flashing ? 1.5 : 0.5)
        }
        .background {
            // The quota_reset / focus flourish: a brief wash of the accent
            // that fades out.
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(style.accent.opacity(flashing ? 0.10 : 0))
                .blur(radius: flashing ? 0 : 8)
        }
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
                        Text(instance)
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
                Text(UsageCenterStore.accountLine(provider, history: history))
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
                    Text("\(primary.longName) window · \(PanelStore.countdown(to: primary.resetsAt, now: store.now) ?? "no reset time")")
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
        if let observedAt = provider.observedAt,
           let age = PanelStore.elapsed(since: Date(timeIntervalSince1970: observedAt), now: store.now) {
            parts.append("read \(age) ago")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// What stands in for the rings when the daemon reports no window: the
    /// state word's own sentence, not a flat "nothing here".
    private var noWindowsLine: String {
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
        guard let primary, let index = provider.windows.firstIndex(of: primary), index != 0 else { return provider.windows }
        var windows = provider.windows
        windows.remove(at: index)
        return [primary] + windows
    }

    private var windows: some View {
        HStack(alignment: .top, spacing: 14) {
            ForEach(orderedWindows) { window in
                QuotaRing(window: window, forecast: store.forecast(for: provider, window: window), accent: style.accent,
                          now: store.now, reduced: store.reduceMotion)
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
                Text(forecast.headline(now: store.now))
                    .font(.callout.weight(forecast.isCritical ? .medium : .regular))
                    .foregroundStyle(forecast.isCritical ? .primary : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(forecastSource(forecast))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
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
        if let hint = PanelStore.paceHint(forecast.pace) { parts.append(hint) }
        return parts.joined(separator: " · ")
    }

    // MARK: History

    @ViewBuilder
    private var historySection: some View {
        let title = store.metric == .tokens ? "Tokens" : "Estimated cost"
        let unit = store.range == .week && !(history?.hours.isEmpty ?? true) ? "by hour" : "by day"
        HStack(alignment: .firstTextBaseline) {
            Text("\(title) \(unit)").font(.subheadline.weight(.semibold))
            Spacer()
            if let history, !history.isEmpty {
                Text(totalsLine(history))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
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
                .frame(height: 150)
            if scanning { ScanningNote() }
            costRow(history)
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("All providers").font(.subheadline.weight(.semibold))
                Text("\(providers.count)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                if let worst = Self.worstLane(in: providers) {
                    let style = ProviderStyle.style(for: worst.provider.id, document: store.document)
                    Text("\(style.name) \(worst.window.shortName) \(worst.window.percentText)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(UsageColors.level(worst.window.usedPct, accent: style.accent))
                        .monospacedDigit()
                        .help("The tightest window any provider reports — \(worst.window.longName)")
                }
            }
            ForEach(providers) { provider in
                row(provider)
            }
            if let totals = totalsLine {
                Divider()
                Text(totals)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5)
        }
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

    private func row(_ provider: CoreProviderUsage) -> some View {
        let style = ProviderStyle.style(for: provider.id, document: store.document)
        let leading = UsageCenterStore.primaryWindow(of: provider)
        return HStack(spacing: 10) {
            ProviderTile(style: style, size: 18)
            Text(style.name)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .truncationMode(.tail)
            if provider.isSignedOut {
                Text("not signed in")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                ResignInButton(provider: provider, store: store)
            } else if provider.windows.isEmpty {
                Text(provider.state?.replacingOccurrences(of: "_", with: " ") ?? "no quota windows")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer(minLength: 4)
            } else {
                Spacer(minLength: 4)
                ForEach(provider.windows) { window in
                    Text("\(window.shortName) \(window.percentText)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(UsageColors.level(window.usedPct, accent: style.accent))
                        .help("\(window.longName) window: \(window.spokenPercent)")
                }
                if let leading, let reset = PanelStore.countdown(to: leading.resetsAt, now: store.now) {
                    Text(reset)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { store.focus(provider: provider.id) }
        .help("Scroll to \(style.name)'s card")
        .accessibilityAddTraits(.isButton)
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

// MARK: - Ring

struct QuotaRing: View {
    let window: CoreUsageWindow
    let forecast: UsageForecast
    let accent: Color
    let now: Date
    let reduced: Bool

    /// Nil when the window has no reading: the ring is drawn as an open
    /// track with a dashed edge, never as an arc of zero.
    private var fraction: Double? { window.usedPct.map { min(1, max(0, $0 / 100)) } }
    private var color: Color { UsageColors.level(window.usedPct, accent: accent) }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.08), lineWidth: 7)
                if let fraction {
                    Circle()
                        .trim(from: 0, to: fraction)
                        .stroke(color, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(reduced ? .easeOut(duration: 0.15) : .spring(response: 0.6, dampingFraction: 0.8), value: fraction)
                } else {
                    // A dashed ring: unmistakably not an empty one.
                    Circle()
                        .stroke(Color.secondary.opacity(0.55), style: StrokeStyle(lineWidth: 7, dash: [3, 5]))
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
            Text(PanelStore.countdown(to: window.resetsAt, now: now) ?? "no reset time")
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
        .help(window.isUnknown ? "\(window.longName) window: the provider reports it without a number" : "\(window.longName) window: \(window.spokenPercent)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(window.longName) window \(window.spokenPercent), \(PanelStore.countdown(to: window.resetsAt, now: now) ?? "")")
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

    private func rows(date: Date, input: Int, output: Int, cache: Int, cost: Double) -> [UsagePoint] {
        switch metric {
        case .tokens:
            return [
                UsagePoint(date: date, kind: "Input", value: Double(input)),
                UsagePoint(date: date, kind: "Output", value: Double(output)),
                UsagePoint(date: date, kind: "Cache reads", value: Double(cache)),
            ]
        case .cost:
            return [UsagePoint(date: date, kind: "Cost", value: cost)]
        }
    }

    private var scale: KeyValuePairs<String, Color> {
        switch metric {
        case .tokens: return ["Input": accent, "Output": accent.opacity(0.55), "Cache reads": Color.secondary.opacity(0.3)]
        case .cost: return ["Cost": accent]
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
    /// granularity (an hour's bar and a day's bar both exist for Tuesday).
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

    @ViewBuilder
    private func annotation(for date: Date) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text((hourly ? Self.hourTitle : Self.dayTitle).string(from: date))
                .font(.caption.weight(.semibold))
            if let bucket = bucket(at: date) {
                if metric == .tokens {
                    line("Input", UsageFormat.tokens(bucket.input))
                    line("Output", UsageFormat.tokens(bucket.output))
                    line("Cache reads", UsageFormat.tokens(bucket.cache))
                    line("Total", UsageFormat.tokens(bucket.input + bucket.output + bucket.cache), bold: true)
                } else {
                    line("Cost", UsageFormat.cost(bucket.cost, currency: history.pricing?.currency ?? "USD"), bold: true)
                }
            }
        }
        .font(.caption2)
        .monospacedDigit()
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func line(_ name: String, _ value: String, bold: Bool = false) -> some View {
        HStack {
            Text(name).foregroundStyle(.secondary)
            Spacer(minLength: 14)
            Text(value).fontWeight(bold ? .semibold : .regular)
        }
    }

    var body: some View {
        Chart {
            ForEach(points) { point in
                BarMark(
                    x: .value("Time", point.date, unit: hourly ? .hour : .day),
                    y: .value(metric == .tokens ? "Tokens" : "Cost", point.value)
                )
                .foregroundStyle(by: .value("Kind", point.kind))
                .cornerRadius(hourly ? 1 : 2)
            }
            // Hover a bucket: a rule at the bucket's start and a card with
            // its figures. No selection, no overlay. The rule is drawn,
            // never animated — nothing to gate on Reduce Motion.
            if let selected {
                RuleMark(x: .value("Selected", selected, unit: unit))
                    .foregroundStyle(.secondary.opacity(0.4))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) {
                        annotation(for: selected)
                    }
            }
        }
        .chartXSelection(value: $selected)
        .chartForegroundStyleScale(scale)
        .chartLegend(position: .top, alignment: .leading, spacing: 6)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: hourly ? 7 : 6)) { value in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.05))
                AxisValueLabel(format: hourly ? .dateTime.weekday(.abbreviated) : (range == .year ? .dateTime.month(.abbreviated) : .dateTime.month(.abbreviated).day()))
                    .font(.caption2)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(metric == .tokens ? UsageFormat.tokens(Int(number)) : UsageFormat.cost(number, currency: history.pricing?.currency ?? "USD"))
                            .font(.caption2)
                            .monospacedDigit()
                    }
                }
            }
        }
        .accessibilityLabel("\(metric == .tokens ? "Tokens" : "Cost") over the last \(range.days) days")
    }
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

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "tray")
                .font(.system(size: 15, weight: .light))
                .foregroundStyle(style.accent.opacity(0.8))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(style.name) reports no local records")
                    .font(.callout.weight(.medium))
                Text("The percentages above come from the provider; the graph needs transcripts on this Mac, and the monitor found none.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.04)))
        .accessibilityElement(children: .combine)
    }
}

/// Grey bars while `usage_history` is in flight.
struct UsageSkeleton: View {
    /// True when the daemon told us its scan is still running: the caption
    /// says so rather than implying the request is merely slow.
    var scanning = false
    @ViewState private var breathing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let heights: [CGFloat] = [0.35, 0.6, 0.45, 0.8, 0.55, 0.7, 0.4, 0.65, 0.5, 0.75, 0.3, 0.6]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(Array(heights.enumerated()), id: \.offset) { _, height in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Color.primary.opacity(0.07))
                        .frame(maxWidth: .infinity)
                        .frame(height: 110 * height)
                }
            }
            .frame(height: 110)
            Text(scanning ? "Reading transcripts — the monitor is still scanning." : "Loading history…")
                .font(.caption)
                .foregroundStyle(.tertiary)
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
