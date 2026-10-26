import JRBarCore
import SwiftUI

/// A window's display at a supplied time. Expired numbers never become current.
public struct UsageGaugeReading: Equatable, Sendable {
    public let title: String
    public let percentUsed: Double?
    public let stale: Bool
    public let elapsed: Bool
    public let footnote: String

    public init(window: CoreUsageWindow, provider: CoreProviderUsage, now: Double, connected: Bool = true) {
        title = window.name
        elapsed = window.resetsAt.map { $0 <= now } ?? false
        stale = !connected || provider.isStale || ["missing_recent", "source_idle", "failing"].contains(provider.availability)
        let suppressed = ["absent", "not_found"].contains(provider.availability)
        let measured = window.usedPct.flatMap { $0.isFinite ? min(100, max(0, $0)) : nil }
        percentUsed = elapsed || suppressed ? nil : measured
        if elapsed {
            footnote = "Reset \(Self.interval(now - (window.resetsAt ?? now))) ago · awaiting reading"
        } else if suppressed {
            footnote = provider.statusText ?? "Not found on this Mac"
        } else {
            let reset = window.resetsAt.map { "Resets in \(Self.interval($0 - now))" } ?? "Reset time unavailable"
            if stale {
                let age = provider.readingAt.map { now - $0 } ?? provider.lastGoodAgeSeconds
                let ageText = age.map { "\(Self.interval($0)) ago" } ?? "age unknown"
                footnote = "Read \(ageText) · \(reset)"
            } else {
                footnote = reset
            }
        }
    }

    static func interval(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "unknown" }
        let minutes = max(0, seconds / 60)
        if minutes < 1 { return "<1m" }
        if minutes < 60 { return "\(Int(minutes))m" }
        if minutes < 1440 { return "\(Int(minutes / 60))h \(Int(minutes.truncatingRemainder(dividingBy: 60)))m" }
        return "\(Int(minutes / 1440))d \(Int((minutes / 60).truncatingRemainder(dividingBy: 24)))h"
    }
}

/// A provider's independent quota windows, with the daemon's availability facts.
/// Pass `now` from the owning page's clock; this view starts no timer or request.
public struct UsageGaugeRow: View {
    public let provider: CoreProviderUsage
    public let name: String
    public let now: Double
    public let connected: Bool
    public let accent: Color
    public let onAction: (() -> Void)?

    public init(provider: CoreProviderUsage, name: String, now: Double, connected: Bool = true,
                accent: Color? = nil, onAction: (() -> Void)? = nil) {
        self.provider = provider
        self.name = name
        self.now = now
        self.connected = connected
        self.accent = accent ?? ProviderPalette.color(for: provider.id)
        self.onAction = onAction
    }

    private var showsWindows: Bool {
        !["absent", "not_found"].contains(provider.availability) && !provider.windows.isEmpty
    }

    public var body: some View {
        if provider.availability != "absent" {
            VStack(alignment: .leading, spacing: JRBarTokens.Space.sm) {
                HStack(spacing: JRBarTokens.Space.sm) {
                    ProviderLogoTile(provider: provider.id, accent: accent)
                    Text(name).fontWeight(.semibold)
                    Spacer(minLength: JRBarTokens.Space.sm)
                    if let status = provider.statusText {
                        HStack(spacing: JRBarTokens.Space.xs) {
                            if provider.availability == "failing" {
                                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(JRBarTokens.Ink.failure)
                            }
                            Text(status).foregroundStyle(JRBarTokens.Ink.stale)
                        }
                        .font(JRBarTokens.TypeStyle.caption.font)
                    }
                    if let onAction, let title = provider.action, !title.isEmpty {
                        Button(title, action: onAction).controlSize(.small)
                    }
                }
                if showsWindows {
                    HStack(alignment: .top, spacing: JRBarTokens.Space.lg) {
                        ForEach(Array(provider.windows.enumerated()), id: \.offset) { _, window in
                            UsageGaugeColumn(reading: UsageGaugeReading(window: window, provider: provider, now: now,
                                                                       connected: connected), accent: accent)
                        }
                    }
                } else if provider.statusText == nil {
                    Text(provider.action ?? (provider.quotaSource ? "No quota reading" : "Sessions only, no quota source"))
                        .font(JRBarTokens.TypeStyle.caption.font)
                        .foregroundStyle(JRBarTokens.Ink.secondary)
                }
            }
            .font(JRBarTokens.TypeStyle.body.font)
            .foregroundStyle(JRBarTokens.Ink.label)
            .padding(JRBarTokens.Space.md)
        }
    }
}

private struct UsageGaugeColumn: View {
    let reading: UsageGaugeReading
    let accent: Color

    private var tint: Color { reading.stale ? JRBarTokens.Ink.stale : accent }

    var body: some View {
        VStack(alignment: .leading, spacing: JRBarTokens.Space.xs) {
            HStack(spacing: JRBarTokens.Space.sm) {
                Text(reading.title).foregroundStyle(JRBarTokens.Ink.secondary)
                Spacer(minLength: 0)
                if let used = reading.percentUsed {
                    Text("\(Int(used.rounded()))% used").monospacedDigit()
                        .foregroundStyle(reading.stale ? JRBarTokens.Ink.stale : JRBarTokens.Ink.label)
                } else {
                    Text(reading.elapsed ? "Reset" : "No reading")
                        .foregroundStyle(reading.elapsed ? JRBarTokens.Ink.reset : JRBarTokens.Ink.secondary)
                }
            }
            .font(JRBarTokens.TypeStyle.callout.font)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(JRBarTokens.Ink.tertiaryFill)
                    if let used = reading.percentUsed {
                        Capsule().fill(tint).frame(width: geometry.size.width * used / 100)
                    }
                }
            }
            .frame(height: JRBarTokens.Space.xs)
            HStack(alignment: .firstTextBaseline, spacing: JRBarTokens.Space.xs) {
                if reading.stale { Image(systemName: "clock") }
                Text(reading.footnote).fixedSize(horizontal: false, vertical: true)
            }
            .font(JRBarTokens.TypeStyle.caption.font)
            .foregroundStyle(reading.stale ? JRBarTokens.Ink.stale : JRBarTokens.Ink.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}
