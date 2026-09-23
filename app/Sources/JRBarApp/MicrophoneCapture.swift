import CoreAudio
import Foundation

/// Whether some other app is capturing from a microphone right now — a
/// call, a recording, dictation. Asked per process, not per device:
/// `kAudioDevicePropertyDeviceIsRunningSomewhere` on the default input
/// is device-wide, and AirPods or a USB headset are one device with both
/// directions, so music playing through them read as a live mic. Here a
/// process counts only while CoreAudio says it runs an input stream
/// (`kAudioProcessPropertyIsRunningInput`) from a device, and never when
/// it is JR-Bar itself — the notch visualizer's process tap runs input
/// in this process. A tap elsewhere (another app's visualizer, a screen
/// recorder's system audio) hears output, not a microphone: it lists no
/// input device, or only an aggregate built on a tap, and is skipped.
///
/// A handful of HAL reads, no microphone permission (running state is
/// not capture), no poll: callers ask at the moment it matters.
enum MicrophoneCapture {
    /// One CoreAudio client, as far as the decision needs it.
    struct Client: Equatable, Sendable {
        var pid: pid_t
        /// `kAudioProcessPropertyIsRunningInput`: IO running with at
        /// least one active input stream.
        var runningInput: Bool
        /// Input devices it uses that are not an aggregate over a
        /// process tap — hardware, a headset, a call's own aggregate.
        var microphoneDevices: Int
    }

    /// The decision, pure: another process capturing from a real input.
    nonisolated static func isLive(_ clients: [Client], ownPID: pid_t) -> Bool {
        clients.contains { $0.pid != ownPID && $0.runningInput && $0.microphoneDevices > 0 }
    }

    /// The decision over the Mac's clients right now. Any read that
    /// fails leaves that client out: a sound that plays through a call
    /// is the old behaviour, a sound silently dropped is not.
    nonisolated static func isLive() -> Bool {
        isLive(clients(skipping: getpid()), ownPID: getpid())
    }

    /// Every CoreAudio client, with devices read only for the ones that
    /// run input and are not `skipping` — the rest cannot count anyway.
    nonisolated static func clients(skipping ownPID: pid_t) -> [Client] {
        objects(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList).compactMap { process in
            guard let raw = uint32(process, kAudioProcessPropertyPID) else { return nil }
            let pid = pid_t(bitPattern: raw)
            let runningInput = uint32(process, kAudioProcessPropertyIsRunningInput) == 1
            guard runningInput, pid != ownPID else {
                return Client(pid: pid, runningInput: runningInput, microphoneDevices: 0)
            }
            let devices = objects(process, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeInput)
            let microphones = devices.filter { objects($0, kAudioAggregateDevicePropertyTapList).isEmpty }
            return Client(pid: pid, runningInput: true, microphoneDevices: microphones.count)
        }
    }

    private nonisolated static func address(_ selector: AudioObjectPropertySelector,
                                            _ scope: AudioObjectPropertyScope) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private nonisolated static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var property = address(selector, kAudioObjectPropertyScopeGlobal)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &property, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    /// An object-list property; empty when absent or unreadable.
    private nonisolated static func objects(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                            scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var property = address(selector, scope)
        guard AudioObjectHasProperty(object, &property) else { return [] }
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &property, 0, nil, &size) == noErr, size > 0 else { return [] }
        var list = [AudioObjectID](repeating: AudioObjectID(kAudioObjectUnknown),
                                   count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &property, 0, nil, &size, &list) == noErr else { return [] }
        return Array(list.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }
}
