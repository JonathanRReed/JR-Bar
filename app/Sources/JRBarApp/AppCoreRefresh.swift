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
            let step: Double
            if age < 60 { step = 1 }
            else if age < 86_400 { step = 60 }
            else { step = 3_600 }
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
        if liveChanged || a?.sessions != b?.sessions || a?.asks != b?.asks
            || a?.aggregate != b?.aggregate || a?.escalation != b?.escalation
            || a?.unseenCompletions != b?.unseenCompletions || a?.hiddenCount != b?.hiddenCount
            || a?.power != b?.power || a?.focus != b?.focus || a?.presence != b?.presence {
            changes.insert(.roster)
        }
        if liveChanged || a?.usage != b?.usage { changes.insert(.usage) }
        if liveChanged || a?.devices != b?.devices { changes.insert(.devices) }
        if liveChanged || old.lights != next.lights { changes.insert(.lights) }
        return changes
    }
}
