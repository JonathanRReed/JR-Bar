import Foundation
import JRBarCore
import JRBarUI
import SwiftUI

@MainActor
struct UsageWindowInspection {
    let provider: CoreProviderUsage
    let window: CoreUsageWindow
    let forecast: UsageForecast
    let isLive: Bool
    let now: Date

    private var hasAmount: Bool {
        window.usedPct.map { $0.isFinite && (0...100).contains($0) } ?? false
    }

    private var validatedReset: Double? {
        guard let reset = window.resetsAt, reset.isFinite, reset > 0,
              reset <= Date.distantFuture.timeIntervalSince1970 else { return nil }
        return reset
    }

    var displayForecast: UsageForecast {
        var result = forecast
        result.resetsAt = validatedReset
        if validatedReset == nil, result.verdict == .guarded(reason: "window_elapsed") {
            result.verdict = .unknown
        }
        return result
    }

    var amountText: String {
        guard hasAmount else { return "No quota reading" }
        let approximate = provider.isDerived && !provider.isStale ? "≈ " : ""
        return "\(approximate)\(window.percentText) used"
    }

    var readingNotice: String? {
        if !isLive { return "\(MonitorWords.sentence) This is the last reading." }
        if provider.isStale || ["failing", "source_idle", "missing_recent"].contains(provider.availability) {
            return "This reading is stale."
        }
        if ["not_found", "absent"].contains(provider.availability) {
            return "Usage source unavailable. This is the last reading."
        }
        if provider.isSignedOut { return "Not signed in. This is the last reading." }
        if provider.usageIsOff { return "Usage is off. This is the last reading." }
        switch provider.state?.lowercased() {
        case "disabled", "off": return "Metering is off. This is the last reading."
        case "needs_consent": return "Usage needs consent. This is the last reading."
        case "error", "unavailable", "source_not_found": return "Usage source unavailable. This is the last reading."
        default: return nil
        }
    }

    var verdictText: String {
        if !hasAmount { return UsageStatus.noReading.word }
        if readingNotice != nil { return UsageStatus.paused.word }
        return displayForecast.verdictWord(now: now)
    }

    var explanation: String {
        if !hasAmount { return "The provider reports this window without a quota percentage." }
        if !isLive { return "Forecasts resume when the monitor reconnects." }
        if readingNotice != nil { return "Forecasts resume with a fresh quota reading." }
        return displayForecast.headline(now: now)
    }

    var projectedText: String? {
        guard readingNotice == nil, hasAmount, !forecast.heldIdle,
              let projected = displayForecast.projectedAtReset(now: now.timeIntervalSince1970),
              projected.isFinite else { return nil }
        return "At this pace \(String(format: "%.0f", projected.rounded()))% by the reset"
    }

    var budget: UsageResetBudget? {
        guard readingNotice == nil else { return nil }
        return UsageResetBudget.make(provider: provider, window: window, forecast: displayForecast,
                                     isLive: isLive, now: now.timeIntervalSince1970)
    }

    var forecastEvidence: String? {
        guard hasAmount, readingNotice == nil else { return nil }
        switch forecast.source {
        case .daemon:
            let primary = window.id == provider.conventionalWindow?.id
            let daemon = window.forecast ?? (primary ? provider.forecast : nil)
            guard let count = daemon?.samples, count >= 0 else { return "Monitor forecast" }
            return "Monitor forecast · \(count) quota reading\(count == 1 ? "" : "s")"
        case .local: return "Local estimate from the last 45 minutes"
        case .none:
            return forecast.verdict == .unknown ? "A pace needs two quota readings a minute apart." : nil
        }
    }

    var readingDate: Date? {
        guard let at = provider.readingAt, at.isFinite, at > 0, at <= now.timeIntervalSince1970 else { return nil }
        return Date(timeIntervalSince1970: at)
    }

    var readingAge: String {
        guard let date = readingDate, let age = PanelStore.elapsed(since: date, now: now) else { return "Reading time unavailable" }
        return "Read \(age) ago"
    }

    var resetText: String {
        guard validatedReset != nil else { return "Reset time unavailable" }
        return UsageCenterStore.resetText(window, of: provider, now: now) ?? "Reset time unavailable"
    }

    var scopeText: String? {
        if window.detail { return "For reference. This window does not drive the account limit." }
        if !window.bindable { return "This window is not used to choose the account's headline limit." }
        return nil
    }

    var inspectLabel: String {
        let reading = hasAmount ? window.spokenPercent : "no quota reading"
        return "Inspect \(window.longName) window, \(reading)"
    }

    var verdictColor: Color {
        guard hasAmount, readingNotice == nil else { return .secondary }
        return UsageCardCopy.verdictTint(displayForecast)
    }
}


struct UsageWindowInspectionView: View {
    let inspection: UsageWindowInspection

    var body: some View {
        VStack(alignment: .leading, spacing: JRBarTokens.Space.md) {
            Text("\(inspection.window.longName) window").font(JRBarTokens.TypeStyle.headline.font)
            if let notice = inspection.readingNotice {
                Label(notice, systemImage: "clock.badge.exclamationmark")
                    .font(JRBarTokens.TypeStyle.callout.font)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(inspection.amountText)
                .font(JRBarTokens.TypeStyle.title1.font)
                .monospacedDigit()
            Text(inspection.resetText)
                .font(JRBarTokens.TypeStyle.callout.font)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Divider()
            StatusBadge(inspection.verdictText, tint: inspection.verdictColor)
            Text(inspection.explanation)
                .font(JRBarTokens.TypeStyle.callout.font)
                .fixedSize(horizontal: false, vertical: true)
            if let evidence = inspection.forecastEvidence {
                Text(evidence).font(JRBarTokens.TypeStyle.caption.font).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: JRBarTokens.Space.xs) {
                Text(inspection.readingAge)
                if let date = inspection.readingDate {
                    Text(date.formatted(date: .abbreviated, time: .shortened))
                }
            }
            .font(JRBarTokens.TypeStyle.caption.font)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            if let scope = inspection.scopeText {
                Text(scope).font(JRBarTokens.TypeStyle.caption.font).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(JRBarTokens.Space.lg)
        .frame(width: 312, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}
