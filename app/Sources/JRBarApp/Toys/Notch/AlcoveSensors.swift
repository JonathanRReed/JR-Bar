import AppKit
import CoreAudio
import CoreMediaIO
import JRBarCore

/// The privacy dots and the call fact: whether another app is capturing
/// from a microphone, or a camera is live, somewhere on the machine.
/// Property listeners make a reading land the moment it changes —
/// CoreAudio's `IsRunningInput` on every audio process (re-armed when
/// processes come and go) and CoreMediaIO's `IsRunningSomewhere` on
/// every camera (re-armed when cameras come and go) — with a slow poll
/// kept only as the safety net. Alive only while something takes the
/// reading: a surface that draws the dots, or the daemon's presence
/// report; with neither, no reader is held.
///
/// The mic answer is `MicrophoneCapture` — the one the sounds and the
/// menu-bar mic trigger ask too: a process other than JR-Bar running
/// input from a real input device. Not the default input's
/// `IsRunningSomewhere`, which is device-wide: AirPods playing music
/// are one device with both directions, and read as a call.
/// The camera's is the CoreMediaIO pattern:
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
    /// The system-level ones (audio processes came or went, camera list
    /// changed) live for the run; the per-object ones are re-armed on
    /// those.
    private var systemProcesses: AudioListener?
    private var systemCameras: CameraListener?
    private var processListeners: [AudioListener] = []
    private var cameraListeners: [CameraListener] = []
    /// A poll already queued for this turn — a burst of edges (a call
    /// app starting its IO touches several processes at once) reads once.
    private var pollQueued = false
    /// The reads are IPC to the audio and camera daemons — about 14 ms,
    /// every edge and every safety tick — so they run here, never on the
    /// main thread. Tests stand in their own reader.
    nonisolated let readQueue = DispatchQueue(label: "jrbar.notch-sensors", qos: .utility)
    var reader: @Sendable () -> NotchSensorState = { NotchSensorMonitor.read() }
    /// A read on its way; an edge meanwhile asks for one more after it.
    private var readInFlight = false
    private var readAgain = false

    /// How many listeners are armed — the tests' window on the
    /// re-arming.
    var armedListenerCount: Int {
        (systemProcesses == nil ? 0 : 1) + (systemCameras == nil ? 0 : 1)
            + processListeners.count + cameraListeners.count
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
        // An edge queued during the in-flight read is dropped too —
        // otherwise the next start would run one redundant poll.
        readAgain = false
        // A stopped monitor reports quiet — a parked island's dots die
        // with it rather than linger stale.
        state = NotchSensorState()
    }

    // MARK: Listeners

    private func armListeners() {
        var processesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let processesChanged: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.armProcessListeners()
                self?.queuePoll()
            }
        }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &processesAddress,
                                               DispatchQueue.main, processesChanged) == noErr {
            systemProcesses = AudioListener(object: AudioObjectID(kAudioObjectSystemObject),
                                            address: processesAddress, block: processesChanged)
        }
        var devicesAddress = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        let camerasChanged: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.armCameraListeners()
                self?.queuePoll()
            }
        }
        if CMIOObjectAddPropertyListenerBlock(CMIOObjectID(kCMIOObjectSystemObject), &devicesAddress,
                                              DispatchQueue.main, camerasChanged) == noErr {
            systemCameras = CameraListener(object: CMIOObjectID(kCMIOObjectSystemObject),
                                           address: devicesAddress, block: camerasChanged)
        }
        armProcessListeners()
        armCameraListeners()
    }

    /// Watch every audio process's `IsRunningInput` — the edge a call,
    /// a recording or dictation makes the moment it opens the mic. JR-Bar
    /// itself is left out: its own tap never counts, so its edges would
    /// only wake a read that changes nothing.
    private func armProcessListeners() {
        for old in processListeners {
            var address = old.address
            AudioObjectRemovePropertyListenerBlock(old.object, &address, DispatchQueue.main, old.block)
        }
        processListeners = []
        guard running else { return }
        let me = getpid()
        for process in MicrophoneCapture.processObjects() where MicrophoneCapture.pid(of: process) != me {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyIsRunningInput,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated { self?.queuePoll() }
            }
            if AudioObjectAddPropertyListenerBlock(process, &address, DispatchQueue.main, block) == noErr {
                processListeners.append(AudioListener(object: process, address: address, block: block))
            }
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
                MainActor.assumeIsolated { self?.queuePoll() }
            }
            if CMIOObjectAddPropertyListenerBlock(device, &address, DispatchQueue.main, block) == noErr {
                cameraListeners.append(CameraListener(object: device, address: address, block: block))
            }
        }
    }

    private func disarmListeners() {
        if let listener = systemProcesses {
            var address = listener.address
            AudioObjectRemovePropertyListenerBlock(listener.object, &address, DispatchQueue.main, listener.block)
            systemProcesses = nil
        }
        if let listener = systemCameras {
            var address = listener.address
            CMIOObjectRemovePropertyListenerBlock(listener.object, &address, DispatchQueue.main, listener.block)
            systemCameras = nil
        }
        armProcessListeners()
        armCameraListeners()
    }

    /// One read on the next main-queue turn, however many edges asked.
    private func queuePoll() {
        guard !pollQueued else { return }
        pollQueued = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pollQueued = false
                if self.running { self.poll() }
            }
        }
    }

    private func poll() {
        guard !readInFlight else {
            readAgain = true
            return
        }
        readInFlight = true
        let read = reader
        readQueue.async { [weak self] in
            let reading = read()
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.land(reading) }
            }
        }
    }

    /// A read came back: an edge if it changed anything, and the read an
    /// edge asked for while it was out.
    private func land(_ reading: NotchSensorState) {
        readInFlight = false
        guard running else { return }
        if reading != state {
            state = reading
            onChange?(reading)
        }
        if readAgain {
            readAgain = false
            poll()
        }
    }

    /// The two reads as one snapshot.
    nonisolated static func read() -> NotchSensorState {
        NotchSensorState(microphoneInUse: microphoneInUse(),
                         cameraInUse: cameraInUse())
    }

    /// Whether another app is capturing from a microphone
    /// (`MicrophoneCapture`) — CoreAudio reads, no mic permission needed
    /// (running state isn't capture).
    nonisolated static func microphoneInUse() -> Bool {
        MicrophoneCapture.isLive()
    }

    /// Whether any camera is running somewhere. A machine with no
    /// cameras — or a read the system refuses — answers false.
    nonisolated static func cameraInUse() -> Bool {
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

    // MARK: Who is listening

    /// The processes capturing from a microphone right now — the same
    /// processes that light the dot (`MicrophoneCapture`), so a
    /// visualizer's tap is never named beside the call. Observation
    /// only, like the dot: no device is opened. Empty when the system
    /// refuses the read.
    nonisolated static func microphoneClientPIDs() -> [pid_t] {
        MicrophoneCapture.capturingPIDs()
    }

    /// The names of what holds the mic: the app's own name, a helper
    /// process's owning app where macOS says (a browser's audio helper
    /// reads as the browser), else the executable's name. JR-Bar itself
    /// is never listed.
    nonisolated static func microphoneClientNames() -> [String] {
        let me = ProcessInfo.processInfo.processIdentifier
        return microphoneClientPIDs().filter { $0 != me }.compactMap { pid in
            if let app = NSRunningApplication(processIdentifier: pid) {
                return app.localizedName ?? app.bundleURL?.deletingPathExtension().lastPathComponent
            }
            var buffer = [UInt8](repeating: 0, count: 256)
            let length = proc_name(pid, &buffer, UInt32(buffer.count))
            guard length > 0 else { return nil }
            let name = String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
            return name.isEmpty ? nil : name
        }
    }

    /// The card's privacy line as of now — nil while nothing is live.
    nonisolated static func privacyLineNow() -> String? {
        let state = read()
        guard state.anyInUse else { return nil }
        return state.privacyLine(microphoneApps: state.microphoneInUse ? microphoneClientNames() : [])
    }

    /// Every camera CoreMediaIO lists — empty on a machine with none, or
    /// a read the system refuses.
    nonisolated static func cameraDevices() -> [CMIOObjectID] {
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
