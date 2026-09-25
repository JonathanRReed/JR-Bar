import CoreAudio
import Foundation

/// The plain CoreAudio reads the notch's audio surfaces share — which
/// device is the default output or input, and that device's name,
/// transport, UID, volume and mute. Pure reads off the HAL, callable
/// from any thread: the toggles' listener queue, the tap's work queue,
/// a key press on the main thread. Nothing here listens or writes;
/// each caller keeps its own listeners and its own writes.
///
/// Every read fails soft: nil when CoreAudio does not answer, so the
/// caller picks its own fallback ("Audio Output", no meter, a throw).
nonisolated enum CoreAudioDefaults {
    /// The device a system default selector names — output, input or
    /// the alert device. nil when the HAL does not answer or names
    /// `kAudioObjectUnknown`.
    static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioObjectID? {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = globalAddress(selector)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                         0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        return device
    }

    /// The default output device.
    static var defaultOutput: AudioDeviceID? { defaultDevice(kAudioHardwarePropertyDefaultOutputDevice) }

    /// The default input device.
    static var defaultInput: AudioDeviceID? { defaultDevice(kAudioHardwarePropertyDefaultInputDevice) }

    /// The device's display name ("AirPods Pro", "MacBook Pro Speakers").
    static func name(of device: AudioObjectID) -> String? {
        var address = globalAddress(kAudioObjectPropertyName)
        var name = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        guard withUnsafeMutablePointer(to: &name, {
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0)
        }) == noErr else { return nil }
        return name as String
    }

    /// The device's transport (`kAudioDeviceTransportTypeBluetooth`, …).
    static func transport(of device: AudioObjectID) -> UInt32? {
        var address = globalAddress(kAudioDevicePropertyTransportType)
        var transport = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr else { return nil }
        return transport
    }

    /// The device's persistent UID. The getter hands back a retained
    /// CFString — read it through Unmanaged and take the retain, or
    /// every read leaks one.
    static func uid(of device: AudioObjectID) -> String? {
        var address = globalAddress(kAudioDevicePropertyDeviceUID)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr,
              let uid else { return nil }
        return uid.takeRetainedValue() as String
    }

    /// The device's volume scalar, 0…1, on one scope and element — nil
    /// where that element carries no volume.
    static func volume(of device: AudioObjectID, scope: AudioObjectPropertyScope,
                       element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> Float? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                                 mScope: scope, mElement: element)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value = Float(0)
        var size = UInt32(MemoryLayout<Float>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    /// The device's mute flag on one scope and element — nil where that
    /// element carries no mute.
    static func muted(of device: AudioObjectID, scope: AudioObjectPropertyScope,
                      element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> Bool? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                                 mScope: scope, mElement: element)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }

    private static func globalAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }
}

/// The output devices the card's route picker offers, and the one write
/// it makes: the system default output — boring.notch 2.8's route picker,
/// through the public HAL (`kAudioHardwarePropertyDefaultOutputDevice`).
/// Reads fail soft to an empty list; the write says whether it took.
nonisolated enum CoreAudioOutputs {
    struct Device: Equatable, Identifiable, Sendable {
        let id: AudioDeviceID
        let name: String
        let transport: UInt32?

        /// The device's glyph: AirPods-shaped for Bluetooth, a display
        /// for HDMI and DisplayPort, the Mac's speakers otherwise.
        var symbol: String { CoreAudioOutputs.symbol(name: name, transport: transport) }
    }

    /// The glyph for a device, from its transport and a name hint.
    static func symbol(name: String, transport: UInt32?) -> String {
        let lower = name.lowercased()
        switch transport {
        case kAudioDeviceTransportTypeBluetooth?, kAudioDeviceTransportTypeBluetoothLE?:
            if lower.contains("airpods max") { return "airpodsmax" }
            if lower.contains("airpods pro") { return "airpodspro" }
            if lower.contains("airpods") { return "airpods" }
            return "headphones"
        case kAudioDeviceTransportTypeHDMI?, kAudioDeviceTransportTypeDisplayPort?:
            return "tv"
        case kAudioDeviceTransportTypeAirPlay?:
            return "airplayaudio"
        case kAudioDeviceTransportTypeUSB?:
            return lower.contains("headphone") || lower.contains("headset") ? "headphones" : "hifispeaker"
        default:
            return lower.contains("headphone") ? "headphones" : "hifispeaker"
        }
    }

    /// Every device the sound can be sent to, by name: it plays (an
    /// output stream), it isn't hidden, and macOS lets it be the default
    /// output — the list Sound settings shows. An aggregate's private
    /// parts or a capture-only driver would only refuse the pick.
    static func all() -> [Device] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address,
                                             0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                         0, nil, &size, &ids) == noErr else { return [] }
        return ids.filter(isOffered).compactMap { id in
            guard let name = CoreAudioDefaults.name(of: id) else { return nil }
            return Device(id: id, name: name, transport: CoreAudioDefaults.transport(of: id))
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Whether the picker offers a device, from what the HAL says of it.
    /// A device that doesn't say whether it's hidden is shown; one that
    /// doesn't say whether it can be the default is left out, since the
    /// pick would be refused.
    static func offers(hasOutput: Bool, hidden: Bool?, canBeDefault: Bool?) -> Bool {
        hasOutput && hidden != true && canBeDefault == true
    }

    static func isOffered(_ device: AudioDeviceID) -> Bool {
        offers(hasOutput: hasOutput(device),
               hidden: flag(kAudioDevicePropertyIsHidden, of: device, scope: kAudioObjectPropertyScopeGlobal),
               canBeDefault: flag(kAudioDevicePropertyDeviceCanBeDefaultDevice, of: device,
                                  scope: kAudioObjectPropertyScopeOutput))
    }

    /// A yes-or-no property of a device; nil where the device lacks it.
    private static func flag(_ selector: AudioObjectPropertySelector, of device: AudioDeviceID,
                             scope: AudioObjectPropertyScope) -> Bool? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }

    /// Whether the device plays sound: it has at least one output stream.
    static func hasOutput(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                 mScope: kAudioObjectPropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
    }

    /// Make `device` the system's default output. True when the HAL took it.
    @discardableResult
    static func setDefault(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var id = device
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                          UInt32(MemoryLayout<AudioDeviceID>.size), &id) == noErr
    }
}

/// The route picker's ears while the card is open: the HAL's device list
/// and its default output. AirPods that connect, a display that is
/// plugged in, or a switch made in Control Center reach the picker at
/// once. Nothing is polled; the two listeners go when `stop` runs.
@MainActor
final class CoreAudioOutputsWatch {
    private var listeners: [(selector: AudioObjectPropertySelector, block: AudioObjectPropertyListenerBlock)] = []

    init(_ changed: @escaping @MainActor () -> Void) {
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice] {
            var address = Self.address(selector)
            let block: AudioObjectPropertyListenerBlock = { _, _ in
                MainActor.assumeIsolated { changed() }
            }
            if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address,
                                                   DispatchQueue.main, block) == noErr {
                listeners.append((selector, block))
            }
        }
    }

    func stop() {
        for listener in listeners {
            var address = Self.address(listener.selector)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address,
                                                   DispatchQueue.main, listener.block)
        }
        listeners.removeAll()
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }
}
