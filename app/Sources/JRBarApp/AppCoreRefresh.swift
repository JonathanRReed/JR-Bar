import Foundation
import JRBarCore

/// Which app refreshers need the newly decoded facts. Retains one prior
/// frame so each refresher can compare the inputs it reads.
struct AppCoreRefresh {
    struct Changes: OptionSet {
        let rawValue: Int
        static let connection = Self(rawValue: 1 << 0)
        static let settings = Self(rawValue: 1 << 1)
        static let roster = Self(rawValue: 1 << 2)
        static let usage = Self(rawValue: 1 << 3)
        static let devices = Self(rawValue: 1 << 4)
        static let lights = Self(rawValue: 1 << 5)
        var refreshesAggregate: Bool { !intersection([.roster, .connection]).isEmpty }
        static let all: Self = [.connection, .settings, .roster, .usage, .devices, .lights]
    }
    /// Clock inputs keep changing between daemon frames. Use one wake for
    /// countdowns, elapsed labels and pending writes, at their next boundary.
    static func nextTick(askTick: Double?, usage: [CoreProviderUsage], elapsedSince: [Double] = [],
                         deadlines: [Double] = [], now: Double) -> Double? {
        let resets = usage.flatMap(\.windows).compactMap(\.resetsAt)
            .filter { $0.isFinite && $0 > now }
        var candidates = resets + deadlines + [askTick].compactMap { $0 }
        if !resets.isEmpty { candidates.append((floor(now / 60) + 1) * 60) }
        for since in elapsedSince where since.isFinite {
            let age = max(0, now - since)
            // Whole minutes, then whole hours. This wake redraws the menu
            // bar icon's tooltip lines and nothing a person watches by the
            // second: a working row's clock restarts with every hook event,
            // so a one-second step under a minute ran the whole refresh
            // once a second for as long as any agent worked. The panel and
            // the notch card keep their own clocks while they are open.
            let step: Double = age < 86_400 ? 60 : 3_600
            let boundary = floor(age / step) + 1
            candidates.append(since + boundary * step)
        }
        return candidates.filter { $0.isFinite && $0 > now }.min()
    }

    private var previous: Snapshot?

    @MainActor
    private struct Snapshot {
        let live: Bool
        let connection: CoreModel.Connection
        let state: CoreState?
        let settings: CoreSettings?
        let lights: CoreLights?
        let hello: CoreHello?
        init(_ core: CoreModel) {
            live = core.isLive
            connection = core.connection
            state = core.state
            settings = core.settings
            lights = core.lights
            hello = core.hello
        }
    }

    @MainActor
    mutating func take(_ core: CoreModel) -> Changes {
        let next = Snapshot(core)
        defer { previous = next }
        guard let old = previous else { return .all }
        var changes: Changes = []
        let liveChanged = old.live != next.live
        if old.connection != next.connection || old.hello != next.hello || liveChanged {
            changes.insert(.connection)
        }
        if old.settings != next.settings { changes.insert(.settings) }
        let a = old.state, b = next.state
        let sessionsChanged = a?.sessions != b?.sessions || a?.asks != b?.asks
        let aggregateChanged = a?.aggregate != b?.aggregate || a?.escalation != b?.escalation
        let completionsChanged = a?.unseenCompletions != b?.unseenCompletions || a?.hiddenCount != b?.hiddenCount
        let contextChanged = a?.power != b?.power || a?.focus != b?.focus || a?.presence != b?.presence
        if liveChanged || sessionsChanged || aggregateChanged || completionsChanged || contextChanged {
            changes.insert(.roster)
        }
        if liveChanged || a?.usage != b?.usage { changes.insert(.usage) }
        if liveChanged || a?.devices != b?.devices { changes.insert(.devices) }
        if liveChanged || old.lights != next.lights { changes.insert(.lights) }
        return changes
    }
}
