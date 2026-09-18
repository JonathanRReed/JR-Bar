import CoreAudio
import Foundation
import IOKit.pwr_mgt
import JRBarCore
import os

/// The card's toggle strip — One Switch's grammar with JR-Bar's
/// honesty rules. State is read back from the system, never asserted:
/// a Finder write that failed shows off, not the intent. Applies run
/// detached so a pend (TCC, a stuck `osascript`) can never reach the
/// render path; the read-back lands a beat later and settles the chip.
@MainActor
@Observable
final class SystemTogglesStore {
    /// The live on-state per stateful toggle — refreshed on show and
    /// after each apply. Momentary verbs never appear here.
    private(set) var isOn: [SystemToggle: Bool] = [:]
    /// A toggle mid-apply — the chip pulses rather than lie.
    private(set) var applying: Set<SystemToggle> = []
    /// The last apply's honest outcome — a denied `defaults` write or
    /// an AppleScript refusal lands here so the chip can say so.
    private(set) var lastError: String?

    private nonisolated static let log = Logger(
        subsystem: "devin.jrbar", category: "toggles")

    /// The keep-awake assertion while held — our own state, so the
    /// chip reads the truth directly. Boxed nonisolated so `deinit`
    /// can release it: a `@MainActor` property can't be read at
    /// teardown, but the assertion must not outlive the store.
    private let awake = AwakeAssertion()
    private var awakeHeld: Bool { awake.held }

    /// The box `deinit` reads — mutated only on the actor, so the
    /// unchecked-Sendable is disciplined by construction.
    private final class AwakeAssertion: @unchecked Sendable {
        var id: IOPMAssertionID = 0
        var held = false
    }

    // MARK: - Reads

    /// Re-read every stateful toggle's truth — on card show, and
    /// after an apply settles. In-process reads answer inline; the
    /// `defaults` probes run detached — a card show must not pay for
    /// process lifetimes on the render path.
    func refresh() {
        for toggle in SystemToggle.allCases where !toggle.isMomentary {
            if let inline = readInline(toggle) {
                isOn[toggle] = inline
            } else {
                Task {
                    let value = await Task.detached { Self.probe(toggle) }.value
                    isOn[toggle] = value
                }
            }
        }
    }

    /// The reads that cost no process: our own bookkeeping, a domain
    /// lookup, a CoreAudio property. `nil` means "probe it off-actor".
    private func readInline(_ toggle: SystemToggle) -> Bool? {
        switch toggle {
        case .keepAwake:
            return awakeHeld
        case .darkMode:
            // The global domain's answer — "Dark" present means on;
            // absent means light. No process needed.
            return (UserDefaults.standard.persistentDomain(
                forName: UserDefaults.globalDomain)?["AppleInterfaceStyle"] as? String) == "Dark"
        case .mute:
            return Self.readMute()
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

    // MARK: - Applies

    /// A chip tap: momentary verbs fire, stateful toggles flip and
    /// read back. One apply per toggle at a time — a double-tap waits
    /// for the read-back rather than racing the system.
    func apply(_ toggle: SystemToggle) {
        guard !applying.contains(toggle) else { return }
        switch toggle {
        case .keepAwake:
            setAwake(!awakeHeld)
            isOn[.keepAwake] = awakeHeld
            return
        case .mute:
            let next = !Self.readMute()
            if Self.writeMute(next) {
                isOn[.mute] = next
            } else {
                lastError = "No output device to mute."
            }
            return
        case .lock, .screenSaver:
            fire(toggle, on: true)
            return
        default:
            if let current = isOn[toggle] ?? readInline(toggle) {
                fire(toggle, on: !current)
            } else {
                // No read yet — probe off-actor before deciding the flip.
                Task {
                    let current = await Task.detached { Self.probe(toggle) }.value
                    isOn[toggle] = current
                    fire(toggle, on: !current)
                }
            }
        }
    }

    /// A shell-backed flip: run detached, read the truth back after
    /// the settle beat (Finder/Dock relaunches take a moment), and
    /// keep any stderr honest — a refused write lands in `lastError`.
    private func fire(_ toggle: SystemToggle, on: Bool) {
        guard let command = toggle.applyCommand(on: on) else { return }
        applying.insert(toggle)
        lastError = nil
        Task {
            let result = await Task.detached {
                Self.shellWithError(command)
            }.value
            applying.remove(toggle)
            if let error = result.error, !error.isEmpty {
                lastError = "\(toggle.title): \(error)"
                Self.log.notice("toggle \(toggle.rawValue, privacy: .public) failed: \(error, privacy: .public)")
            }
            // The read-back is the truth — the chip settles to what
            // the system reports, not what we asked for.
            if !toggle.isMomentary {
                try? await Task.sleep(nanoseconds: 600_000_000)
                isOn[toggle] = await Task.detached { Self.probe(toggle) }.value
            }
        }
    }

    // MARK: - Keep awake (IOPMAssertion — the public, reversible path)

    /// `caffeinate` without the process: an IOKit power assertion.
    /// Off releases it — the Mac's own bookkeeping, nothing persists.
    private func setAwake(_ hold: Bool) {
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
                lastError = "Awake: the power assertion was refused."
            }
        } else if !hold && awake.held {
            IOPMAssertionRelease(awake.id)
            awake.id = 0
            awake.held = false
        }
    }

    /// The store dies before the app does — release the assertion so
    /// a left-on state can't outlive the toggle that owns it. A
    /// recreated store reads `awakeHeld == false`; only a released
    /// assertion keeps that chip honest.
    deinit {
        if awake.held { IOPMAssertionRelease(awake.id) }
    }

    // MARK: - Mute (CoreAudio — public, no process)

    private nonisolated static func defaultOutput() -> AudioDeviceID? {
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
