import Foundation
import JRBarCore
import SwiftUI

/// A window's display at the caller's clock. Expired numbers never become current.
public struct UsageGaugeReading: Equatable, Sendable {
    public let id: String
    public let title: String
    public let percentUsed: Double?
    public let stale: Bool
    public let elapsed: Bool
    public let footnote: String
    public let resetFootnote: String
    public let forecast: UsageForecast?
    public enum CaptionTone: Equatable, Sendable {
        case secondary, attention, failure
        public var tone: Tone {
            switch self {
            case .secondary: .neutral
            case .attention: .warning
            case .failure: .failure
            }
        }
    }
    public var captionTone: CaptionTone {
        guard let forecast else { return .secondary }
        switch forecast.status.tone {
        case .warning: return .attention
        case .failure: return .failure
        default: return .secondary
        }
    }
    public var forecastHelp: String {
        [forecast?.headline(now: Date(timeIntervalSince1970: timestamp)),
         forecast.flatMap { SessionAwarePace.roomText($0, now: timestamp) },
         resetFootnote.isEmpty ? nil : (elapsed ? resetFootnote : "Resets \(resetFootnote)")].compactMap { $0 }.joined(separator: ". ")
    }
    private let timestamp: Double

    public init(window: CoreUsageWindow, provider: CoreProviderUsage, now: Double, connected: Bool = true,
                locale: Locale = .current, timeZone: TimeZone = .current, forecast: UsageForecast? = nil,
                abbreviatesMinutes: Bool = false) {
        timestamp = now
        id = window.id
        title = window.name
        elapsed = window.elapsed || (window.resetsAt.map { $0 <= now } ?? false)
        stale = !connected || provider.isStale || ["missing_recent", "source_idle", "failing"].contains(provider.availability)
        let suppressed = ["absent", "not_found"].contains(provider.availability) || provider.usageIsOff || !provider.quotaSource
        let measured = window.usedPct.flatMap { $0.isFinite ? min(100, max(0, $0)) : nil }
        percentUsed = elapsed || suppressed ? nil : measured
        resetFootnote = window.resetsAt.map { UsageTime.resetLine($0, now: now, locale: locale, timeZone: timeZone) }
            ?? (elapsed ? "Waiting for a new reading" : "")
        let unavailable = stale || elapsed || suppressed || provider.isSignedOut
            || ["disabled", "off", "needs_consent", "error", "unavailable", "source_not_found"].contains(provider.state ?? "")
        self.forecast = unavailable || percentUsed == nil ? nil : forecast
        switch self.forecast?.verdict {
        case .exhausted?: footnote = UsageStatus.usedUp.word
        case .runsOut(let at)?:
            footnote = UsageTime.runsOut(at: at, now: now, locale: locale, timeZone: timeZone)
        default: footnote = resetFootnote
        }
    }

    public static func resetTime(_ reset: Double, now: Double, locale: Locale, timeZone: TimeZone) -> String {
        UsageTime.resetLine(reset, now: now, locale: locale, timeZone: timeZone)
    }

    public static func age(provider: CoreProviderUsage, now: Double, snapshotReceivedAt: Double) -> String {
        let seconds = provider.readingAt.map { now - $0 }
            ?? provider.lastGoodAgeSeconds.map { $0 + max(0, now - snapshotReceivedAt) }
        return seconds.map { "Read \(UsageTime.ago($0))" } ?? "Reading age unknown"
    }

    static func interval(_ seconds: Double) -> String {
        UsageTime.duration(seconds)
    }
}

/// Render this once above compact rows. Pass the same windowNames to every row.
public struct UsageGaugeHeader: View {
    @Environment(\.jrbarInk) private var neutralInk
    public let windowNames: [String]
    public init(windowNames: [String]) { self.windowNames = UsageGaugeRow.orderedWindowNames(windowNames) }

    public var body: some View {
        HStack(spacing: 10) {
            Color.clear.frame(width: UsageGaugeRow.compactIdentityWidth)
            ForEach(windowNames, id: \.self) { name in
                Text("\(name) used").font(JRBarTokens.TypeStyle.caption.font)
                    .foregroundStyle(neutralInk.secondary).lineLimit(1).truncationMode(.tail)
                    .frame(minWidth: UsageGaugeRow.columnWidth, maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 12).padding(.bottom, 2)
    }
}

/// A provider's independent quota windows. This view starts no polling or clock.
public struct UsageGaugeRow: View {
    @Environment(\.jrbarInk) private var neutralInk
    public enum Style: Sendable { case compact, detail }
    public static let columnWidth: CGFloat = 76
    public static let compactRowHeight: CGFloat = 36
    fileprivate static let compactIdentityWidth: CGFloat = 100
    fileprivate static let compactPercentWidth: CGFloat = 40
    public let provider: CoreProviderUsage
    public let includeAbsent: Bool
    public let name: String
    public let now: Double
    public let connected: Bool
    public let accent: Color
    private let tileAccent: Color?
    public let style: Style
    public let windowNames: [String]
    public let compactColumnWidth: CGFloat
    public let suppressDisconnectedStatus: Bool
    public let snapshotReceivedAt: Double?
    public let locale: Locale
    public let timeZone: TimeZone
    public let fix: String?
    public let onAction: (() -> Void)?
    public let onRetry: (() -> Void)?
    public let forecasts: [String: UsageForecast]
    public let onInspect: ((CoreUsageWindow) -> Void)?
    public let onOpen: (() -> Void)?
    public let pace: [String: Double]
    @UIState private var fallbackSnapshotAt: Double
    @UIState private var hovering = false

    public init(provider: CoreProviderUsage, name: String, now: Double, connected: Bool = true,
                accent: Color? = nil, style: Style = .detail, windowNames: [String]? = nil,
                snapshotReceivedAt: Double? = nil, suppressDisconnectedStatus: Bool = false, locale: Locale = .current, timeZone: TimeZone = .current,
                pace: [String: Double] = [:], forecasts: [String: UsageForecast] = [:],
                onInspect: ((CoreUsageWindow) -> Void)? = nil, onOpen: (() -> Void)? = nil, fix: String? = nil,
                onAction: (() -> Void)? = nil, onRetry: (() -> Void)? = nil,
                compactColumnWidth: CGFloat = UsageGaugeRow.columnWidth, includeAbsent: Bool = false) {
        self.includeAbsent = includeAbsent
        self.compactColumnWidth = compactColumnWidth
        self.provider = provider
        self.name = name
        self.now = now
        self.connected = connected
        self.accent = accent ?? ProviderPalette.color(for: provider.id)
        self.tileAccent = accent
        self.style = style
        self.windowNames = Self.orderedWindowNames(windowNames ?? provider.windows.map(\.name))
        self.snapshotReceivedAt = snapshotReceivedAt
        self.suppressDisconnectedStatus = suppressDisconnectedStatus
        self.locale = locale
        self.timeZone = timeZone
        self.forecasts = forecasts
        self.onInspect = onInspect
        self.onOpen = onOpen
        self.pace = pace
        self.fix = fix
        self.onAction = onAction
        self.onRetry = onRetry
        self._fallbackSnapshotAt = UIState(initialValue: now)
    }

    nonisolated public static func orderedWindowNames(_ names: [String]) -> [String] {
        var unique: [String] = []
        for name in names where !unique.contains(name) { unique.append(name) }
        return ["5h", "7d"].filter(unique.contains) + unique.filter { !["5h", "7d"].contains($0) }
    }

    /// Expired stale windows remain in detail without adding columns to the overview.
    nonisolated public static func compactWindowNames(providers: [CoreProviderUsage], now: Double,
                                                       connected: Bool) -> [String] {
        let names = providers.flatMap { provider in
            guard provider.quotaSource, !provider.usageIsOff,
                  !["absent", "not_found"].contains(provider.availability) else { return [String]() }
            return provider.windows.compactMap { window -> String? in
                let reading = UsageGaugeReading(window: window, provider: provider, now: now, connected: connected)
                return reading.stale && reading.elapsed ? nil : window.name
            }
        }
        return orderedWindowNames(names)
    }

    private var showsWindows: Bool {
        !["absent", "not_found"].contains(provider.availability) && provider.quotaSource && !provider.usageIsOff && !provider.windows.isEmpty
    }
    private var isStale: Bool {
        !connected || provider.isStale || ["missing_recent", "source_idle", "failing"].contains(provider.availability)
    }
    private var status: String? {
        if !connected && !suppressDisconnectedStatus { return MonitorWords.label }
        if provider.availability == "not_found" { return provider.statusText ?? "Not found on this Mac" }
        if provider.usageIsOff { return provider.statusText ?? "Usage is off" }
        if !provider.quotaSource { return UsageStatus.noQuotaSource.word }
        if let status = provider.statusText { return status }
        if isStale && showsWindows { return UsageStatus.stale.word }
        let hasCompactPlaceholders = style == .compact && !windowNames.isEmpty && !isStale
        return showsWindows || hasCompactPlaceholders ? nil : UsageStatus.noReading.word
    }

    public var body: some View {
        if provider.availability != "absent" || includeAbsent {
            Group {
                if style == .compact { compact } else { detail }
            }
            .foregroundStyle(neutralInk.label)
            .onChange(of: provider) { _, _ in fallbackSnapshotAt = now }
        }
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(name).font((style == .compact ? JRBarTokens.TypeStyle.callout : .headline).font).lineLimit(1).truncationMode(.tail)
                .layoutPriority(1)
            if let status {
                HStack(spacing: 3) {
                    if provider.quotaSource && provider.availability == "failing" {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(JRBarTokens.Ink.failure)
                    }
                    Text(status).foregroundStyle(provider.quotaSource && provider.availability == "failing" ? neutralInk.label : neutralInk.secondary)
                }
                .font(JRBarTokens.TypeStyle.caption.font).lineLimit(1).truncationMode(.tail)
                .help(status)
            }
            if let incident = provider.incident, !incident.isEmpty {
                Label("Incident", systemImage: "exclamationmark.triangle")
                    .font(JRBarTokens.TypeStyle.caption.font).foregroundStyle(Tone.failure.color)
                    .help(incident)
            }
            if isStale && showsWindows {
                HStack(spacing: 3) {
                    Image(systemName: "clock")
                    Text(UsageGaugeReading.age(provider: provider, now: now, snapshotReceivedAt: snapshotReceivedAt ?? fallbackSnapshotAt))
                }
                .font(JRBarTokens.TypeStyle.caption.font).foregroundStyle(neutralInk.stale).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var compact: some View {
        VStack(alignment: .leading, spacing: 6) {
            if provider.availability == "not_found" {
                HStack(spacing: 10) {
                    ProviderLogoTile(provider: provider.id, accent: tileAccent, dim: true)
                    Text(name).font(JRBarTokens.TypeStyle.callout.font).lineLimit(1)
                    Text(status ?? "Not found on this Mac").font(JRBarTokens.TypeStyle.caption.font)
                        .foregroundStyle(neutralInk.secondary).lineLimit(1).truncationMode(.tail)
                        .help(status ?? "Not found on this Mac")
                    Spacer(minLength: 0)
                    if let onAction, let title = provider.action, !title.isEmpty {
                        ActionButton(title, action: onAction)
                    }
                }
            } else {
                if let onOpen {
                    Button(action: onOpen) {
                        compactWindows
                            .frame(minHeight: Self.compactRowHeight - JRBarTokens.Space.xs)
                            .contentShape(Rectangle())
                    }
                        .buttonStyle(.plain)
                        .accessibilityHint("Show provider usage")
                } else {
                    compactWindows
                }
                if status != nil || (isStale && showsWindows) { compactReadingStatus.padding(.leading, 30) }
                actions.padding(.leading, 30)
            }
        }
        .padding(.vertical, JRBarTokens.Space.xs / 2).padding(.horizontal, JRBarTokens.Space.md)
        .frame(minHeight: Self.compactRowHeight)
        .background(hovering ? neutralInk.hover : .clear, in: RoundedRectangle(cornerRadius: JRBarTokens.Radius.control))
        .onHover { hovering = $0 }
    }

    @ViewBuilder private var compactWindows: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                ProviderLogoTile(provider: provider.id, accent: tileAccent, dim: ["not_found", "absent"].contains(provider.availability))
                compactIdentity.frame(width: Self.compactIdentityWidth - 30)
                if !windowNames.isEmpty {
                    ForEach(windowNames, id: \.self) { column($0, compact: true) }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    ProviderLogoTile(provider: provider.id, accent: tileAccent, dim: ["not_found", "absent"].contains(provider.availability))
                    compactIdentity
                }
                if showsWindows {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: compactColumnWidth, maximum: compactColumnWidth), spacing: 10)], alignment: .trailing, spacing: 8) {
                        ForEach(windowNames, id: \.self) { name in
                            VStack(alignment: .trailing, spacing: 4) {
                                Text(name).font(JRBarTokens.TypeStyle.caption.font).foregroundStyle(neutralInk.secondary)
                                column(name, compact: true)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var compactIdentity: some View {
        if status != nil || (isStale && showsWindows) {
            Text(name).font(JRBarTokens.TypeStyle.callout.font).lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            identity
        }
    }

    private var compactReadingStatus: some View {
        let age = UsageGaugeReading.age(provider: provider, now: now, snapshotReceivedAt: snapshotReceivedAt ?? fallbackSnapshotAt)
        return HStack(spacing: JRBarTokens.Space.sm) {
            if let status {
                HStack(spacing: 3) {
                    if provider.quotaSource && provider.availability == "failing" {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(JRBarTokens.Ink.failure)
                    }
                    Text(status).foregroundStyle(provider.quotaSource && provider.availability == "failing" ? neutralInk.label : neutralInk.secondary)
                }
                .fixedSize(horizontal: false, vertical: true).help(status)
            }
            if isStale && showsWindows {
                Label(age, systemImage: "clock").foregroundStyle(neutralInk.stale)
                    .fixedSize().help(age)
            }
            Spacer(minLength: 0)
        }
        .font(JRBarTokens.TypeStyle.caption.font)
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: JRBarTokens.Space.sm) {
            HStack(spacing: 10) {
                ProviderLogoTile(provider: provider.id, accent: tileAccent, dim: ["not_found", "absent"].contains(provider.availability))
                identity
            }
            actions.padding(.leading, 30)
            if showsWindows {
                HStack(alignment: .top, spacing: JRBarTokens.Space.md) {
                    ForEach(windowNames, id: \.self) { column($0, compact: false) }
                }
            }
        }
        .padding(JRBarTokens.Space.md)
    }

    @ViewBuilder private var actions: some View {
        if (onAction != nil && provider.action?.isEmpty == false) || onRetry != nil || fix?.isEmpty == false {
            HStack(spacing: 8) {
                if let fix { Text(fix).font(JRBarTokens.TypeStyle.caption.font).fixedSize(horizontal: false, vertical: true) }
                if let onAction, let title = provider.action, !title.isEmpty {
                    ActionButton(title, action: onAction)
                }
                if let onRetry { ActionButton("Retry", action: onRetry) }
            }
        }
    }

    public func reading(for window: CoreUsageWindow) -> UsageGaugeReading {
        UsageGaugeReading(window: window, provider: provider, now: now, connected: connected,
                          locale: locale, timeZone: timeZone, forecast: forecasts[window.id])
    }

    @ViewBuilder private func column(_ name: String, compact: Bool) -> some View {
        if let window = provider.windows.first(where: { $0.name == name }),
           !compact || (showsWindows && !(reading(for: window).stale && reading(for: window).elapsed)) {
            let reading = reading(for: window)
            Group {
                if compact {
                    CompactUsageGaugeColumn(reading: reading, accent: accent)
                } else {
                    if let onInspect {
                        Button { onInspect(window) } label: {
                            UsageGaugeColumn(reading: reading, accent: accent, compact: false, pace: pace[name])
                        }
                        .buttonStyle(.plain)
                        .help("Inspect \(window.longName) window")
                    } else {
                        UsageGaugeColumn(reading: reading, accent: accent, compact: false, pace: pace[name])
                    }
                }
            }
            .frame(minWidth: compact ? compactColumnWidth : nil, maxWidth: .infinity)
        } else {
            Text("–").font(JRBarTokens.TypeStyle.body.font).foregroundStyle(neutralInk.secondary)
                .frame(width: compact ? Self.compactPercentWidth : nil, alignment: .trailing)
                .frame(minWidth: compact ? compactColumnWidth : nil, maxWidth: .infinity, alignment: compact ? .leading : .center)
                .accessibilityLabel("\(name): no window")
        }
    }
}

private struct CompactUsageGaugeColumn: View {
    @Environment(\.jrbarInk) private var neutralInk
    let reading: UsageGaugeReading
    let accent: Color

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            if let used = reading.percentUsed {
                HStack(spacing: JRBarTokens.Space.xs) {
                    Text(UsageNumber.percent(used))
                        .font(JRBarTokens.TypeStyle.headline.font).monospacedDigit()
                        .foregroundStyle(reading.stale ? neutralInk.stale : neutralInk.label)
                        .frame(width: UsageGaugeRow.compactPercentWidth, alignment: .trailing)
                    JRBarGauge(value: used, tint: accent, stale: reading.stale, height: 4)
                }
            } else {
                Text(reading.elapsed ? UsageStatus.reset.word : UsageStatus.noReading.word)
                    .font((reading.elapsed ? JRBarTokens.TypeStyle.headline : .caption).font).lineLimit(1)
                    .foregroundStyle(reading.elapsed ? JRBarTokens.Ink.reset : neutralInk.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(reading.footnote).font(JRBarTokens.TypeStyle.caption.font)
                .fixedSize(horizontal: true, vertical: false)
                .preference(key: UsageGaugeEvidence.self, value: [reading.id: reading])
                .foregroundStyle(captionColor).lineLimit(1)
                .help(reading.forecastHelp)
        }
        .frame(maxWidth: .infinity)
        .help(reading.forecastHelp)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(reading.title), \(reading.percentUsed.map { UsageWindowLabel.spoken($0) } ?? (reading.elapsed ? UsageStatus.reset.word : UsageStatus.noReading.word)), \(reading.footnote). \(reading.forecastHelp)")
    }

    private var captionColor: Color {
        switch reading.captionTone {
        case .secondary: neutralInk.secondary
        case .attention: Tone.warning.color
        case .failure: Tone.failure.color
        }
    }
}

private struct UsageGaugeColumn: View {
    @Environment(\.jrbarInk) private var neutralInk
    let reading: UsageGaugeReading
    let accent: Color
    let compact: Bool
    let pace: Double?

    var body: some View {
        VStack(alignment: compact ? .trailing : .leading, spacing: 4) {
            if !compact {
                Text("\(reading.title) used").font(JRBarTokens.TypeStyle.callout.font)
                    .foregroundStyle(neutralInk.secondary).lineLimit(1)
            }
            if let used = reading.percentUsed {
                Text(UsageNumber.percent(used))
                    .font((compact ? JRBarTokens.TypeStyle.headline : .title1).font).monospacedDigit()
                    .foregroundStyle(reading.stale ? neutralInk.stale : neutralInk.label)
                JRBarGauge(value: used, tint: accent, stale: reading.stale, height: compact ? 4 : 6, pace: compact ? nil : pace)
            } else {
                Text(reading.elapsed ? UsageStatus.reset.word : UsageStatus.noReading.word)
                    .font((reading.elapsed ? JRBarTokens.TypeStyle.headline : .caption).font).lineLimit(1)
                    .foregroundStyle(reading.elapsed ? JRBarTokens.Ink.reset : neutralInk.secondary)
            }
            Text(reading.resetFootnote).font(JRBarTokens.TypeStyle.caption.font)
                .foregroundStyle(neutralInk.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: compact ? .trailing : .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(reading.title), \(reading.percentUsed.map { UsageWindowLabel.spoken($0) } ?? (reading.elapsed ? UsageStatus.reset.word : UsageStatus.noReading.word)), \(reading.resetFootnote)")
    }
}
