import AppKit
import IOKit.ps
import JRBarCore

/// The one IOKit power poll in the app. The island's charging capsule,
/// the card's battery row and the Screen Bar's ear notice each used to
/// run their own 5 s `IOPSCopyPowerSourcesInfo` timer over the same
/// battery; they now subscribe here, and the timer runs only while at
/// least one of them is listening. Changes fan out as (old, new) — old
/// nil on the feed's very first reading, the baseline nobody announces.
@MainActor
final class AlcovePowerFeed {
    static let shared = AlcovePowerFeed()
    static let interval: TimeInterval = 5

    /// The last reading, nil while nobody listens.
    private(set) var latest: AlcovePowerState?
    /// The read itself — IOKit in production; tests stage readings.
    var read: @MainActor () -> AlcovePowerState = { AlcovePowerMonitor.read() }
    /// Whether the poll timer should arm — tests drive `pollNow` by hand.
    var schedulesTimer = true

    private var subscribers: [UUID: @MainActor (AlcovePowerState?, AlcovePowerState) -> Void] = [:]
    private var timer: Timer?

    var subscriberCount: Int { subscribers.count }
    var isPolling: Bool { timer != nil }

    /// Listen for changes. The first subscriber starts the poll (its
    /// first reading is the baseline); a later one joins it silently —
    /// the state the machine is already in is not a transition.
    func subscribe(_ handler: @escaping @MainActor (AlcovePowerState?, AlcovePowerState) -> Void) -> UUID {
        let token = UUID()
        subscribers[token] = handler
        if latest == nil { pollNow() }
        if timer == nil, schedulesTimer {
            let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.pollNow() }
            }
            timer.tolerance = 1
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        return token
    }

    /// Stop listening. The last one out stops the poll and forgets the
    /// reading, so a later first subscriber takes a fresh baseline.
    func unsubscribe(_ token: UUID) {
        subscribers[token] = nil
        guard subscribers.isEmpty else { return }
        timer?.invalidate()
        timer = nil
        latest = nil
    }

    /// One reading: a change reaches every subscriber, nothing else does.
    func pollNow() {
        let state = read()
        guard state != latest else { return }
        let old = latest
        latest = state
        for handler in subscribers.values { handler(old, state) }
    }
}

/// The battery half of the island's instant notifications — now a
/// subscription to `AlcovePowerFeed` rather than a poller of its own.
/// The API is the one every surface already uses: `start`, `stop`, and
/// `onTransition` with a real change. The first reading is a baseline —
/// plugging in, switching to battery, hitting full are the only
/// transitions that ever reach a surface, and `AlcovePower.notice`
/// decides what each is worth.
@MainActor
final class AlcovePowerMonitor {
    static let interval: TimeInterval = AlcovePowerFeed.interval

    /// (old, new) on a real change — old is never nil (the baseline
    /// stays silent) and the two never equal.
    var onTransition: (@MainActor (AlcovePowerState, AlcovePowerState) -> Void)?

    private let feed: AlcovePowerFeed
    private var token: UUID?

    var running: Bool { token != nil }

    init(feed: AlcovePowerFeed? = nil) {
        self.feed = feed ?? AlcovePowerFeed.shared
    }

    func start() {
        guard token == nil else { return }
        token = feed.subscribe { [weak self] old, new in
            // The baseline never speaks: a capsule for the state the
            // machine was already in isn't a transition.
            guard let old else { return }
            self?.onTransition?(old, new)
        }
    }

    func stop() {
        guard let token else { return }
        self.token = nil
        feed.unsubscribe(token)
    }

    /// The reading right now — the feed's while it polls, a direct read
    /// otherwise — so a surface that was away (the card folded) never
    /// comes back showing the charge it left with.
    var current: AlcovePowerState { feed.latest ?? feed.read() }

    /// The internal battery's slice of `IOPSCopyPowerSourcesInfo` —
    /// `Type == "InternalBattery"`, AC vs battery from `Power Source
    /// State`, charge state from `Is Charging`, percent from `Current
    /// Capacity` (a 0–100 reading for internal batteries), full from
    /// `Is Charged` or 100% on AC. No battery → `hasBattery` false.
    static func read() -> AlcovePowerState {
        let empty = AlcovePowerState(hasBattery: false, onAC: false,
                                     charging: false, percent: nil, fullyCharged: false)
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return empty
        }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?
                .takeUnretainedValue() as? [String: Any],
                  (description[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            let onAC = (description[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            let charging = (description[kIOPSIsChargingKey] as? Bool) ?? false
            let percent = description[kIOPSCurrentCapacityKey] as? Int
            let charged = (description[kIOPSIsChargedKey] as? Bool) ?? false
            // The system's estimate: minutes to full while charging (-1
            // while it is still measuring), seconds to empty on battery
            // (negative for "unknown" and "unlimited").
            var minutes: Int?
            if charging {
                minutes = (description[kIOPSTimeToFullChargeKey] as? Int).flatMap { $0 > 0 ? $0 : nil }
            } else if !onAC {
                let seconds = IOPSGetTimeRemainingEstimate()
                minutes = seconds > 0 ? Int(seconds / 60) : nil
            }
            return AlcovePowerState(hasBattery: true, onAC: onAC, charging: charging,
                                    percent: percent,
                                    fullyCharged: charged || (onAC && (percent ?? 0) >= 100),
                                    minutesRemaining: minutes)
        }
        return empty
    }
}
