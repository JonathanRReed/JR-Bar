import CoreAudio
import Foundation
import JRBarCore

/// The wing's transient device notices — a charger landing or leaving,
/// a battery filling, headphones taking the audio route. Composed here
/// into slots so the controller stays a geometry owner; every notice is
/// a real transition off a real system signal, never a poll inventing
/// state. `noticeKey`/`cooldown` mirror the island's capsule queue: a
/// reconnect flap inside the window is strobe, not news.
enum ScreenBarNotices {
    /// How long a notice holds the wing — the island's capsule life, so
    /// both surfaces speak for the same beat.
    static let life: TimeInterval = AlcoveCapsuleQueue.life
    /// The same subject repeating inside this window is suppressed.
    static let cooldown: TimeInterval = AlcoveCapsuleQueue.sameKeyCooldown

    /// A power transition → a right-wing slot ("Charging · 84%"), or nil
    /// when `AlcovePower.notice` says the change was not news.
    static func power(from old: AlcovePowerState, to new: AlcovePowerState) -> ScreenBarWingSlot? {
        guard let notice = AlcovePower.notice(from: old, to: new,
                                              id: UUID().uuidString,
                                              kinds: AlcoveCapsuleKinds()) else { return nil }
        return ScreenBarWingSlot(text: notice.subtitle, symbol: notice.kind.symbol,
                                 tone: .attention)
    }

    /// An output-route change → a right-wing slot ("AirPods Pro"), or
    /// nil when the reroute repeated inside the cooldown — a Bluetooth
    /// flap is strobe, not a new connection. `now` is the caller's clock
    /// so the policy is testable; `recent` is the caller's memory.
    static func audio(name: String, transport: UInt32,
                      recent: [String: Date], now: Date) -> (slot: ScreenBarWingSlot?, recent: [String: Date]) {
        var recent = recent.filter { now.timeIntervalSince($0.value) < cooldown }
        let key = "audio:\(name)"
        if let seen = recent[key], now.timeIntervalSince(seen) < cooldown {
            return (nil, recent)
        }
        recent[key] = now
        let symbol = transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE ? "airpodspro" : "headphones"
        return (ScreenBarWingSlot(text: name, symbol: symbol, tone: .neutral), recent)
    }
}

/// The default audio output device, watched through CoreAudio's property
/// listener: headphones connecting reroute the default output, which is
/// the honest "audio went somewhere" signal — no Bluetooth SPI, no
/// entitlement, and a device that pairs without taking the route does
/// not speak. The first read is a baseline; only changes fire.
@MainActor
final class ScreenBarAudioMonitor {
    /// (name, transport) on a real output-device change — never the
    /// baseline read.
    var onChange: (@MainActor (String, UInt32) -> Void)?

    private var last: AudioDeviceID = 0
    /// The registered block — removal requires the identical listener.
    private var listener: AudioObjectPropertyListenerBlock?

    func start() {
        guard listener == nil else { return }
        last = Self.outputDevice()
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.deviceChanged() }
        }
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
        listener = block
    }

    func stop() {
        guard let listener else { return }
        self.listener = nil
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, listener)
        last = 0
    }

    private func deviceChanged() {
        let current = Self.outputDevice()
        guard current != 0, current != last else { return }
        last = current
        onChange?(Self.deviceName(current), Self.transportType(current))
    }

    /// The current default output device, or 0 when CoreAudio cannot say.
    private static func outputDevice() -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &device) == noErr else { return 0 }
        return device
    }

    private static func deviceName(_ device: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var name = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        guard withUnsafeMutablePointer(to: &name, {
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0)
        }) == noErr else { return "Audio Output" }
        return name as String
    }

    private static func transportType(_ device: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var transport = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr else { return 0 }
        return transport
    }
}
