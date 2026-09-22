import AppKit
import CoreAudio
import JRBarCore
import os

/// The tap's own logger — `NotchHUD.log` is main-actor isolated and
/// the engine's rebuild runs off-actor on its serial queue.
private let audioTapLog = Logger(subsystem: "devin.jrbar", category: "audio-tap")

/// The media row's real visualizer: a Core Audio process tap (macOS
/// 14.2+) over the now-playing app's output — or the global stereo
/// mixdown when no client is known — feeding six Goertzel band levels
/// to the bars at ~30 Hz. The pipeline is the public one every notch
/// app landed on: `CATapDescription` → `AudioHardwareCreateProcessTap`
/// → a private aggregate device that owns the tap →
/// `AudioDeviceCreateIOProcID`. The tap is unmuted passthrough —
/// `.mutedWhenTapped` would silence the user's own music, which is the
/// exact failure this feature exists to avoid.
///
/// First start asks the one-time "system audio" permission
/// (`NSAudioCaptureUsageDescription` in the packaged Info.plist); a
/// denial or any pipeline failure just means `live` stays false and
/// the row keeps its decorative animation — never an error surfaced.
///
/// Gating is a pure state table (`NotchAudioLevels.shouldRun`): the
/// toy pushes `visible`/`playing`/`enabled` facts through `sync` and
/// the tap stops the moment any goes false — a collapse, a pause, the
/// setting flipping. A stopped tap holds no Core Audio object.
@MainActor
final class AudioLevelTap {
    /// The smoothed six-band levels the bars draw, 0…1. Published only
    /// on the main actor.
    private(set) var levels: [Float] = [Float](repeating: 0,
                                               count: NotchAudioLevels.bandCenters.count)
    /// The whole pipeline is up and buffers are flowing — the row's
    /// signal to draw live bars instead of the decorative animation.
    private(set) var live = false

    /// Every level publication lands here — the toy forwards it to the
    /// model the card row reads.
    var onLevels: (@MainActor ([Float]) -> Void)?

    /// The engine factory — tests substitute a fake so no Core Audio
    /// object is ever created off the runtime path.
    var makeEngine: @MainActor () -> any AudioTapEngine = {
        CoreAudioTapEngine()
    }

    /// Resolve the now-playing app's pid from its bundle id —
    /// `NSRunningApplication` so a renamed app still resolves. Tests
    /// can answer a pid without a real app.
    var resolvePIDs: @MainActor (String) -> [pid_t] = { bundleID in
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .map(\.processIdentifier)
    }

    // Gating facts, pushed by `sync` — the state table's inputs.
    private var mediaRowVisible = false
    private var playing = false
    private var settingEnabled = false
    private var clientBundleID: String?

    private var engine: (any AudioTapEngine)?

    /// Push the gating facts. Any change re-evaluates the state table;
    /// a false verdict tears the tap down immediately (well inside the
    /// one-second budget — `stop` is synchronous), a true one starts it
    /// if it isn't running. `clientBundleID` retargets the tap when the
    /// now-playing app changes underneath a running pipeline.
    func sync(visible: Bool, playing: Bool, enabled: Bool,
              clientBundleID: String? = nil) {
        mediaRowVisible = visible
        self.playing = playing
        settingEnabled = enabled
        self.clientBundleID = clientBundleID

        guard NotchAudioLevels.shouldRun(mediaRowVisible: visible,
                                         playing: playing,
                                         settingEnabled: enabled) else {
            stop()
            return
        }
        if engine == nil {
            start()
        } else if engine?.processes != targetProcesses() {
            // The client changed mid-flight (or resolved late) — the
            // tap aims at the wrong process. Rebuild rather than mix.
            restart()
        }
    }

    /// Tear the pipeline down — idempotent, and the only way `live`
    /// goes false. Called from `sync`'s verdict and from the toy's own
    /// teardown (park, shutdown), so no tap ever survives a collapse.
    func stop() {
        guard engine != nil else { return }
        engine?.stop()
        engine = nil
        live = false
        if levels.contains(where: { $0 > 0 }) {
            levels = [Float](repeating: 0, count: levels.count)
            onLevels?(levels)
        }
    }

    /// Which processes the tap should mix: the now-playing client's
    /// pids when the feed named a bundle and it resolves, else nil —
    /// the global mixdown.
    private func targetProcesses() -> [pid_t]? {
        guard let bundleID = clientBundleID else { return nil }
        let pids = resolvePIDs(bundleID)
        return pids.isEmpty ? nil : pids
    }

    private func start() {
        let engine = makeEngine()
        // The engine publishes off a utility queue — hop, don't assume.
        engine.onLevels = { [weak self] bands in
            Task { @MainActor [weak self] in self?.note(levels: bands) }
        }
        engine.onDeath = { [weak self] in
            Task { @MainActor [weak self] in self?.noteEngineDied() }
        }
        // Adopt now so a stop() during the build still tears it down;
        // `live` only flips when the pipeline is genuinely up.
        self.engine = engine
        let engineID = ObjectIdentifier(engine)
        engine.start(processes: targetProcesses()) { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, let current = self.engine,
                      ObjectIdentifier(current) == engineID else { return }
                switch result {
                case .success:
                    self.live = true
                case .failure(let error):
                    // Denied consent, a moved API, no default output —
                    // every failure reads the same to the row:
                    // decorative bars.
                    audioTapLog.error("audio tap: pipeline failed — \(error.localizedDescription, privacy: .public)")
                    self.engine = nil
                    self.live = false
                }
            }
        }
    }

    private func restart() {
        engine?.stop()
        engine = nil
        live = false
        start()
    }

    private func note(levels bands: [Float]) {
        guard live else { return }
        levels = bands
        onLevels?(bands)
    }

    /// The engine's own watchdog: a device-change rebuild that failed,
    /// or a tap the system killed, reports here — the row falls back
    /// to decorative bars rather than drawing a frozen reading.
    private func noteEngineDied() {
        engine = nil
        live = false
    }
}

/// The engine's contract — the seam the tests fake. `processes` is the
/// tap's current target: nil = the global mixdown.
protocol AudioTapEngine: AnyObject {
    var processes: [pid_t]? { get }
    var running: Bool { get }
    var onLevels: (([Float]) -> Void)? { get set }
    /// Fires when the engine stops itself (rebuild failure, killed
    /// tap) — the tap's live flag follows it down.
    var onDeath: (() -> Void)? { get set }
    /// Async: the HAL pipeline build runs on the engine's queue — its
    /// RPCs can take tens of ms (longer on the first TCC pass), and none
    /// of that belongs on the caller's thread. Completion fires on the
    /// engine's queue too; callers hop as needed.
    func start(processes: [pid_t]?,
               completion: @escaping @Sendable (Result<Void, any Error>) -> Void)
    func stop()
}

enum AudioTapError: Error {
    /// No default output device to hang the aggregate on.
    case noOutputDevice
    /// `AudioHardwareCreateProcessTap` refused — most often the TCC
    /// "system audio" consent being denied or never asked.
    case tapCreationFailed(OSStatus)
    case aggregateCreationFailed(OSStatus)
    case ioProcCreationFailed(OSStatus)
    case deviceStartFailed(OSStatus)
}

/// The realtime-thread half: sample delivery. The IOProc runs on a
/// Core Audio worker thread where allocation and locks are both sins;
/// it only copies floats into a preallocated ring under an unfair
/// lock, and a plain DispatchSourceTimer on a utility queue does the
/// Goertzel + smoothing + publish hop.
private final class TapSampleBuffer: @unchecked Sendable {
    struct Slot {
        /// The mono-mixed ring — newest samples overwrite oldest.
        var ring = [Float](repeating: 0, count: 8192)
        var writePos = 0
        /// Stamps for the decay-to-zero rule: silence means the last
        /// write ages out and the bars fall on their own.
        var lastWrite = CFAbsoluteTimeGetCurrent()
        var sampleRate = 48000.0
    }

    let lock = OSAllocatedUnfairLock<Slot>(initialState: Slot())

    /// The IOProc thread's scratch — the mixdown happens here so the
    /// lock's `@Sendable` body never borrows a buffer-list pointer, and
    /// the lock is held only for the ring copy. One writer calls this
    /// (the aggregate's IOProc thread), so a plain array is safe.
    private var scratch = [Float](repeating: 0, count: 8192)

    /// IOProc side: fold each channel into the ring as mono. Both
    /// layouts are honoured — non-interleaved (one buffer per channel)
    /// and interleaved (one buffer whose samples stride by
    /// `mNumberChannels`); treating interleaved stereo as mono samples
    /// would double-rate the stream and shift every band an octave.
    func ingest(_ buffers: UnsafePointer<AudioBufferList>) {
        let list = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer<AudioBufferList>(mutating: buffers))
        guard !list.isEmpty else { return }
        var frames = Int.max
        var channelCount = 0
        for buffer in list {
            guard buffer.mData != nil, buffer.mDataByteSize > 0 else { continue }
            let channels = max(1, Int(buffer.mNumberChannels))
            channelCount += channels
            frames = min(frames, Int(buffer.mDataByteSize)
                / (MemoryLayout<Float>.size * channels))
        }
        guard frames > 0, frames != Int.max, channelCount > 0 else { return }
        if scratch.count < frames {
            scratch = [Float](repeating: 0, count: frames)
        }
        for index in 0..<frames { scratch[index] = 0 }
        for buffer in list {
            guard let data = buffer.mData else { continue }
            let channels = max(1, Int(buffer.mNumberChannels))
            let samples = data.assumingMemoryBound(to: Float.self)
            for frame in 0..<frames {
                var mono = scratch[frame]
                for channel in 0..<channels {
                    mono += samples[frame * channels + channel]
                }
                scratch[frame] = mono
            }
        }
        let scale = 1 / Float(channelCount)
        // `frames`/`scratch` are read-only from here, but a `var`
        // captured by the lock's @Sendable body is an error — copy.
        let frameCount = frames
        lock.withLock { slot in
            for frame in 0..<frameCount {
                slot.ring[slot.writePos] = scratch[frame] * scale
                slot.writePos = (slot.writePos + 1) % slot.ring.count
            }
            slot.lastWrite = CFAbsoluteTimeGetCurrent()
        }
    }

    /// Timer side: the newest `count` samples in write order.
    func window(_ count: Int) -> (samples: [Float], stale: Bool) {
        lock.withLock { slot in
            var out = [Float](repeating: 0, count: min(count, slot.ring.count))
            for i in 0..<out.count {
                let pos = (slot.writePos - out.count + i + slot.ring.count) % slot.ring.count
                out[i] = slot.ring[pos]
            }
            // No writes for a full window means silence — the smoother's
            // release carries the bars down on its own.
            let stale = CFAbsoluteTimeGetCurrent() - slot.lastWrite > 0.5
            return (out, stale)
        }
    }
}

/// The real pipeline. One instance = one tap + one aggregate + one
/// IOProc; `rebuild` (default-output change) is a stop/start pair, so
/// at no moment are two taps alive.
final class CoreAudioTapEngine: AudioTapEngine, @unchecked Sendable {
    private(set) var processes: [pid_t]?
    private(set) var running = false
    var onLevels: (([Float]) -> Void)?
    var onDeath: (() -> Void)?

    private let buffer = TapSampleBuffer()
    private let workQueue = DispatchQueue(label: "jrbar.audio.tap", qos: .utility)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var timer: DispatchSourceTimer?
    private var smoother = NotchBandSmoother()
    private var lastPublish = CFAbsoluteTimeGetCurrent()
    /// The default-output listener context — kept so `stop` can
    /// remove exactly what `start` added.
    private var listeningForDeviceChange = false
    /// Invalidate ticket for an in-flight build — a stop (or a newer
    /// start) mid-construction makes the build unwind itself instead of
    /// coming alive after its caller already left.
    private var startTicket = 0

    func start(processes: [pid_t]?,
               completion: @escaping @Sendable (Result<Void, any Error>) -> Void) {
        guard !running else { completion(.success(())); return }
        self.processes = processes
        startTicket += 1
        let ticket = startTicket
        workQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.buildPipeline()
            } catch {
                completion(.failure(error))
                return
            }
            guard ticket == self.startTicket, !self.running else {
                // Stopped (or restarted) while the HAL worked — unwind.
                self.teardown()
                return
            }
            self.running = true
            self.armDeviceChangeListener()
            self.armPublishTimer()
            completion(.success(()))
        }
    }

    func stop() {
        running = false
        startTicket += 1
        timer?.cancel()
        timer = nil
        disarmDeviceChangeListener()
        // The teardown runs on the engine's serial queue: a device-
        // change rebuild or start already in flight finishes (or sees
        // its ticket stale / `running == false` and unwinds) before we
        // tear down, so a stop can never leave a tap behind. No
        // work-queue item ever blocks on the main actor — the hops are
        // `Task` posts — so `sync` cannot deadlock.
        workQueue.sync { teardown() }
    }

    /// Unwind every Core Audio object — the IOProc first, then the
    /// aggregate that hosts it, then the tap. Runs on `workQueue`;
    /// safe to call twice.
    private func teardown() {
        if let ioProcID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    // MARK: Pipeline

    private func buildPipeline() throws {
        // 1. The tap description. A known client mixes its processes;
        // otherwise the global stereo mixdown of everything.
        let objectIDs = processes.map { Self.processObjectIDs(for: $0) } ?? []
        let description: CATapDescription
        if !objectIDs.isEmpty {
            description = CATapDescription(stereoMixdownOfProcesses: objectIDs)
        } else {
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        }
        description.uuid = UUID()
        // `.unmuted` is load-bearing: the tap listens, it must never
        // mute the user's passthrough audio.
        description.muteBehavior = .unmuted
        description.isPrivate = true
        description.name = "JR-Bar visualizer"

        var tapID = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else { throw AudioTapError.tapCreationFailed(status) }
        self.tapID = tapID

        do {
            // 2. The default output becomes the aggregate's main
            // sub-device, so the tap's clock follows the user's real
            // output (and a device swap is a rebuild, handled by the
            // listener below).
            let outputID = try Self.defaultOutputDevice()
            let outputUID = try Self.deviceUID(outputID)
            let aggregateDesc: [String: Any] = [
                kAudioAggregateDeviceNameKey: "JR-Bar visualizer",
                kAudioAggregateDeviceUIDKey: "jrbar.visualizer.\(UUID().uuidString)",
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [
                    [kAudioSubDeviceUIDKey: outputUID],
                ],
                kAudioAggregateDeviceTapListKey: [
                    [
                        kAudioSubTapDriftCompensationKey: true,
                        kAudioSubTapUIDKey: description.uuid.uuidString,
                    ],
                ],
            ]
            var aggregateID = AudioObjectID(kAudioObjectUnknown)
            status = AudioHardwareCreateAggregateDevice(aggregateDesc as CFDictionary, &aggregateID)
            guard status == noErr else { throw AudioTapError.aggregateCreationFailed(status) }
            self.aggregateID = aggregateID

            // 3. Sample rate for the Goertzel — the tap's format, not
            //    a guess at 48 kHz. Read before the lock: the lock's
            //    @Sendable body cannot capture the local tapID var.
            let rate = Self.nominalSampleRate(of: tapID) ?? 48000
            buffer.lock.withLock { slot in
                slot.sampleRate = rate
            }

            // 4. The IOProc on the aggregate: buffers land on a Core
            //    Audio thread, get folded into the ring, and the timer
            //    does the rest.
            let context = Unmanaged.passUnretained(self).toOpaque()
            var procID: AudioDeviceIOProcID?
            status = AudioDeviceCreateIOProcID(aggregateID, { _, _, inputData, _, _, _, clientData in
                guard let clientData else { return noErr }
                let engine = Unmanaged<CoreAudioTapEngine>.fromOpaque(clientData)
                    .takeUnretainedValue()
                engine.buffer.ingest(inputData)
                return noErr
            }, context, &procID)
            guard status == noErr, let procID else {
                throw AudioTapError.ioProcCreationFailed(status)
            }
            ioProcID = procID
            status = AudioDeviceStart(aggregateID, procID)
            guard status == noErr else { throw AudioTapError.deviceStartFailed(status) }
        } catch {
            // A half-built pipeline must not leak — unwind whatever
            // stage the failure landed in.
            if let ioProcID, aggregateID != kAudioObjectUnknown {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
                self.ioProcID = nil
            }
            if aggregateID != kAudioObjectUnknown {
                AudioHardwareDestroyAggregateDevice(aggregateID)
                self.aggregateID = AudioObjectID(kAudioObjectUnknown)
            }
            AudioHardwareDestroyProcessTap(tapID)
            self.tapID = AudioObjectID(kAudioObjectUnknown)
            throw error
        }
    }

    // MARK: Publish timer

    /// ~30 Hz: read the newest window, six Goertzel bands, smooth,
    /// publish. Silence for half a second publishes zeros — the
    /// release ramp brings the bars down instead of freezing them.
    private func armPublishTimer() {
        let timer = DispatchSource.makeTimerSource(queue: workQueue)
        timer.schedule(deadline: .now() + 1.0 / 30.0,
                       repeating: 1.0 / 30.0, leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in
            self?.publish()
        }
        timer.resume()
        self.timer = timer
    }

    private func publish() {
        let (samples, stale) = buffer.window(NotchAudioLevels.windowSize)
        let raw = stale
            ? [Float](repeating: 0, count: NotchAudioLevels.bandCenters.count)
            : NotchAudioLevels.bandLevels(samples, sampleRate: buffer.lock.withLock { $0.sampleRate })
        let now = CFAbsoluteTimeGetCurrent()
        let dt = now - lastPublish
        lastPublish = now
        let levels = smoother.update(raw, dt: dt)
        onLevels?(levels)
    }

    // MARK: Default-output tracking

    /// The aggregate's main sub-device is the default output — when it
    /// changes (headphones in, AirPods out) the pipeline's clock is
    /// stale, so rebuild around the new output.
    private func armDeviceChangeListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard AudioObjectAddPropertyListener(
            AudioObjectID(kAudioObjectSystemObject), &address,
            Self.deviceChangeProc, context) == noErr else { return }
        listeningForDeviceChange = true
    }

    private func disarmDeviceChangeListener() {
        guard listeningForDeviceChange else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        // The removal must name exactly what `add` registered — the
        // same proc value and context — or the listener leaks and a
        // dead engine still gets rebuild asks.
        let context = Unmanaged.passUnretained(self).toOpaque()
        AudioObjectRemovePropertyListener(
            AudioObjectID(kAudioObjectSystemObject), &address,
            Self.deviceChangeProc, context)
        listeningForDeviceChange = false
    }

    /// The device-change callback as one shared value — CoreAudio
    /// matches a listener for removal by its proc pointer, so add and
    /// remove must hand over the identical function.
    private static let deviceChangeProc: AudioObjectPropertyListenerProc = {
        _, _, _, clientData in
        guard let clientData else { return noErr }
        let engine = Unmanaged<CoreAudioTapEngine>.fromOpaque(clientData)
            .takeUnretainedValue()
        engine.noteDeviceChange()
        return noErr
    }

    /// A device change is a full rebuild on the engine's own queue —
    /// teardown then re-create around the new output. A rebuild that
    /// fails (the new output has no usable stream, TCC revoked
    /// mid-session) is a death, not a half-state: the tap reports
    /// itself dead and the row falls back.
    private func noteDeviceChange() {
        workQueue.async { [weak self] in
            guard let self, self.running else { return }
            do {
                self.teardown()
                try self.buildPipeline()
            } catch {
                audioTapLog.error("audio tap: device-change rebuild failed — \(error.localizedDescription, privacy: .public)")
                // Death must disarm before reporting: the HAL still holds
                // this engine's address, and the next headphone plug would
                // otherwise fire the proc on a dead object.
                self.disarmDeviceChangeListener()
                self.onDeath?()
            }
        }
    }

    deinit {
        // The tap stops the engine on the normal path, but an engine that
        // outlives its owner (teardown race) still owes the HAL its
        // listener removal — the context pointer is unretained self.
        disarmDeviceChangeListener()
    }

    // MARK: Property reads

    /// pid → the HAL's process object id — a tap description names
    /// process objects, not pids. A pid that won't translate is
    /// dropped; none translating at all means the global mixdown
    /// carries the read instead.
    private static func processObjectIDs(for pids: [pid_t]) -> [AudioObjectID] {
        pids.compactMap { pid in
            var objectID = AudioObjectID(kAudioObjectUnknown)
            var processID = pid
            var size = UInt32(MemoryLayout<AudioObjectID>.size)
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<pid_t>.size), &processID,
                &size, &objectID) == noErr,
                  objectID != AudioObjectID(kAudioObjectUnknown) else { return nil }
            return objectID
        }
    }

    private static func defaultOutputDevice() throws -> AudioDeviceID {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard status == noErr, device != kAudioObjectUnknown else {
            throw AudioTapError.noOutputDevice
        }
        return device
    }

    private static func deviceUID(_ device: AudioDeviceID) throws -> String {
        // The getter hands back a retained CFString — read it through
        // Unmanaged and take the retain, or every rebuild leaks one.
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid)
        guard status == noErr, let uid else { throw AudioTapError.noOutputDevice }
        return uid.takeRetainedValue() as String
    }

    /// The tap's own nominal rate — `kAudioDevicePropertyNominalSampleRate`
    /// answers on the tap object the same as on a device.
    private static func nominalSampleRate(of object: AudioObjectID) -> Double? {
        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &rate) == noErr,
              rate > 0 else { return nil }
        return rate
    }
}
