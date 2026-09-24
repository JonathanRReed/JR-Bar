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

/// What a decoded level-key press should do — the pure half of the
/// replace-the-HUD decision, so tests can drive it without a CGEvent.
enum SystemHUDAction: Equatable {
    /// A volume key-down we set ourselves — a 1/16 step.
    case adjustVolume
    /// The mute key — a toggle of the mute element.
    case toggleMute
    /// A brightness key-down we set ourselves — a 1/16 step, only
    /// while DisplayServices answers.
    case adjustBrightness
    /// Everything else goes back to the event stream untouched.
    case passThrough
}

/// The key→action table for the replace-the-overlay mode. The rules
/// are deliberately conservative: a press we cannot fully honour is
/// a press macOS keeps.
enum SystemHUDKeys {
    /// One HUD quantum — the 1/16 step the keys repeat in.
    static let step: Float = 1.0 / 16.0

    /// The action a key press earns under the consuming tap.
    ///
    /// * Option and Shift variants always pass through: fine-step
    ///   volume and the "open Sound/Displays prefs" shortcuts are
    ///   macOS's own meanings, not ours to rewrite.
    /// * Illumination keys always pass through: the keyboard
    ///   backlight has a private *read* (CoreBrightness's client) but
    ///   no reliable public setter — a swallowed key we cannot apply
    ///   is a lost key.
    /// * Brightness keys only count when DisplayServices' get AND set
    ///   both resolved — a read with no write is the same lost key.
    /// * Anything not a level key passes through by construction.
    static func action(for press: MediaKeyPress,
                       flags: NSEvent.ModifierFlags,
                       brightnessWritable: Bool) -> SystemHUDAction {
        guard !flags.contains(.option), !flags.contains(.shift) else {
            return .passThrough
        }
        switch press.key {
        case .volumeUp, .volumeDown: return .adjustVolume
        case .mute: return .toggleMute
        case .brightnessUp, .brightnessDown:
            return brightnessWritable ? .adjustBrightness : .passThrough
        case .illuminationUp, .illuminationDown, .illuminationToggle:
            return .passThrough
        }
    }

    /// The next level after a step — clamped, so a press at the rail
    /// still has a defined answer.
    static func stepped(_ value: Float, up: Bool) -> Float {
        min(1, max(0, value + (up ? step : -step)))
    }
}

/// The level backend the consuming tap drives — the app's copy reads
/// and writes through `SystemLevelReader`; tests hand a fake and
/// prove the step math and the swallow rules against it.
protocol SystemHUDBackend {
    var brightnessWritable: Bool { get }
    func volume() -> Float?
    func muted() -> Bool?
    func setVolume(_ value: Float) -> Bool
    func setMuted(_ muted: Bool) -> Bool
    func brightness() -> Float?
    func setBrightness(_ value: Float) -> Bool
}

/// The live backend — `SystemLevelReader`'s hardware path.
struct LiveSystemHUDBackend: SystemHUDBackend {
    var brightnessWritable: Bool { SystemLevelReader.displayBrightnessWritable }
    func volume() -> Float? { SystemLevelReader.outputVolume() }
    func muted() -> Bool? { SystemLevelReader.outputMuted() }
    func setVolume(_ value: Float) -> Bool { SystemLevelReader.setOutputVolume(value) }
    func setMuted(_ muted: Bool) -> Bool { SystemLevelReader.setOutputMuted(muted) }
    func brightness() -> Float? { SystemLevelReader.displayBrightness() }
    func setBrightness(_ value: Float) -> Bool { SystemLevelReader.setDisplayBrightness(value) }
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
            if let value = CoreAudioDefaults.volume(of: device, scope: kAudioObjectPropertyScopeOutput,
                                                    element: element) {
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

    /// Set the default output's mute element — the MUTE key's own
    /// write in replace-the-overlay mode. Same element walk as the
    /// volume writes; false where no settable mute exists.
    @discardableResult
    static func setOutputMuted(_ muted: Bool) -> Bool {
        guard let device = defaultOutputDevice() else { return false }
        for element in [kAudioObjectPropertyElementMain, 1] {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: element)
            var settable = DarwinBoolean(false)
            guard AudioObjectHasProperty(device, &address),
                  AudioObjectIsPropertySettable(device, &address, &settable) == noErr,
                  settable.boolValue else { continue }
            var value: UInt32 = muted ? 1 : 0
            if AudioObjectSetPropertyData(device, &address, 0, nil,
                                          UInt32(MemoryLayout<UInt32>.size), &value) == noErr {
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
            if let muted = CoreAudioDefaults.muted(of: device, scope: kAudioObjectPropertyScopeOutput,
                                                   element: element) {
                return muted
            }
        }
        return nil
    }

    /// Where the sound is going — the default output's name and
    /// transport, read at the key press so the level capsule's glyph is
    /// the device (AirPods, a display, the built-in speakers) and not a
    /// generic speaker. nil when CoreAudio names no default output.
    static func outputRoute() -> (name: String, transport: UInt32)? {
        guard let device = defaultOutputDevice() else { return nil }
        return (CoreAudioDefaults.name(of: device) ?? "", CoreAudioDefaults.transport(of: device) ?? 0)
    }

    private static func defaultOutputDevice() -> AudioDeviceID? { CoreAudioDefaults.defaultOutput }

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

    /// `DisplayServicesSetBrightness(display, value)` → status — the
    /// write half of the private seam, resolved the same way. Both
    /// symbols must answer before the consuming tap may swallow a
    /// brightness key; a missing set means the press passes through
    /// to Apple's stack untouched.
    private static let displayServicesSet: (@convention(c) (CGDirectDisplayID, Float) -> Int32)? = {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
              let symbol = dlsym(handle, "DisplayServicesSetBrightness") else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) (CGDirectDisplayID, Float) -> Int32).self)
    }()

    /// Whether the DisplayServices pair fully resolved — the
    /// brightness key's swallow license.
    static var displayBrightnessWritable: Bool {
        displayServicesGet != nil && displayServicesSet != nil
    }

    /// The brightness key's write in replace-the-overlay mode — nil-safe
    /// like the read: a moved framework answers false and the key
    /// press passes through instead of dying here.
    @discardableResult
    static func setDisplayBrightness(_ value: Float) -> Bool {
        guard let set = displayServicesSet else { return false }
        return set(CGMainDisplayID(), min(1, max(0, value))) == 0
    }

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

/// The level capsule's glyph and title — pure, so the device mapping is
/// pinned without audio hardware. Volume names the device the sound is
/// going to (MediaMate's device icons, off the same default-output read
/// the level comes from); the plain speaker is the three-wave one, whose
/// waves the level face lights with the level (a variable symbol, as
/// the system HUD draws it); brightness dims its sun with the level; the
/// keyboard keeps its own.
enum NotchLevelGlyph {
    static func volume(level: Float, muted: Bool, transport: UInt32?, name: String?) -> String {
        if muted || level <= 0 { return "speaker.slash.fill" }
        let lower = (name ?? "").lowercased()
        switch transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            if lower.contains("airpods max") { return "airpodsmax" }
            if lower.contains("airpods pro") { return "airpodspro" }
            if lower.contains("airpods") { return "airpods" }
            if lower.contains("beats") { return "beats.headphones" }
            return "headphones"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort:
            return "tv"
        case kAudioDeviceTransportTypeAirPlay:
            return "airplayaudio"
        case kAudioDeviceTransportTypeUSB:
            return lower.contains("headphone") || lower.contains("headset")
                ? "headphones" : "hifispeaker.fill"
        default:
            if lower.contains("headphone") { return "headphones" }
            return "speaker.wave.3.fill"
        }
    }

    static func brightness(level: Float) -> String {
        level < 0.5 ? "sun.min.fill" : "sun.max.fill"
    }

    static let keyboard = "light.max"

    /// The capsule's spoken name — the device for volume when it has
    /// one, else the key's family.
    static func title(for key: MediaKeyPress.Key, deviceName: String?) -> String {
        switch key {
        case .volumeUp, .volumeDown, .mute:
            if let deviceName, !deviceName.isEmpty { return deviceName }
            return "Volume"
        case .brightnessUp, .brightnessDown: return "Brightness"
        case .illuminationUp, .illuminationDown, .illuminationToggle: return "Keyboard backlight"
        }
    }
}

/// Watches the session event stream for aux-button key-downs and
/// reports the level the press left behind. Two modes, one tap:
///
/// * **Listen** (default): the press still changes the volume; we
///   only draw it. A read lands ~90 ms after the press so the OS has
///   applied the change, and repeated presses coalesce to one read of
///   the settled value.
/// * **Replace** (`replaceHUDWanted()` and Accessibility granted):
///   the tap consumes the volume/brightness key-downs it can fully
///   honour, performs the 1/16 step itself, and shows the capsule
///   with the value it set. Modifier variants, illumination keys,
///   brightness without DisplayServices, and every set that fails go
///   back to the stream — a press JR-Bar cannot own is a press macOS
///   keeps.
@MainActor
final class HUDKeyMonitor {
    /// The level read for one key kind — the HUD draws it.
    var onLevel: (@MainActor (MediaKeyPress.Key, Float?, Bool?) -> Void)?

    /// Whether a press earns a capsule — the notch's setting, consulted
    /// per press so toggling takes effect without touching the tap.
    var isAllowed: () -> Bool = { true }

    /// The notch's "replace the overlay" vote — consulted per press;
    /// a flip mid-flight rebuilds the tap at the next key event so a
    /// disabled setting can never leave a swallowing tap behind.
    var replaceHUDWanted: () -> Bool = { false }

    /// The level backend — the live hardware path in the app, a fake
    /// in tests.
    var backend: SystemHUDBackend = LiveSystemHUDBackend()

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    /// One delayed read per key kind — a volume nudge then a
    /// brightness nudge are two capsules; a single shared slot let
    /// the second key cancel the first's read entirely.
    private var pendingReads: [MediaKeyPress.Key: DispatchWorkItem] = [:]
    /// The Accessibility grant read — a closure like the other votes
    /// so tests can drive the deny/latch/retry cycle without a TCC
    /// state of their own.
    var isTrusted: () -> Bool = { AXIsProcessTrusted() }
    /// When a `.defaultTap` create was refused. Latched so
    /// `consumingWanted` stops asking — an untrusted create retries
    /// per key press otherwise, an error-log spam every nudge.
    /// Internal so tests can age the latch past the backoff.
    var consumingDeniedAt: Date?
    /// How long a refused consuming tap stays refused before one
    /// retry — the grant appearing sooner lifts the latch directly.
    static let consumingRetryBackoff: TimeInterval = 30
    /// The mode the running tap was built in — a listen tap cannot
    /// swallow, so flipping this is a rebuild, not a flag. Internal so
    /// tests can pin a mode without standing up a real event tap.
    var consuming = false

    /// `NX_SYSDEFINED` — the CGEventType the public enum never names.
    static let systemDefined: CGEventMask = 1 << 14

    /// The press's outcome under the current mode — pure for tests:
    /// `true` means the tap swallows the event.
    func handle(_ press: MediaKeyPress, flags: NSEvent.ModifierFlags) -> Bool {
        guard isAllowed() else { return false }
        guard consuming else {
            note(press)
            return false
        }
        let action = SystemHUDKeys.action(
            for: press, flags: flags,
            brightnessWritable: backend.brightnessWritable)
        switch action {
        case .passThrough:
            // Still ours to draw — the OS applies the change and the
            // delayed read lands the capsule on the settled value.
            note(press)
            return false
        case .adjustVolume:
            guard let current = backend.volume() else { return false }
            let next = SystemHUDKeys.stepped(
                current, up: press.key == .volumeUp)
            guard backend.setVolume(next) else { return false }
            onLevel?(press.key, next, backend.muted())
            return true
        case .toggleMute:
            guard let muted = backend.muted(),
                  backend.setMuted(!muted) else { return false }
            onLevel?(press.key, backend.volume(), !muted)
            return true
        case .adjustBrightness:
            guard let current = backend.brightness() else { return false }
            let next = SystemHUDKeys.stepped(
                current, up: press.key == .brightnessUp)
            guard backend.setBrightness(next) else { return false }
            onLevel?(press.key, next, nil)
            return true
        }
    }

    /// Whether the tap should be consuming right now — the setting
    /// AND the Accessibility grant, since a `.defaultTap` without it
    /// never comes up. A refused create is latched: while the latch
    /// stands the answer is no until the grant state moves (a fresh
    /// grant earns an immediate retry) or the backoff has passed —
    /// never a rebuild attempt per key press. Internal so tests can
    /// drive the latch without a real event tap.
    func consumingWanted() -> Bool {
        guard replaceHUDWanted() else { return false }
        let trusted = isTrusted()
        guard let deniedAt = consumingDeniedAt else { return trusted }
        guard !trusted
            || Date().timeIntervalSince(deniedAt) >= Self.consumingRetryBackoff
        else { return false }
        consumingDeniedAt = nil
        return trusted
    }

    /// Re-check the wanted mode — called from the event stream on
    /// every key event, so a settings flip or a fresh grant takes at
    /// the next press without a poll. A mismatch rebuilds the tap
    /// after this event has been answered.
    private func syncConsuming() {
        let wanted = consumingWanted()
        guard wanted != consuming else { return }
        consuming = wanted
        rebuild()
    }

    private func rebuild() {
        stop()
        start()
    }

    func start() {
        guard tap == nil else { return }
        consuming = consumingWanted()
        let mask = Self.systemDefined
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: consuming ? .defaultTap : .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, info in
                guard let info else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<HUDKeyMonitor>.fromOpaque(info).takeUnretainedValue()
                // The tap's source lives on the main run loop, so the
                // main-actor hop is a no-op — but the decision must be
                // synchronous: swallowing is a return value, not a task.
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    MainActor.assumeIsolated { monitor.reenable() }
                    return Unmanaged.passUnretained(event)
                }
                guard type.rawValue == 14, let ns = NSEvent(cgEvent: event),
                      let press = MediaKeyPress.down(in: ns) else {
                    return Unmanaged.passUnretained(event)
                }
                let swallow = MainActor.assumeIsolated {
                    monitor.syncConsuming()
                    return monitor.handle(press, flags: ns.modifierFlags)
                }
                return swallow ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: pointer) else {
            if consuming {
                // No Accessibility grant — the session refused the
                // consuming tap. Listen instead: the keys still pass
                // to macOS and the capsule still draws. The refusal
                // latches so the next key press doesn't try again.
                NotchHUD.log.error("media keys: no consuming tap — listening instead")
                consuming = false
                consumingDeniedAt = Date()
                start()
                return
            }
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
        for (_, work) in pendingReads { work.cancel() }
        pendingReads = [:]
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
        // The slot is per key kind: a brightness press must not eat
        // the volume capsule's pending read.
        pendingReads[key]?.cancel()
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
        pendingReads[key] = read
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.09, execute: read)
    }
}
