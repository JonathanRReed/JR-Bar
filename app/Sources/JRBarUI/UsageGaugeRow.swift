import Foundation
import JRBarCore
import SwiftUI

/// A window's display at the caller's clock. Expired numbers never become current.
public struct UsageGaugeReading: Equatable, Sendable {
    public let title: String
    public let percentUsed: Double?
    public let stale: Bool
    public let elapsed: Bool
    public let footnote: String

    public init(window: CoreUsageWindow, provider: CoreProviderUsage, now: Double, connected: Bool = true,
                locale: Locale = .current, timeZone: TimeZone = .current) {
        title = window.name
        elapsed = window.elapsed || (window.resetsAt.map { $0 <= now } ?? false)
        stale = !connected || provider.isStale || ["missing_recent", "source_idle", "failing"].contains(provider.availability)
        let suppressed = ["absent", "not_found"].contains(provider.availability) || provider.usageIsOff || !provider.quotaSource
        let measured = window.usedPct.flatMap { $0.isFinite ? min(100, max(0, $0)) : nil }
        percentUsed = elapsed || suppressed ? nil : measured
        if elapsed {
            footnote = window.resetsAt.map { "\(Self.interval(now - $0)) ago" } ?? "Awaiting reading"
        } else {
            footnote = window.resetsAt.map { Self.resetTime($0, now: now, locale: locale, timeZone: timeZone) } ?? ""
        }
    }

    public static func resetTime(_ reset: Double, now: Double, locale: Locale, timeZone: TimeZone) -> String {
        guard reset.isFinite, now.isFinite else { return "" }
        let remaining = reset - now
        if remaining <= 0 { return "\(interval(-remaining)) ago" }
        if remaining < 3600 { return "in \(interval(remaining))" }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let date = Date(timeIntervalSince1970: reset)
        let today = calendar.isDate(date, inSameDayAs: Date(timeIntervalSince1970: now))
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate(today ? "jm" : "EEEj")
        return formatter.string(from: date)
    }

    public static func age(provider: CoreProviderUsage, now: Double, snapshotReceivedAt: Double) -> String {
        let seconds = provider.readingAt.map { now - $0 }
            ?? provider.lastGoodAgeSeconds.map { $0 + max(0, now - snapshotReceivedAt) }
        return seconds.map { "Read \(interval($0)) ago" } ?? "Reading age unknown"
    }

    static func interval(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "unknown" }
        let minutes = max(0, seconds / 60)
        if minutes < 1 { return "<1m" }
        if minutes < 60 { return "\(Int(minutes))m" }
        let hours = Int(minutes / 60)
        let remainder = Int(minutes.truncatingRemainder(dividingBy: 60))
        if minutes < 1440 { return remainder == 0 ? "\(hours)h" : "\(hours)h \(remainder)m" }
        let days = Int(minutes / 1440)
        let extraHours = hours % 24
        return extraHours == 0 ? "\(days)d" : "\(days)d \(extraHours)h"
    }
}

/// Render this once above compact rows. Pass the same windowNames to every row.
public struct UsageGaugeHeader: View {
    @Environment(\.jrbarInk) private var neutralInk
    public let windowNames: [String]
    public init(windowNames: [String]) { self.windowNames = UsageGaugeRow.orderedWindowNames(windowNames) }

    public var body: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)
            ForEach(windowNames, id: \.self) { name in
                Text("\(name) used").font(JRBarTokens.TypeStyle.caption.font)
                    .foregroundStyle(neutralInk.secondary).lineLimit(1).truncationMode(.tail)
                    .frame(width: UsageGaugeRow.columnWidth, alignment: .trailing)
            }
        }
        .padding(.horizontal, 12).padding(.bottom, 2)
    }
}

/// A provider's independent quota windows. This view starts no polling or clock.
public struct UsageGaugeRow: View {
    @Environment(\.jrbarInk) private var neutralInk
    public enum Style: Sendable { case compact, detail }
    public static let columnWidth: CGFloat = 64
    public let provider: CoreProviderUsage
    public let name: String
    public let now: Double
    public let connected: Bool
    public let accent: Color
    private let tileAccent: Color?
    public let style: Style
    public let windowNames: [String]
    public let snapshotReceivedAt: Double?
    public let locale: Locale
    public let timeZone: TimeZone
    public let fix: String?
    public let onAction: (() -> Void)?
    public let onRetry: (() -> Void)?
    public let pace: [String: Double]
    @UIState private var fallbackSnapshotAt: Double
    @UIState private var hovering = false

    public init(provider: CoreProviderUsage, name: String, now: Double, connected: Bool = true,
                accent: Color? = nil, style: Style = .detail, windowNames: [String]? = nil,
                snapshotReceivedAt: Double? = nil, locale: Locale = .current, timeZone: TimeZone = .current,
                pace: [String: Double] = [:], fix: String? = nil,
                onAction: (() -> Void)? = nil, onRetry: (() -> Void)? = nil) {
        self.provider = provider
        self.name = name
        self.now = now
        self.connected = connected
        self.accent = accent ?? ProviderPalette.color(for: provider.id)
        self.tileAccent = accent
        self.style = style
        self.windowNames = Self.orderedWindowNames(windowNames ?? provider.windows.map(\.name))
        self.snapshotReceivedAt = snapshotReceivedAt
        self.locale = locale
        self.timeZone = timeZone
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

    private var showsWindows: Bool {
        !["absent", "not_found"].contains(provider.availability) && provider.quotaSource && !provider.usageIsOff && !provider.windows.isEmpty
    }
    private var isStale: Bool {
        !connected || provider.isStale || ["missing_recent", "source_idle", "failing"].contains(provider.availability)
    }
    private var status: String? {
        if !connected { return "Disconnected" }
        if provider.availability == "not_found" { return provider.statusText ?? "Not found on this Mac" }
        if provider.usageIsOff { return provider.statusText ?? "Usage is off" }
        if !provider.quotaSource { return "Sessions only" }
        return provider.statusText ?? (showsWindows ? nil : "No quota reading")
    }

    public var body: some View {
        if provider.availability != "absent" {
            Group {
                if style == .compact { compact } else { detail }
            }
            .foregroundStyle(neutralInk.label)
            .onChange(of: provider) { _, _ in fallbackSnapshotAt = now }
        }
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(name).font(JRBarTokens.TypeStyle.headline.font).lineLimit(1).truncationMode(.tail)
                .layoutPriority(1)
            if let status {
                HStack(spacing: 3) {
                    if provider.availability == "failing" {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(JRBarTokens.Ink.failure)
                    }
                    Text(status).foregroundStyle(provider.availability == "failing" ? neutralInk.label : neutralInk.secondary)
                }
                .font(JRBarTokens.TypeStyle.caption.font).lineLimit(1).truncationMode(.tail)
                .help(status)
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
                    Text(name).font(JRBarTokens.TypeStyle.headline.font).lineLimit(1)
                    Text(status ?? "Not found on this Mac").font(JRBarTokens.TypeStyle.caption.font)
                        .foregroundStyle(neutralInk.secondary).lineLimit(1).truncationMode(.tail)
                        .help(status ?? "Not found on this Mac")
                    Spacer(minLength: 0)
                    if let onAction, let title = provider.action, !title.isEmpty {
                        Button(title, action: onAction).controlSize(.small)
                    }
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        ProviderLogoTile(provider: provider.id, accent: tileAccent, dim: provider.availability == "not_found")
                        identity.frame(minWidth: 60, idealWidth: 60, maxWidth: .infinity)
                        if showsWindows {
                            ForEach(windowNames, id: \.self) { column($0, compact: true) }
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            ProviderLogoTile(provider: provider.id, accent: tileAccent, dim: provider.availability == "not_found")
                            identity
                        }
                        if showsWindows {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.columnWidth, maximum: Self.columnWidth), spacing: 10)], alignment: .trailing, spacing: 8) {
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
                actions.padding(.leading, 30)
            }
        }
        .padding(.vertical, 7).padding(.horizontal, 12)
        .frame(minHeight: 44)
        .background(hovering ? neutralInk.hover : .clear, in: RoundedRectangle(cornerRadius: JRBarTokens.Radius.control))
        .onHover { hovering = $0 }
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: JRBarTokens.Space.sm) {
            HStack(spacing: 10) {
                ProviderLogoTile(provider: provider.id, accent: tileAccent, dim: provider.availability == "not_found")
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
                    Button(title, action: onAction).controlSize(.small)
                }
                if let onRetry { Button("Retry", action: onRetry).controlSize(.small) }
            }
        }
    }

    @ViewBuilder private func column(_ name: String, compact: Bool) -> some View {
        if let window = provider.windows.first(where: { $0.name == name }) {
            let reading = UsageGaugeReading(window: window, provider: provider, now: now, connected: connected,
                                            locale: locale, timeZone: timeZone)
            UsageGaugeColumn(reading: reading, accent: accent, compact: compact, pace: pace[name])
                .frame(width: compact ? Self.columnWidth : nil)
                .frame(maxWidth: compact ? nil : .infinity)
        } else {
            Text("–").font(JRBarTokens.TypeStyle.body.font).foregroundStyle(neutralInk.secondary)
                .frame(width: compact ? Self.columnWidth : nil, alignment: .trailing)
                .frame(maxWidth: compact ? nil : .infinity)
                .accessibilityLabel("\(name): no window")
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
                Text("\(Int(used.rounded()))%")
                    .font((compact ? JRBarTokens.TypeStyle.headline : .title1).font).monospacedDigit()
                    .foregroundStyle(reading.stale ? neutralInk.stale : neutralInk.label)
                JRBarGauge(value: used, tint: accent, stale: reading.stale, height: compact ? 4 : 6, pace: compact ? nil : pace)
            } else {
                Text(reading.elapsed ? "Reset" : "No reading")
                    .font((reading.elapsed ? JRBarTokens.TypeStyle.headline : .caption).font).lineLimit(1)
                    .foregroundStyle(reading.elapsed ? JRBarTokens.Ink.reset : neutralInk.secondary)
            }
            Text(reading.footnote).font(JRBarTokens.TypeStyle.caption.font)
                .foregroundStyle(neutralInk.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: compact ? .trailing : .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(reading.title), \(reading.percentUsed.map { "\(Int($0.rounded())) percent used" } ?? (reading.elapsed ? "Reset" : "No reading")), \(reading.footnote)")
    }
}
