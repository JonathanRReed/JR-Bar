import AppKit
import IOKit.ps
import JRBarCore

/// The battery half of the island's instant notifications: a 5 s poll
/// over IOKit's power-source list (the same `pmset -g ps` reads),
/// alive only while the island is shown and `capsuleKinds.charging` is
/// on. The first reading is a baseline — plugging in, switching to
/// battery, hitting full are the only transitions that ever reach the
/// toy, and `AlcovePower.notice` decides what each is worth.
@MainActor
final class AlcovePowerMonitor {
    static let interval: TimeInterval = 5

    /// (old, new) on a real change — old is never nil (the baseline
    /// stays silent) and the two never equal.
    var onTransition: (@MainActor (AlcovePowerState, AlcovePowerState) -> Void)?

    private var timer: Timer?
    private var last: AlcovePowerState?

    private(set) var running = false

    func start() {
        guard !running else { return }
        running = true
        poll()
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        running = false
        timer?.invalidate()
        timer = nil
        last = nil
    }

    private func poll() {
        let state = Self.read()
        guard state != last else { return }
        let old = last
        last = state
        // The baseline never speaks: a capsule for the state the machine
        // was already in isn't a transition.
        if let old { onTransition?(old, state) }
    }

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
            return AlcovePowerState(hasBattery: true, onAC: onAC, charging: charging,
                                    percent: percent,
                                    fullyCharged: charged || (onAC && (percent ?? 0) >= 100))
        }
        return empty
    }
}
