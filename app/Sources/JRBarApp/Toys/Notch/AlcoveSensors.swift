import AppKit
import CoreAudio
import CoreMediaIO
import JRBarCore

/// The island's privacy dots: whether a microphone or a camera is live
/// somewhere on the machine. A slow poll, alive only while the island
/// is ours and shown — a privacy LED may lag a couple of seconds, but
/// it must never be a hot loop, and a parked island holds no reader.
///
/// The mic answer is the same CoreAudio read the menu-bar mic trigger
/// makes (`MenuBarSystemTriggerSource.microphoneInUse` —
/// `kAudioDevicePropertyDeviceIsRunningSomewhere` on the default input).
/// The camera's is the CoreMediaIO twin of that pattern:
/// `kCMIOHardwarePropertyDevices` enumerated, then
/// `kCMIODevicePropertyDeviceIsRunningSomewhere` per device — the
/// camera daemon flips it for FaceTime and Continuity lenses alike, and
/// for the card's own Mirror row too (it IS the camera in use).
///
/// Both reads are observation only: no device is opened, no consent is
/// asked, no frame or sample is ever seen. A refused read answers
/// quiet — a dot that can't be checked is simply not drawn.
@MainActor
final class NotchSensorMonitor {
    static let interval: TimeInterval = 2

    /// The latest reading — written only on change, so the toy sees
    /// edges, not ticks.
    private(set) var state = NotchSensorState()
    var onChange: (@MainActor (NotchSensorState) -> Void)?

    private var timer: Timer?
    private(set) var running = false

    func start() {
        guard !running else { return }
        running = true
        poll()
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        running = false
        timer?.invalidate()
        timer = nil
        // A stopped monitor reports quiet — a parked island's dots die
        // with it rather than linger stale.
        state = NotchSensorState()
    }

    private func poll() {
        let reading = Self.read()
        guard reading != state else { return }
        state = reading
        onChange?(reading)
    }

    /// The two reads as one snapshot.
    static func read() -> NotchSensorState {
        NotchSensorState(microphoneInUse: microphoneInUse(),
                         cameraInUse: cameraInUse())
    }

    /// Whether anything holds the default input running — a CoreAudio
    /// read, no mic permission needed (running-state isn't capture).
    static func microphoneInUse() -> Bool {
        MenuBarSystemTriggerSource.microphoneInUse()
    }

    /// Whether any camera is running somewhere. A machine with no
    /// cameras — or a read the system refuses — answers false.
    static func cameraInUse() -> Bool {
        var listAddress = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var size: UInt32 = 0
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        guard CMIOObjectGetPropertyDataSize(system, &listAddress, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<CMIOObjectID>.size) else { return false }
        var devices = [CMIOObjectID](
            repeating: CMIOObjectID(kCMIOObjectUnknown),
            count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        guard CMIOObjectGetPropertyData(system, &listAddress, 0, nil,
                                        size, &size, &devices) == noErr else { return false }
        var runningAddress = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        for device in devices where device != CMIOObjectID(kCMIOObjectUnknown) {
            var value: UInt32 = 0
            var used = UInt32(MemoryLayout<UInt32>.size)
            if CMIOObjectGetPropertyData(device, &runningAddress, 0, nil,
                                         used, &used, &value) == noErr, value != 0 {
                return true
            }
        }
        return false
    }
}
