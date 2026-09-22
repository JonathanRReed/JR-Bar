import CoreAudio
import Foundation
import IOKit.pwr_mgt
import JRBarCore
import os

/// The Control Center strip — One Switch's grammar with JR-Bar's
/// honesty rules. State is read back from the system, never asserted:
/// a Finder write that failed shows off, not the intent. Applies run
/// detached so a pend (TCC, a stuck `osascript`) can never reach the
/// render path; the read-back lands a beat later and settles the chip.
///
/// App-level: every instance is a view onto one `State`, so the notch
/// card's chips (both card surfaces build their own store), a global
/// shortcut, a `jrbar://toggle/…` link and a Shortcuts action all flip
/// the same truth and hold the same keep-awake assertion — never two.
@MainActor
final class SystemTogglesStore {
    /// The one strip. `SystemTogglesStore()` joins it too.
    static let shared = SystemTogglesStore()

    /// The truth every instance reads and writes.
    @MainActor
    @Observable
    final class State {
        static let shared = State()

        /// The live on-state per stateful toggle — refreshed on show,
        /// after each apply, and whenever the system says it changed.
        /// Momentary verbs never appear here.
        var isOn: [SystemToggle: Bool] = [:]
        /// A toggle mid-apply — the chip pulses rather than lie.
        var applying: Set<SystemToggle> = []
        /// The last apply's honest outcome — a denied `defaults` write or
        /// an AppleScript refusal lands here so the chip can say so.
        var lastError: String?
        /// Which chips the strip shows, in order — One Switch's "choose
        /// which toggles show". Persisted app-locally.
        var strip: [SystemToggle]

        /// The keep-awake assertion while held — our own state, so the
        /// chip reads the truth directly. Boxed nonisolated so `deinit`
        /// can release it: the assertion must not outlive the state.
        let awake = AwakeAssertion()

        /// A Dock choice made while the Dock utility's preview holds the
        /// Dock out: applied the moment the hold lets go, so the hold's
        /// restore can never undo it.
        @ObservationIgnored var pendingDockAutohide: Bool?
        @ObservationIgnored var listening = false

        /// The Dock's live `autohide` pair (`CoreDock`, the one the Dock
        /// utility's preview hold uses) — nil on a build where it does
        /// not resolve, and then System Events, and only last `defaults`
        /// plus a Dock restart.
        @ObservationIgnored let dockDriver: (any DockAutohideDriver)?
        /// Is the Dock utility holding the Dock out for a preview right
        /// now? Wired by the delegate; a chip flip during a hold waits.
        @ObservationIgnored var dockHoldActive: @MainActor () -> Bool = { false }

        /// Where the strip's chip choice persists — app-local defaults;
        /// a test hands in its own suite.
        @ObservationIgnored let defaults: UserDefaults

        init(dockDriver: (any DockAutohideDriver)? = CoreDockAutohideDriver(),
             defaults: UserDefaults = .standard) {
            self.dockDriver = dockDriver
            self.defaults = defaults
            self.strip = SystemTogglesStore.loadStrip(defaults: defaults)
        }

        deinit {
            if awake.held { IOPMAssertionRelease(awake.id) }
        }
    }

    /// The box `deinit` reads — mutated only on the actor, so the
    /// unchecked-Sendable is disciplined by construction.
    final class AwakeAssertion: @unchecked Sendable {
        var id: IOPMAssertionID = 0
        var held = false
    }

    let state: State
    private var dockDriver: (any DockAutohideDriver)? { state.dockDriver }
    private func dockHoldActive() -> Bool { state.dockHoldActive() }

    init(state: State = .shared) {
        self.state = state
    }

    var isOn: [SystemToggle: Bool] { state.isOn }
    var applying: Set<SystemToggle> { state.applying }
    var lastError: String? { state.lastError }
    var strip: [SystemToggle] { state.strip }

    private nonisolated static let log = Logger(
        subsystem: "devin.jrbar", category: "toggles")

    // MARK: - The strip

    nonisolated static let stripDefaultsKey = "systemToggleStrip"

    nonisolated static func loadStrip(defaults: UserDefaults = .standard) -> [SystemToggle] {
        guard let raw = defaults.array(forKey: stripDefaultsKey) as? [String] else {
            return SystemToggle.defaultStrip
        }
        return SystemToggle.strip(fromStored: raw)
    }

    /// Show or hide one chip on the strip; a chip joining lands at its
    /// canonical place, so the strip keeps One Switch's stable order.
    func setInStrip(_ toggle: SystemToggle, _ shown: Bool) {
        var set = Set(state.strip)
        if shown { set.insert(toggle) } else { set.remove(toggle) }
        let next = SystemToggle.allCases.filter(set.contains)
        guard next != state.strip else { return }
        state.strip = next
        state.defaults.set(next.map(\.rawValue), forKey: Self.stripDefaultsKey)
    }

    // MARK: - Reads

    /// Re-read every stateful toggle's truth — on card show, and
    /// after an apply settles. In-process reads answer inline; the
    /// `defaults` probes run detached — a card show must not pay for
    /// process lifetimes on the render path. The first call also starts
    /// the system listeners, so a chip follows F10 or Control Center
    /// while the card is open instead of going stale.
    func refresh() {
        startListening()
        for toggle in SystemToggle.allCases where !toggle.isMomentary {
            refresh(toggle)
        }
    }

    private func refresh(_ toggle: SystemToggle) {
        if let inline = readInline(toggle) {
            state.isOn[toggle] = inline
        } else {
            Task {
                let value = await Task.detached { Self.probe(toggle) }.value
                state.isOn[toggle] = value
            }
        }
    }

    /// The reads that cost no process: our own bookkeeping, a domain
    /// lookup, a CoreAudio property, the Dock's own live flag. `nil`
    /// means "probe it off-actor".
    private func readInline(_ toggle: SystemToggle) -> Bool? {
        switch toggle {
        case .keepAwake:
            return state.awake.held
        case .darkMode:
            // The global domain's answer — "Dark" present means on;
            // absent means light. No process needed.
            return (UserDefaults.standard.persistentDomain(
                forName: UserDefaults.globalDomain)?["AppleInterfaceStyle"] as? String) == "Dark"
        case .mute:
            return Self.readMute()
        case .dockAutoHide:
            return dockDriver?.isAutohideEnabled
        default:
            return nil
        }
    }

    /// The `defaults read` probe — detached callers only: a process
    /// launch has no business on the render path.
    private nonisolated static func probe(_ toggle: SystemToggle) -> Bool {
        guard let probe = toggle.defaultsProbe else { return false }
        let out = shell("defaults read \(probe.domain) \(probe.key)")
        return SystemToggle.readMaps(out, onWhenAbsent: probe.onWhenAbsent)
    }

    // MARK: - Listening (the system tells us, nothing polls)

    /// Appearance and output mute can change under the strip — F10, the
    /// Control Center module, System Settings. The distributed
    /// appearance notification and a CoreAudio listener on the default
    /// output (re-armed when the default device changes) keep those
    /// chips true without a poll.
    private func startListening() {
        guard !state.listening else { return }
        state.listening = true
        let state = self.state
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    state.isOn[.darkMode] = (UserDefaults.standard.persistentDomain(
                        forName: UserDefaults.globalDomain)?["AppleInterfaceStyle"] as? String) == "Dark"
                }
            }
        AudioListener.shared.onChange = {
            Task { @MainActor in state.isOn[.mute] = Self.readMute() }
        }
        AudioListener.shared.start()
    }

    // MARK: - Applies

    /// A chip tap: momentary verbs fire, stateful toggles flip and
    /// read back. One apply per toggle at a time — a double-tap waits
    /// for the read-back rather than racing the system.
    func apply(_ toggle: SystemToggle) {
        guard !state.applying.contains(toggle) else { return }
        switch toggle {
        case .keepAwake:
            setAwake(!state.awake.held)
            state.isOn[.keepAwake] = state.awake.held
            return
        case .mute:
            let next = !Self.readMute()
            if Self.writeMute(next) {
                state.isOn[.mute] = next
            } else {
                state.lastError = "No output device to mute."
            }
            return
        case .lock, .screenSaver:
            fire(toggle, on: true)
            return
        case .dockAutoHide:
            setDockAutohide(!(readInline(.dockAutoHide) ?? state.isOn[.dockAutoHide] ?? false))
            return
        default:
            if let current = state.isOn[toggle] ?? readInline(toggle) {
                fire(toggle, on: !current)
            } else {
                // No read yet — probe off-actor before deciding the flip.
                Task {
                    let current = await Task.detached { Self.probe(toggle) }.value
                    state.isOn[toggle] = current
                    fire(toggle, on: !current)
                }
            }
        }
    }

    /// Set a stateful toggle to `on` — a link's `?on=1`, a Shortcuts
    /// action — or fire a verb. A toggle already there is left alone
    /// (no Finder restart for nothing).
    func set(_ toggle: SystemToggle, on: Bool) {
        guard !toggle.isMomentary else {
            if on { apply(toggle) }
            return
        }
        if let current = state.isOn[toggle] ?? readInline(toggle), current == on { return }
        if state.isOn[toggle] == nil, readInline(toggle) == nil {
            Task {
                let current = await Task.detached { Self.probe(toggle) }.value
                state.isOn[toggle] = current
                if current != on { apply(toggle) }
            }
            return
        }
        apply(toggle)
    }

    /// A shell-backed flip: run detached, read the truth back after
    /// the settle beat (Finder relaunches take a moment), and keep any
    /// stderr honest — a refused write lands in `lastError`.
    private func fire(_ toggle: SystemToggle, on: Bool, command override: String? = nil,
                      fallback: String? = nil) {
        guard let command = override ?? toggle.applyCommand(on: on) else { return }
        state.applying.insert(toggle)
        state.lastError = nil
        Task {
            var result = await Task.detached {
                Self.shellWithError(command)
            }.value
            if result.error != nil, let fallback {
                // The public path was refused (no Automation grant, most
                // likely): the last resort still gets the choice through.
                result = await Task.detached { Self.shellWithError(fallback) }.value
            }
            state.applying.remove(toggle)
            if let error = result.error, !error.isEmpty {
                state.lastError = "\(toggle.title): \(error)"
                Self.log.notice("toggle \(toggle.rawValue, privacy: .public) failed: \(error, privacy: .public)")
            }
            // The read-back is the truth — the chip settles to what
            // the system reports, not what we asked for.
            if !toggle.isMomentary {
                try? await Task.sleep(nanoseconds: 600_000_000)
                if let inline = readInline(toggle) {
                    state.isOn[toggle] = inline
                } else {
                    state.isOn[toggle] = await Task.detached { Self.probe(toggle) }.value
                }
            }
        }
    }

    // MARK: - Dock autohide (live, never a Dock restart when avoidable)

    /// The Dock chip rides the Dock utility's own live driver — the
    /// `CoreDock` pair its preview hold uses — so the Dock hides or
    /// shows in place, with no relaunch, no Mission Control reset and
    /// no break in the utility's AX observation. System Events is the
    /// public fallback; `defaults` plus `killall Dock` only the last.
    ///
    /// While the preview holds the Dock out, the choice waits: flipping
    /// under a hold would be undone by the hold's restore, so it lands
    /// the moment the hold lets go.
    private func setDockAutohide(_ on: Bool) {
        state.lastError = nil
        if dockHoldActive() {
            state.pendingDockAutohide = on
            state.lastError = "Dock: applies when the preview closes."
            waitForDockHold()
            return
        }
        if let dockDriver {
            dockDriver.setAutohideEnabled(on)
            state.isOn[.dockAutoHide] = dockDriver.isAutohideEnabled
            if dockDriver.isAutohideEnabled != on {
                state.lastError = "Dock: the Dock kept its setting."
            }
            return
        }
        fire(.dockAutoHide, on: on, command: SystemToggle.dockAutoHide.liveApplyCommand(on: on),
             fallback: SystemToggle.dockAutoHide.applyCommand(on: on))
    }

    private func waitForDockHold(attempt: Int = 0) {
        Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let pending = state.pendingDockAutohide else { return }
            if dockHoldActive(), attempt < 480 {
                waitForDockHold(attempt: attempt + 1)
                return
            }
            state.pendingDockAutohide = nil
            setDockAutohide(pending)
        }
    }

    // MARK: - Keep awake (IOPMAssertion — the public, reversible path)

    /// `caffeinate` without the process: an IOKit power assertion.
    /// Off releases it — the Mac's own bookkeeping, nothing persists.
    private func setAwake(_ hold: Bool) {
        let awake = state.awake
        if hold && !awake.held {
            var assertion = IOPMAssertionID(0)
            let status = IOPMAssertionCreateWithName(
                kIOPMAssertionTypeNoIdleSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "JR-Bar Keep Awake" as CFString,
                &assertion)
            if status == kIOReturnSuccess {
                awake.id = assertion
                awake.held = true
            } else {
                state.lastError = "Awake: the power assertion was refused."
            }
        } else if !hold && awake.held {
            IOPMAssertionRelease(awake.id)
            awake.id = 0
            awake.held = false
        }
    }

    // MARK: - Mute (CoreAudio — public, no process)

    nonisolated static func defaultOutput() -> AudioDeviceID? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
            &size, &device) == noErr, device != kAudioObjectUnknown else { return nil }
        return device
    }

    private nonisolated static func readMute() -> Bool {
        guard let device = defaultOutput() else { return false }
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &muted) == noErr
            && muted != 0
    }

    /// The reversible flip: write `kAudioDevicePropertyMute` on the
    /// default output. Devices without a mute property answer false —
    /// the chip reports the error rather than claiming the silence.
    private nonisolated static func writeMute(_ muted: Bool) -> Bool {
        guard let device = defaultOutput() else { return false }
        var value: UInt32 = muted ? 1 : 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        return AudioObjectSetPropertyData(device, &address, 0, nil,
                                          UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }

    // MARK: - Processes

    /// `defaults read`-style probe: stdout on success, nil on any
    /// failure — the caller's `onWhenAbsent` decides what absent means.
    private nonisolated static func shell(_ command: String) -> String? {
        shellWithError(command).output
    }

    /// Run a `/bin/sh -c` payload with a hard ceiling — a pended TCC
    /// prompt or a stuck AppleScript must not hang the toggle row.
    /// Both pipes drain on background queues so a chatty command can't
    /// deadlock on a full pipe (the script-trigger lesson), and the
    /// exit semaphore is what bounds the wait — never the drain.
    nonisolated static func shellWithError(
        _ command: String, timeout: TimeInterval = 8
    ) -> (output: String?, error: String?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch { return (nil, nil) }
        let drain = PipeDrain()
        let drained = DispatchGroup()
        drained.enter()
        DispatchQueue.global().async {
            drain.out = out.fileHandleForReading.readDataToEndOfFile()
            drained.leave()
        }
        drained.enter()
        DispatchQueue.global().async {
            drain.err = err.fileHandleForReading.readDataToEndOfFile()
            drained.leave()
        }
        let exited = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            process.waitUntilExit()
            exited.signal()
        }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = drained.wait(timeout: .now() + 1)
            return (nil, "timed out")
        }
        drained.wait()
        guard process.terminationStatus == 0 else {
            let text = String(data: drain.err, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (nil, text?.isEmpty == false ? text : "exited \(process.terminationStatus)")
        }
        return (String(data: drain.out, encoding: .utf8), nil)
    }

    /// The bag two drain queues fill while the caller waits on the
    /// child's exit — the group's `wait` orders the reads back.
    private final class PipeDrain: @unchecked Sendable {
        var out = Data()
        var err = Data()
    }
}

/// CoreAudio's change callbacks for the chips that mirror audio state:
/// the default output (and input) device, and the mute property on
/// whichever device is default now. One listener set per app; the
/// device listeners move when the default device does.
final class AudioListener: @unchecked Sendable {
    static let shared = AudioListener()

    /// Any watched property changed. Called on the listener queue.
    var onChange: (@Sendable () -> Void)?

    private let queue = DispatchQueue(label: "devin.jrbar.toggles.audio")
    private var started = false
    private var watchedDevices: [(device: AudioObjectID, address: AudioObjectPropertyAddress)] = []
    private lazy var deviceBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.onChange?()
    }
    private lazy var systemBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.rewatchDevices()
        self?.onChange?()
    }

    private static let systemSelectors: [AudioObjectPropertySelector] = [
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioHardwarePropertyDefaultInputDevice,
    ]

    func start() {
        queue.async { [self] in
            guard !started else { return }
            started = true
            for selector in Self.systemSelectors {
                var address = AudioObjectPropertyAddress(
                    mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain)
                AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                                    &address, queue, systemBlock)
            }
            rewatchDevices()
        }
    }

    /// Runs on `queue`: drop the old device listeners, add them on the
    /// current default output and input.
    private func rewatchDevices() {
        for var watched in watchedDevices {
            AudioObjectRemovePropertyListenerBlock(watched.device, &watched.address, queue, deviceBlock)
        }
        watchedDevices = []
        let targets: [(AudioObjectPropertySelector, AudioObjectPropertyScope)] = [
            (kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal),
            (kAudioHardwarePropertyDefaultInputDevice, kAudioDevicePropertyScopeInput),
        ]
        for (selector, scope) in targets {
            guard let device = Self.defaultDevice(selector) else { continue }
            for property in [kAudioDevicePropertyMute, kAudioDevicePropertyVolumeScalar] {
                var address = AudioObjectPropertyAddress(
                    mSelector: property, mScope: scope, mElement: kAudioObjectPropertyElementMain)
                guard AudioObjectHasProperty(device, &address) else { continue }
                if AudioObjectAddPropertyListenerBlock(device, &address, queue, deviceBlock) == noErr {
                    watchedDevices.append((device, address))
                }
            }
        }
    }

    static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioObjectID? {
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                         0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        return device
    }
}
