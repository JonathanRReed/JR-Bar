import JRBarCore
import JRBarUI
import SwiftUI

@MainActor
struct UsageProviderFacts {
    let provider: CoreProviderUsage
    let history: UsageHistory?
    let providers: [CoreProviderUsage]
    let isLive: Bool
    let now: Date

    var account: String {
        [UsageCenterStore.accountLine(provider, history: history), UsageSourceNotes.sourceCaption(provider) ?? ""]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }
    var readingAge: String? { UsageCardCopy.readingAgeText(provider, now: now) }
    var constraint: String? {
        guard let selected = provider.headlineWindow, let conventional = provider.conventionalWindow,
              selected.id != conventional.id else { return nil }
        return provider.constrained.map { "Watching \(selected.longName): \($0.explanation)" }
    }
    var noQuota: String? { UsageSourceNotes.noQuotaLine(provider, name: ProviderPalette.displayName(for: provider.id)) }
    var credits: String? {
        var parts: [String] = []
        if let balance = provider.creditsRemaining, balance.isFinite, balance >= 0 {
            parts.append("\(UsageFormat.grouped(balance)) credits left")
        }
        if let resets = UsageSourceNotes.resetCreditsText(provider.resetCredits) { parts.append(resets) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
    var counters: String? {
        guard !provider.isSignedOut, let tokens = provider.tokens, tokens.total > 0 else { return nil }
        var text = "\(UsageFormat.tokens(tokens.total)) tokens at last reading"
        if tokens.cachedInput > 0 { text += " · \(UsageFormat.tokens(tokens.cachedInput)) from cache" }
        return text
    }
    var estimatedCost: String? {
        guard !provider.isSignedOut, let cost = provider.estimatedCostUSD, cost.isFinite, cost > 0 else { return nil }
        return "≈ \(UsageFormat.cost(cost)) estimated at last reading"
    }
    var headroom: String? {
        guard isLive, !provider.isSignedOut,
              let found = HeadroomElsewhere.find(for: provider, among: providers, now: now) else { return nil }
        let date = found.readAt.map { Date(timeIntervalSince1970: $0) }
        return found.line(providerName: ProviderPalette.displayName(for: found.providerID), ago: PanelStore.elapsed(since: date, now: now))
    }
}

struct UsageProviderFactsView: View {
    let facts: UsageProviderFacts
    let showCost: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: JRBarTokens.Space.xs) {
            if !facts.account.isEmpty { Text(facts.account).textSelection(.enabled) }
            if let text = facts.noQuota { Text(text) }
            if let text = facts.constraint { Text(text) }
            if let text = facts.readingAge { Text(text) }
            if let text = facts.credits { Text(text) }
            if let text = facts.counters { Text(text) }
            if showCost, let text = facts.estimatedCost { Text(text) }
            if let text = facts.headroom { Text(text) }
        }
        .font(JRBarTokens.TypeStyle.callout.font).foregroundStyle(JRBarTokens.Ink.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct UsageBurnersView: View {
    let window: CoreUsageWindow
    let burners: [WindowBurner]

    var body: some View {
        VStack(alignment: .leading, spacing: JRBarTokens.Space.xs) {
            Text("Burning the \(window.shortName) window here").font(JRBarTokens.TypeStyle.headline.font)
            ForEach(burners) { burner in
                HStack(spacing: JRBarTokens.Space.md) {
                    Text(burner.label).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text("\(Int((burner.share * 100).rounded()))% · \(UsageFormat.tokens(burner.tokens))").monospacedDigit()
                }
            }
        }
        .font(JRBarTokens.TypeStyle.callout.font)
        .help("Shares of the tokens this Mac's sessions spent since the window opened.")
    }
}
