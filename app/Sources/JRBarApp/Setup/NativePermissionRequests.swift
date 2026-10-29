import CoreBluetooth
import CoreLocation

/// Retain the manager and wait for the answer before publishing a refresh.
@MainActor
final class LocationPermissionRequest: NSObject, @preconcurrency CLLocationManagerDelegate {
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func request(manager: CLLocationManager) async {
        await withCheckedContinuation { continuation in
            waiting.append(continuation)
            guard waiting.count == 1 else { return }
            manager.delegate = self
            manager.requestWhenInUseAuthorization()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard manager.authorizationStatus != .notDetermined else { return }
        let replies = waiting
        waiting.removeAll()
        replies.forEach { $0.resume() }
    }
}

/// Creating a central requests Bluetooth consent, without scanning or pairing.
@MainActor
final class BluetoothPermissionRequest: NSObject, @preconcurrency CBCentralManagerDelegate {
    private var manager: CBCentralManager?
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func request() async {
        await withCheckedContinuation { continuation in
            waiting.append(continuation)
            guard waiting.count == 1 else { return }
            manager = CBCentralManager(delegate: self, queue: .main,
                                       options: [CBCentralManagerOptionShowPowerAlertKey: false])
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state != .unknown, central.state != .resetting else { return }
        let replies = waiting
        waiting.removeAll()
        replies.forEach { $0.resume() }
        manager = nil
    }
}
