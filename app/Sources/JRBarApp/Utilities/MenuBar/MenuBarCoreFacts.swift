import Foundation
import JRBarCore

/// What the daemon's feed says, in the shape the menu bar's rules read:
/// the agents' combined state, whether an ask is open, the tightest
/// usage headroom, and whether SidePulse hardware is attached. These are
/// the facts only an integrated app has — a standalone menu-bar manager
/// cannot see what your agents are doing.
///
/// The app delegate hands the utility a closure that builds these from
/// `CoreModel` and pokes `coreFactsChanged()` on every core change; the
/// utility turns a moved value into a trigger sample. Pure over its
/// inputs so a test pins the reductions.
struct MenuBarCoreFacts: Equatable, Sendable {
    /// Whether the daemon's feed is live. A dead feed says nothing, so
    /// the samples below are withheld rather than read as "idle".
    var live = false
    var agent: AgentAggregateState = .idle
    var askPending = false
    /// The tightest measured window's remaining share, 0…100; nil while
    /// nothing is measured.
    var quotaRemaining: Int?
    var sidePulsePresent = false

    /// The device kinds that are SidePulse hardware — the strip and the
    /// Dot. The Screen Bar is ours and virtual; it never counts.
    nonisolated static let sidePulseKinds: Set<String> = ["pro", "dot"]

    /// Whether any SidePulse device is present on the daemon's list.
    nonisolated static func sidePulsePresent(_ devices: [CoreDevice]) -> Bool {
        devices.contains { sidePulseKinds.contains($0.kind) && $0.isPresent }
    }

    /// The least headroom any bindable, measured window has left, in
    /// whole percent — nil when no window states a number. An unmeasured
    /// window is never read as empty or full.
    nonisolated static func tightestRemaining(_ usage: [CoreProviderUsage]) -> Int? {
        let remaining = usage.flatMap(\.windows)
            .filter(\.bindable)
            .compactMap { $0.usedPct.map { max(0, min(100, 100 - $0)) } }
        return remaining.min().map { Int($0.rounded(.down)) }
    }

    /// The facts from a live model and the panel's merged aggregate.
    @MainActor
    static func read(core: CoreModel, aggregate: AgentAggregateState) -> MenuBarCoreFacts {
        guard core.isLive else { return MenuBarCoreFacts() }
        return MenuBarCoreFacts(live: true, agent: aggregate,
                                askPending: !core.openAsks.isEmpty || aggregate == .needsInput,
                                quotaRemaining: tightestRemaining(core.usage),
                                sidePulsePresent: sidePulsePresent(core.devices))
    }

    /// The trigger samples that moved between two reads, in a fixed
    /// order. A dead feed pushes nothing; the first live read pushes
    /// everything it knows (the engine treats it as the baseline).
    nonisolated static func samples(from old: MenuBarCoreFacts?,
                                    to new: MenuBarCoreFacts) -> [MenuBarTriggerEvent] {
        guard new.live else { return [] }
        let fresh = old?.live != true
        var events: [MenuBarTriggerEvent] = []
        if fresh || old?.agent != new.agent { events.append(.agentState(new.agent)) }
        if let quota = new.quotaRemaining, fresh || old?.quotaRemaining != quota {
            events.append(.quotaRemaining(quota))
        }
        if fresh || old?.sidePulsePresent != new.sidePulsePresent {
            events.append(.sidePulsePresent(new.sidePulsePresent))
        }
        return events
    }
}
