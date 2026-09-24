import JRBarCore
import SwiftUI

/// What a usage card says about where its numbers come from, and about
/// the numbers that are only detail.
///
/// Two honesty rules live here. A provider that has no quota for this
/// account (OpenCode without an OpenCode Go subscription) says so in a
/// sentence instead of drawing an empty ring. And a window the provider's
/// own catalog does not bind (`bindable: false`, OpenCode Go's monthly
/// figure, a Codex model sub-cap) is shown as a line of detail under the
/// rings, never as a ring that looks like the account's limit.
enum UsageSourceNotes {
    /// The card's sentence when the daemon says this reading can carry no
    /// quota at all (`quota_source: false`); nil when it can.
    static func noQuotaLine(_ provider: CoreProviderUsage, name: String) -> String? {
        guard !provider.quotaSource else { return nil }
        switch provider.reason {
        case "opencode_go_not_subscribed":
            return "This OpenCode key has no Go subscription, so there is no quota to show. Token totals still count."
        case "opencode_no_quota_source":
            return "OpenCode reports no quota on this Mac. Add an OpenCode Go key to see its limits; token totals still count."
        default:
            return "\(name) reports no quota for this account. Token totals still count."
        }
    }

    /// The windows drawn as rings: the bindable ones when there are any,
    /// else every window (a provider whose lanes are all detail, such as
    /// Gemini's per-model pools, still gets its rings).
    static func ringWindows(_ windows: [CoreUsageWindow]) -> [CoreUsageWindow] {
        let bound = windows.filter(\.bindable)
        return bound.isEmpty ? windows : bound
    }

    /// The windows shown as detail under the rings: the unbound ones, but
    /// only when some window is bound (otherwise they are the rings).
    static func detailWindows(_ windows: [CoreUsageWindow]) -> [CoreUsageWindow] {
        guard windows.contains(where: \.bindable) else { return [] }
        return windows.filter { !$0.bindable }
    }

    /// Where the card's numbers came from, when that is not the provider's
    /// own usage endpoint: Claude Code's status line stands in while the
    /// OAuth read is rate limited or signed out, and CLIProxyAPI reads an
    /// account this Mac does not sign in to itself. Nil for a direct read.
    static func sourceCaption(_ provider: CoreProviderUsage) -> String? {
        let sources = Set(provider.windows.compactMap(\.source))
        if sources.contains("claude-statusline") { return "via Claude Code" }
        if sources.contains("cliproxy") || isHubInstance(provider.instance) { return "via CLIProxyAPI" }
        return nil
    }

    /// Instances the CLIProxyAPI hub adds are named `cliproxy:<hash>`.
    static func isHubInstance(_ instance: String?) -> Bool {
        instance?.hasPrefix("cliproxy:") == true
    }

    /// The badge that tells two accounts of one provider apart: the
    /// instance id, except a hub account, whose hash means nothing to a
    /// person and whose account line already names it.
    static func instanceBadge(_ instance: String) -> String {
        isHubInstance(instance) ? "CLIProxyAPI" : instance
    }

    /// "1 reset credit" / "3 reset credits": unused limit resets the
    /// provider reports, shown as a count. The app never redeems one.
    static func resetCreditsText(_ count: Int?) -> String? {
        guard let count, count > 0 else { return nil }
        return count == 1 ? "1 reset credit" : "\(count) reset credits"
    }

    /// One detail window in words: "Monthly 7% used, resets in 6d 4h".
    static func detailText(_ window: CoreUsageWindow, now: Date, fix: String?) -> String {
        let reading = window.isUnknown ? "no reading" : "\(window.percentText) used"
        guard let reset = PanelStore.countdown(to: window.resetsAt, now: now, fix: fix) else {
            return "\(window.longName) \(reading)"
        }
        return "\(window.longName) \(reading), \(reset)"
    }
}

/// The detail windows under a card's rings, as one quiet line.
struct UsageDetailWindowsLine: View {
    let windows: [CoreUsageWindow]
    let now: Date
    let fix: String?

    private var text: String {
        windows.map { UsageSourceNotes.detailText($0, now: now, fix: fix) }.joined(separator: " · ")
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("Also reported")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
        }
        .help("Shown for reference. These windows are not the account's limit, so they never drive the lights or an alert.")
        .accessibilityElement(children: .combine)
    }
}
