import AppKit
import CoreAudio
import JRBarCore

/// A volume/brightness key press decoded from an `NX_SYSDEFINED`
/// event — the aux-control subtype (8). `data1` packs the key id in
/// the top half, the key state (0x0A down / 0x0B up) and a repeat bit
/// in the low byte — the layout every media-key tap has used since
/// SPMediaKeyTap.
struct MediaKeyPress: Equatable, Sendable {
    enum Key: Int, Equatable, Sendable {
        case volumeUp = 0
        case volumeDown = 1
        case brightnessUp = 2
        case brightnessDown = 3
        case mute = 7
        /// NX_KEYTYPE_ILLUMINATION_* — the keyboard-backlight keys.
        /// macOS 13+ routes F5/F6 elsewhere by default, so these only
        /// arrive where a key still emits them (Fn-combos, Touch Bar
        /// sliders, older layouts) — a missing press draws nothing.
        case illuminationDown = 21
        case illuminationUp = 22
        case illuminationToggle = 23
    }

    let key: Key
    /// A held key repeats — each repeat is another nudge to show.
    let isRepeat: Bool

    /// The key the event carries, or nil for anything that is not an
    /// aux-button key-down (releases and unrelated subtypes carry no
    /// HUD).
    static func down(in event: NSEvent) -> MediaKeyPress? {
        down(type: event.type, subtype: event.subtype.rawValue, data1: event.data1)
    }

    /// The raw-field decode, split out so tests can feed it without an
    /// NSEvent to wrap.
    static func down(type: NSEvent.EventType, subtype: Int16, data1: Int) -> MediaKeyPress? {
        guard type == .systemDefined, subtype == 8 else { return nil }
        guard (data1 >> 8) & 0xFF == 0x0A,
              let key = Key(rawValue: (data1 >> 16) & 0xFFFF) else { return nil }
        return MediaKeyPress(key: key, isRepeat: data1 & 0x1 != 0)
    }
}

/// The level a key press leaves behind: volume/mute off the default
/// output (AudioHardwareService — virtual-master so HDMI, AirPods and
/// aggregates all read honestly), brightness off DisplayServices
/// (resolved at runtime — a private framework may always move) with
/// the IOKit display parameter as the Intel-era fallback. Every read
/// fails soft: no device, no framework, no meter.
enum SystemLevelReader {
    /// The default output's master scalar, 0…1 — the element-main
    /// read first, channel 1 for devices that keep volume per channel.
    /// nil when the device has no hardware volume (the key press
    /// changed nothing we could honour anyway).
    static func outputVolume() -> Float? {
        guard let device = defaultOutputDevice() else { return nil }
        for element in [kAudioObjectPropertyElementMain, 1] {
            var value = Float(0)
            var size = UInt32(MemoryLayout<Float>.size)
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: element)
            if AudioObjectHasProperty(device, &address),
               AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr {
                return value
            }
        }
        return nil
    }

    /// Set the default output's master scalar — the combined system
    /// item's slider. Same element walk as `outputVolume`; returns
    /// whether a writable element answered.
    @discardableResult
    static func setOutputVolume(_ value: Float) -> Bool {
        guard let device = defaultOutputDevice() else { return false }
        let clamped = min(1, max(0, value))
        for element in [kAudioObjectPropertyElementMain, 1] {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: element)
            var settable = DarwinBoolean(false)
            guard AudioObjectHasProperty(device, &address),
                  AudioObjectIsPropertySettable(device, &address, &settable) == noErr,
                  settable.boolValue else { continue }
            var scalar = clamped
            if AudioObjectSetPropertyData(device, &address, 0, nil,
                                          UInt32(MemoryLayout<Float>.size), &scalar) == noErr {
                var muted = UInt32(0)
                var canSetMute = DarwinBoolean(false)
                address.mSelector = kAudioDevicePropertyMute
                if AudioObjectIsPropertySettable(device, &address, &canSetMute) == noErr,
                   canSetMute.boolValue {
                    AudioObjectSetPropertyData(device, &address, 0, nil,
                                               UInt32(MemoryLayout<UInt32>.size), &muted)
                }
                return true
            }
        }
        return false
    }

    /// Whether the default output is muted — nil when the device does
    /// not carry a mute element.
    static func outputMuted() -> Bool? {
        guard let device = defaultOutputDevice() else { return nil }
        for element in [kAudioObjectPropertyElementMain, 1] {
            var muted = UInt32(0)
            var size = UInt32(MemoryLayout<UInt32>.size)
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: element)
            if AudioObjectHasProperty(device, &address),
               AudioObjectGetPropertyData(device, &address, 0, nil, &size, &muted) == noErr {
                return muted != 0
            }
        }
        return nil
    }

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
        ) == noErr else { return nil }
        return device
    }

    /// The built-in display's brightness, 0…1: DisplayServices first
    /// (the Apple-silicon path), then the IOKit display parameter.
    /// nil when neither answers — an external-only desk has no panel
    /// the key would drive.
    static func displayBrightness() -> Float? {
        if let get = displayServicesGet {
            var value = Float(0)
            if get(CGMainDisplayID(), &value) == 0 { return value }
        }
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("IODisplayConnect"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var value = Float(0)
        guard IODisplayGetFloatParameter(service, 0, kIODisplayBrightnessKey as CFString, &value)
                == kIOReturnSuccess else { return nil }
        return value
    }

    /// `DisplayServicesGetBrightness(display, *value)` → status —
    /// looked up once; a nil symbol means the framework moved and the
    /// IOKit path takes over.
    private static let displayServicesGet: (@convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32)? = {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
              let symbol = dlsym(handle, "DisplayServicesGetBrightness") else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32).self)
    }()

    /// The keyboard backlight's level, 0…1 — CoreBrightness's private
    /// `KeyboardBrightnessClient`, looked up at runtime the way
    /// boring.notch reads it. nil where the class moved or the machine
    /// has no backlit keyboard — a nil read draws no capsule.
    static func keyboardBacklight() -> Float? {
        guard let client = keyboardBacklightClient else { return nil }
        return (client as? NSObject)?.value(forKey: "brightness")
            .flatMap { ($0 as? NSNumber)?.floatValue }
    }

    /// The shared backlight client, resolved once. Both class names
    /// ship across releases — try them in order. `nonisolated(unsafe)`:
    /// the client is read-only after creation and every read lands on
    /// the main actor's HUD path anyway.
    nonisolated(unsafe) private static let keyboardBacklightClient: AnyObject? = {
        guard dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness",
                     RTLD_LAZY) != nil else { return nil }
        for name in ["KeyboardBrightnessClient", "CBKeyboardBrightnessClient"] {
            guard let cls = NSClassFromString(name) else { continue }
            let alloc = (cls as AnyObject).perform(NSSelectorFromString("alloc"))?
                .takeUnretainedValue()
            if let client = alloc?.perform(NSSelectorFromString("init"))?.takeUnretainedValue() {
                return client
            }
        }
        return nil
    }()
}

/// Watches the session event stream for aux-button key-downs and
/// reports the level the press left behind. The tap listens, never
/// swallows — the press still changes the volume; we only draw it.
/// A read lands ~90 ms after the press so the OS has applied the
/// change, and repeated presses coalesce to one read of the settled
/// value.
@MainActor
final class HUDKeyMonitor {
    /// The level read for one key kind — the HUD draws it.
    var onLevel: (@MainActor (MediaKeyPress.Key, Float?, Bool?) -> Void)?

    /// Whether a press earns a capsule — the notch's setting, consulted
    /// per press so toggling takes effect without touching the tap.
    var isAllowed: () -> Bool = { true }

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var pendingRead: DispatchWorkItem?

    /// `NX_SYSDEFINED` — the CGEventType the public enum never names.
    static let systemDefined: CGEventMask = 1 << 14

    func start() {
        guard tap == nil else { return }
        let mask = Self.systemDefined
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, info in
                guard let info else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<HUDKeyMonitor>.fromOpaque(info).takeUnretainedValue()
                // The tap's source lives on the main run loop. The
                // decode stays in the callback (CGEvent is not
                // Sendable); only the press hops actors.
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    MainActor.assumeIsolated { monitor.reenable() }
                    return Unmanaged.passUnretained(event)
                }
                guard type.rawValue == 14, let ns = NSEvent(cgEvent: event),
                      let press = MediaKeyPress.down(in: ns) else {
                    return Unmanaged.passUnretained(event)
                }
                MainActor.assumeIsolated { monitor.note(press) }
                return Unmanaged.passUnretained(event)
            },
            userInfo: pointer) else {
            NotchHUD.log.error("media keys: no event tap — the capsules stay off")
            return
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        self.tap = nil
        source = nil
        pendingRead?.cancel()
        pendingRead = nil
    }

    /// A tap the window server timed out comes back disabled — wake it.
    private func reenable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    /// One decoded key-down: schedule the read that lands after the OS
    /// has applied it.
    private func note(_ press: MediaKeyPress) {
        guard isAllowed() else { return }
        let key = press.key
        // The OS applies the change off the event stream — read once,
        // a beat later, so a burst of presses settles to one meter.
        pendingRead?.cancel()
        let read = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch key {
                case .volumeUp, .volumeDown, .mute:
                    self.onLevel?(key, SystemLevelReader.outputVolume(),
                                  SystemLevelReader.outputMuted())
                case .brightnessUp, .brightnessDown:
                    self.onLevel?(key, SystemLevelReader.displayBrightness(), nil)
                case .illuminationUp, .illuminationDown, .illuminationToggle:
                    self.onLevel?(key, SystemLevelReader.keyboardBacklight(), nil)
                }
            }
        }
        pendingRead = read
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.09, execute: read)
    }
}
