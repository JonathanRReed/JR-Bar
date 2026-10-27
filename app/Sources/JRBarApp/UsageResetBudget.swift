import Foundation
import JRBarCore
import JRBarUI
import SwiftUI

/// Compare the recent burn rate with the remaining quota spread to reset.
struct UsageResetBudget: Equatable {
    let recentRate: Double
    let rateToReset: Double

    var exceedsBudget: Bool { recentRate > rateToReset }
    var recentText: String { UsageNumber.rate(recentRate, approximate: true) }
    var budgetText: String { UsageNumber.rateLimit(rateToReset) }

    static func make(provider: CoreProviderUsage, window: CoreUsageWindow,
                     forecast: UsageForecast, isLive: Bool, now: Double) -> Self? {
        guard isLive, !provider.isStale, !provider.isSignedOut, !provider.usageIsOff,
              window.bindable, !window.detail, !forecast.heldIdle, now.isFinite else { return nil }
        if let state = provider.state?.lowercased(),
           ["disabled", "off", "needs_consent", "error", "unavailable", "source_not_found"].contains(state) { return nil }
        switch forecast.verdict {
        case .comfortable, .runsOut: break
        default: return nil
        }
        guard forecast.source != .none,
              let used = forecast.usedPct, used.isFinite, (0..<100).contains(used),
              let reset = forecast.resetsAt, reset.isFinite, reset > now,
              let recent = measuredRate(provider: provider, window: window, forecast: forecast, now: now), recent.isFinite,
              recent > UsageForecaster.idleRate else { return nil }
        let hours = (reset - now) / 3600
        let budget = (100 - used) / hours
        guard budget.isFinite, budget >= 0.000001, (budget * 10).isFinite else { return nil }
        return Self(recentRate: recent, rateToReset: budget)
    }

    private static func measuredRate(provider: CoreProviderUsage, window: CoreUsageWindow,
                                     forecast: UsageForecast, now: Double) -> Double? {
        if forecast.source == .local { return forecast.ratePctPerHour }
        guard forecast.source == .daemon, let daemon = window.forecast ?? provider.forecast else { return nil }
        if let at = provider.readingAt, !at.isFinite || at <= 0 || at > now { return nil }
        if let rate = daemon.ratePctPerHour { return rate }
        guard let at = provider.readingAt,
              let exhaustsAt = daemon.exhaustsAt, exhaustsAt.isFinite, exhaustsAt > at,
              let used = forecast.usedPct else { return nil }
        return (100 - used) / ((exhaustsAt - at) / 3600)
    }
}

struct UsageResetBudgetView: View {
    let budget: UsageResetBudget

    var body: some View {
        HStack(alignment: .top, spacing: JRBarTokens.Space.lg) {
            column("Recent pace", value: budget.recentText,
                   color: budget.exceedsBudget ? Tone.warning.color : JRBarTokens.Ink.secondary)
            column("To last until reset", value: budget.budgetText, color: .secondary)
        }
        .padding(.horizontal, JRBarTokens.Space.md)
        .padding(.vertical, JRBarTokens.Space.sm)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: JRBarTokens.Radius.control))
        .help("The rate to reset divides the remaining quota by the hours until its reported reset. Recent pace estimates how fast quota was spent. Usage elsewhere can change that pace.")
        .accessibilityElement(children: .combine)
    }

    private func column(_ title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: JRBarTokens.Space.xs) {
            Text(title).font(JRBarTokens.TypeStyle.caption.font).foregroundStyle(.secondary)
            Text(value)
                .font(JRBarTokens.TypeStyle.callout.font)
                .monospacedDigit()
                .foregroundStyle(color)
        }
    }
}
