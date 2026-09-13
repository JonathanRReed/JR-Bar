import Foundation

/// Everything the notch island shows, reduced to plain data so the view
/// never walks `CoreSession`s and the panel never guesses its own size:
/// `summarize` makes the idle dots, the live rows and the status line in
/// one pass; `meters` picks each provider's headline usage window;
/// `AlcoveIslandLayout` owns the frame math that hangs the panel under
/// the notch. Pure, so `AlcoveIslandTests` pins it without a screen.
public struct AlcoveIslandRow: Equatable, Sendable, Identifiable {
    /// The session id.
    public var id: String
    /// `SessionLabel.display`: short, no UUID, no leading provider name.
    public var label: String
    /// The provider id — the app resolves its name and colour.
    public var provider: String
    public var activity: SessionActivity

    public init(id: String, label: String, provider: String, activity: SessionActivity) {
        self.id = id
        self.label = label
        self.provider = provider
        self.activity = activity
    }
}

/// One provider's headline meter in the expanded card: its first usage
/// window's reading. `percent` nil is a stated unknown, never a zero —
/// the same contract `CoreUsageWindow.usedPct` carries.
public struct AlcoveIslandMeter: Equatable, Sendable, Identifiable {
    /// `CoreProviderUsage.identity` — stable across multi-account rows.
    public var id: String
    public var provider: String
    /// The window's short name (`5h`, `7d`, `Daily`).
    public var window: String
    public var percent: Double?

    public init(id: String, provider: String, window: String, percent: Double?) {
        self.id = id
        self.provider = provider
        self.window = window
        self.percent = percent
    }

    /// `42%`, or `—` when the provider stated no number.
    public var percentText: String { UsageWindowLabel.percent(percent) }
}

public struct AlcoveIslandSummary: Equatable, Sendable {
    public var working = 0
    public var waiting = 0
    public var failed = 0
    /// Providers with working sessions, busiest first, id tiebreak — the
    /// idle capsule's dots, in order.
    public var workingProviders: [String] = []
    /// The live sessions (working, waiting, failed) in the panel's
    /// precedence — the expanded card's rows, uncapped; the caller
    /// truncates at `AlcoveIsland.rowLimit`.
    public var rows: [AlcoveIslandRow] = []
    /// "3 working · 1 waiting" — the header and the accessibility value.
    public var statusLine = "Nothing on the clock"

    public init() {}
}

public enum AlcoveIsland {
    /// Rows the expanded card shows before a "+N more" line.
    public static let rowLimit = 5
    /// Usage meters the card shows.
    public static let meterLimit = 3
    /// Provider dots the idle capsule shows.
    public static let dotLimit = 6

    /// One pass over the session list: the counts, the working-provider
    /// dots, the live rows and the status line all fall out of the same
    /// `SessionActivity.reduce` calls, the way `NotchBuddyToy.summary`
    /// keeps its pieces from disagreeing.
    public static func summarize(_ sessions: [CoreSession]) -> AlcoveIslandSummary {
        var s = AlcoveIslandSummary()
        var tally: [String: Int] = [:]
        for session in sessions {
            let activity = SessionActivity.reduce(session)
            switch activity {
            case .working:
                s.working += 1
                tally[session.provider, default: 0] += 1
            case .waiting: s.waiting += 1
            case .failed: s.failed += 1
            case .done, .ended, .idle: break
            }
            switch activity {
            case .working, .waiting, .failed:
                s.rows.append(AlcoveIslandRow(
                    id: session.id,
                    label: SessionLabel.display(label: session.label, shortId: session.shortId,
                                                id: session.id, provider: session.provider),
                    provider: session.provider,
                    activity: activity))
            case .done, .ended, .idle: break
            }
        }
        // Busiest first; the id tiebreak keeps a split house from
        // flickering between ticks, the same rule the buddy uses.
        s.workingProviders = tally.keys.sorted { a, b in
            tally[a]! != tally[b]! ? tally[a]! > tally[b]! : a < b
        }
        s.rows.sort { a, b in
            a.activity.sortRank != b.activity.sortRank
                ? a.activity.sortRank < b.activity.sortRank
                : a.label.localizedCaseInsensitiveCompare(b.label) == .orderedAscending
        }
        var parts: [String] = []
        if s.working > 0 { parts.append("\(s.working) working") }
        if s.waiting > 0 { parts.append("\(s.waiting) waiting") }
        if s.failed > 0 { parts.append("\(s.failed) failed") }
        if !parts.isEmpty { s.statusLine = parts.joined(separator: " · ") }
        return s
    }

    /// Each provider's first window as a meter — the headline reading —
    /// skipping providers that carry no windows at all. Ordered as the
    /// daemon sent them, capped at `meterLimit`.
    public static func meters(_ usage: CoreUsage?) -> [AlcoveIslandMeter] {
        (usage?.providers ?? []).compactMap { provider in
            guard let window = provider.windows.first else { return nil }
            return AlcoveIslandMeter(id: provider.identity, provider: provider.id,
                                     window: window.shortName, percent: window.usedPct)
        }.prefix(meterLimit).map { $0 }
    }

    /// The idle content's width: `dotLimit`-capped provider dots plus the
    /// waiting/failed dots, the live count, and the spacing between them —
    /// deterministic, so the panel sizes itself without asking the view
    /// and nothing invisible hangs over the menu bar.
    public static func idleContentWidth(_ summary: AlcoveIslandSummary) -> CGFloat {
        let dots = min(summary.workingProviders.count, dotLimit)
            + (summary.waiting > 0 ? 1 : 0) + (summary.failed > 0 ? 1 : 0)
        let live = summary.working + summary.waiting + summary.failed
        guard dots > 0 else { return 4 }   // the lone resting dot
        var width = CGFloat(dots) * 5 + CGFloat(dots - 1) * 4
        if live > 0 { width += 4 + (live < 100 ? 14 : 22) }
        return width
    }
}

/// The island's frame math. The panel is exactly the drawn shape — a
/// capsule pinned to the screen's top edge, centred on the notch slot —
/// so a transparent window never swallows a menu-bar click.
public enum AlcoveIslandLayout {
    /// Points the idle capsule reaches past each shoulder of the notch.
    public static let shoulder: CGFloat = 12
    public static let idleMinWidth: CGFloat = 96
    public static let expandedWidth: CGFloat = 300
    /// Room the frame leaves at the screen's side edges.
    public static let edgeMargin: CGFloat = 8
    /// On a notch-less screen the island floats this far under the top
    /// edge instead of hugging it.
    public static let floatingTopInset: CGFloat = 6
    /// Clearance the expanded card's content keeps under the notch.
    public static let expandedNotchInset: CGFloat = 8

    /// The notch slot — centre and width — from the screen's menu-bar
    /// areas (`auxiliaryTopLeftArea`/`auxiliaryTopRightArea`), nil where
    /// there is no notch to measure.
    public static func slot(left: CGRect?, right: CGRect?) -> (centerX: CGFloat, width: CGFloat)? {
        guard let left, let right else { return nil }
        let width = right.minX - left.maxX
        guard width > 0 else { return nil }
        return ((left.maxX + right.minX) / 2, width)
    }

    /// Points of dead space the island keeps under the notch while the
    /// Screen Bar is live, on the faces that drop below the notch (the
    /// notice capsule and the expanded card): the LED band ends ~8 pt
    /// below the notch (6 pt of band plus the halo bleed) and the
    /// island's window sits one level under the bar, so content clears
    /// the strip. The idle face needs none — it tucks into the notch's
    /// own depth, ending flush with the hardware's bottom edge.
    public static let ledBandClearance: CGFloat = 12

    /// The collapsed capsule: at least as wide as the notch plus a small
    /// shoulder each side — the island reads as the notch grown, not a
    /// pill parked beside it — and exactly the notch's depth, so at rest
    /// nothing but the Screen Bar's band draws below the hardware.
    /// Notch-less screens get a floating pill sized to the content.
    public static func idleSize(slotWidth: CGFloat, notchDepth: CGFloat, contentWidth: CGFloat) -> CGSize {
        guard notchDepth > 0 else {
            return CGSize(width: max(idleMinWidth, contentWidth + 24), height: 24)
        }
        return CGSize(width: max(idleMinWidth, slotWidth + 2 * shoulder, contentWidth + 28),
                      height: notchDepth)
    }

    /// The expanded card's window height: the notch clearance (the card's
    /// content starts below the hardware) plus the media row, the session
    /// rows, the meters and the paddings — all fixed heights, so the view
    /// and the frame agree to the point. `ledClearance` raises the
    /// content start past a live Screen Bar's band and halo.
    public static func expandedHeight(notchDepth: CGFloat, rows: Int, meters: Int,
                                      overflow: Bool, media: Bool = false,
                                      ledClearance: CGFloat = 0) -> CGFloat {
        let inset = notchDepth > 0 ? notchDepth + expandedNotchInset + ledClearance : 8
        var card: CGFloat = 20                              // header line
        if media { card += 40 }                             // Now Playing row + divider
        card += CGFloat(max(0, rows)) * 22                  // session rows
        if overflow { card += 18 }                          // "+N more"
        if meters > 0 { card += 10 + CGFloat(meters) * 18 } // divider + meters
        card += 12                                          // bottom padding
        return inset + card
    }

    /// The window's frame: centred on `centerX`, its top edge `topInset`
    /// below the screen's top edge, clamped inside the screen with
    /// `edgeMargin` to spare.
    public static func frame(screenFrame: CGRect, centerX: CGFloat, size: CGSize, topInset: CGFloat = 0) -> CGRect {
        let width = min(size.width, max(0, screenFrame.width - 2 * edgeMargin))
        let x = min(screenFrame.maxX - edgeMargin - width,
                    max(screenFrame.minX + edgeMargin, centerX - width / 2))
        return CGRect(x: x, y: screenFrame.maxY - max(0, topInset) - size.height,
                      width: width, height: size.height)
    }
}
