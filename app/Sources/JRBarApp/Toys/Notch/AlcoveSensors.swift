import AppKit
import CoreAudio
import CoreMediaIO
import JRBarCore

/// The island's privacy dots: whether a microphone or a camera is live
/// somewhere on the machine. Property listeners make a dot land the
/// moment a device starts or stops — CoreAudio's `IsRunningSomewhere`
/// on the default input (re-armed when the default input moves) and
/// CoreMediaIO's twin on every camera (re-armed when cameras come and
/// go) — with a slow poll kept only as the safety net. Alive only while
/// a surface can draw the dots; a parked island holds no reader.
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
    /// The safety-net poll — the listeners carry the edges; this only
    /// catches a device whose listener the system never fired.
    static let interval: TimeInterval = 10

    /// The latest reading — written only on change, so the toy sees
    /// edges, not ticks.
    private(set) var state = NotchSensorState()
    var onChange: (@MainActor (NotchSensorState) -> Void)?

    private var timer: Timer?
    private(set) var running = false

    /// A registered CoreAudio listener — removal needs the identical
    /// object, address and block.
    private struct AudioListener {
        var object: AudioObjectID
        var address: AudioObjectPropertyAddress
        var block: AudioObjectPropertyListenerBlock
    }
    private struct CameraListener {
        var object: CMIOObjectID
        var address: CMIOObjectPropertyAddress
        var block: CMIOObjectPropertyListenerBlock
    }
    /// The system-level ones (default input moved, camera list changed)
    /// live for the run; the device-level ones are re-armed on those.
    private var systemAudio: AudioListener?
    private var systemCameras: CameraListener?
    private var inputListener: AudioListener?
    private var cameraListeners: [CameraListener] = []

    /// How many device listeners are armed — the tests' window on the
    /// re-arming.
    var armedListenerCount: Int {
        (systemAudio == nil ? 0 : 1) + (systemCameras == nil ? 0 : 1)
            + (inputListener == nil ? 0 : 1) + cameraListeners.count
    }

    func start() {
        guard !running else { return }
        running = true
        poll()
        armListeners()
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer.tolerance = 2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        running = false
        timer?.invalidate()
        timer = nil
        disarmListeners()
        // A stopped monitor reports quiet — a parked island's dots die
        // with it rather than linger stale.
        state = NotchSensorState()
    }

    // MARK: Listeners

    private func armListeners() {
        var inputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let inputMoved: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.armInputListener()
                self?.poll()
            }
        }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &inputAddress,
                                               DispatchQueue.main, inputMoved) == noErr {
            systemAudio = AudioListener(object: AudioObjectID(kAudioObjectSystemObject),
                                        address: inputAddress, block: inputMoved)
        }
        var devicesAddress = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        let camerasChanged: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.armCameraListeners()
                self?.poll()
            }
        }
        if CMIOObjectAddPropertyListenerBlock(CMIOObjectID(kCMIOObjectSystemObject), &devicesAddress,
                                              DispatchQueue.main, camerasChanged) == noErr {
            systemCameras = CameraListener(object: CMIOObjectID(kCMIOObjectSystemObject),
                                           address: devicesAddress, block: camerasChanged)
        }
        armInputListener()
        armCameraListeners()
    }

    /// Watch the current default input's running state; the old
    /// device's listener goes first.
    private func armInputListener() {
        if let old = inputListener {
            var address = old.address
            AudioObjectRemovePropertyListenerBlock(old.object, &address, DispatchQueue.main, old.block)
            inputListener = nil
        }
        guard running, let device = Self.defaultInputDevice() else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        if AudioObjectAddPropertyListenerBlock(device, &address, DispatchQueue.main, block) == noErr {
            inputListener = AudioListener(object: device, address: address, block: block)
        }
    }

    /// Watch every camera's running state — re-armed whenever the list
    /// changes, so a Continuity camera arriving is watched too.
    private func armCameraListeners() {
        for old in cameraListeners {
            var address = old.address
            CMIOObjectRemovePropertyListenerBlock(old.object, &address, DispatchQueue.main, old.block)
        }
        cameraListeners = []
        guard running else { return }
        for device in Self.cameraDevices() {
            var address = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
            let block: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated { self?.poll() }
            }
            if CMIOObjectAddPropertyListenerBlock(device, &address, DispatchQueue.main, block) == noErr {
                cameraListeners.append(CameraListener(object: device, address: address, block: block))
            }
        }
    }

    private func disarmListeners() {
        if let listener = systemAudio {
            var address = listener.address
            AudioObjectRemovePropertyListenerBlock(listener.object, &address, DispatchQueue.main, listener.block)
            systemAudio = nil
        }
        if let listener = systemCameras {
            var address = listener.address
            CMIOObjectRemovePropertyListenerBlock(listener.object, &address, DispatchQueue.main, listener.block)
            systemCameras = nil
        }
        armInputListener()
        armCameraListeners()
    }

    /// The default input device, nil when CoreAudio names none.
    private static func defaultInputDevice() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                         &size, &device) == noErr, device != 0 else { return nil }
        return device
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
        var runningAddress = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        for device in cameraDevices() {
            var value: UInt32 = 0
            var used = UInt32(MemoryLayout<UInt32>.size)
            if CMIOObjectGetPropertyData(device, &runningAddress, 0, nil,
                                         used, &used, &value) == noErr, value != 0 {
                return true
            }
        }
        return false
    }

    /// Every camera CoreMediaIO lists — empty on a machine with none, or
    /// a read the system refuses.
    static func cameraDevices() -> [CMIOObjectID] {
        var listAddress = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var size: UInt32 = 0
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        guard CMIOObjectGetPropertyDataSize(system, &listAddress, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<CMIOObjectID>.size) else { return [] }
        var devices = [CMIOObjectID](
            repeating: CMIOObjectID(kCMIOObjectUnknown),
            count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        guard CMIOObjectGetPropertyData(system, &listAddress, 0, nil,
                                        size, &size, &devices) == noErr else { return [] }
        return devices.filter { $0 != CMIOObjectID(kCMIOObjectUnknown) }
    }
}
