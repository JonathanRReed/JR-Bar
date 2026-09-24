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
