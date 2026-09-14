import CoreWLAN
import Foundation
import JRBarUI

/// The `orbit` status icon's feed: the two device facts nobody else on
/// the menu bar nests — Wi-Fi signal and the internal battery — polled
/// on the island power monitor's own cadence. Battery comes from
/// `AlcovePowerMonitor.read` (the same IOKit source the notices use);
/// Wi-Fi from CoreWLAN's primary interface. Every field is an honest
/// read: an interface off, unassociated, or unreadable is a state, never
/// a guessed bar.
@MainActor
final class StatusDeviceMonitor {
    static let interval: TimeInterval = AlcovePowerMonitor.interval

    /// The latest reading — fired only when it changed. An RSSI that
    /// drifts a dBm redraws the same dots, so the spec carries the raw
    /// figure and the renderer's cache key is the one that absorbs it.
    var onChange: (@MainActor (StatusDeviceInfo) -> Void)?

    private var timer: Timer?
    private var last: StatusDeviceInfo?

    func start() {
        guard timer == nil else { return }
        poll()
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        last = nil
    }

    private func poll() {
        let power = AlcovePowerMonitor.read()
        let wifi = Self.readWiFi()
        let info = StatusDeviceInfo(wifiDots: wifi.dots, wifiRSSI: wifi.rssi,
                                    batteryPercent: power.percent,
                                    charging: power.charging, hasBattery: power.hasBattery)
        guard info != last else { return }
        last = info
        onChange?(info)
    }

    /// (dots, rssi) for the primary Wi-Fi interface: nil dots is a radio
    /// off or absent, 0 is on-but-unassociated, 1…4 the signal bucket.
    /// Split out so the bucketing is testable without hardware.
    static func readWiFi() -> (dots: Int?, rssi: Int?) {
        guard let interface = CWWiFiClient.shared().interface(), interface.powerOn() else {
            return (nil, nil)
        }
        // An associated interface reports a real negative dBm; anything
        // else is powered-on-but-not-on-a-network.
        let rssi = interface.rssiValue()
        guard rssi < 0 else { return (0, nil) }
        return (wifiDots(rssi: rssi), rssi)
    }

    /// dBm → dots. −55 or better is the full four; below −75 the link is
    /// a thread — one dot while it still holds. `nonisolated` so the
    /// bucketing is testable without the actor.
    nonisolated static func wifiDots(rssi: Int) -> Int {
        switch rssi {
        case ..<(-75): return 1
        case ..<(-65): return 2
        case ..<(-55): return 3
        default: return 4
        }
    }
}
