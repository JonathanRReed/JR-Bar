import AppKit
import IOBluetooth
import JRBarCore
import OSLog

/// The system announcements Alcove surfaces in the island: a Focus
/// mode turning on or off, a Bluetooth device joining or leaving, Caps
/// Lock, a display arriving or going. Each watcher is quiet until
/// something actually changes — no polling, no entitlement asks — and
/// each change becomes an `AlcoveNotice` of its own kind, so the island
/// speaks it through the same queue as the agents' news (the HUD's pill
/// only when the island can't).
@MainActor
final class NotchAnnouncements {
    static let log = Logger(subsystem: "devin.jrbar", category: "announce")

    /// The notch settings' vote — consulted per announcement so a
    /// mid-flight change never strands a watcher.
    var isAllowed: () -> Bool = { true }
    /// Whether the Screen Bar's ear already names the audio route — a
    /// headphone joining is then its news, not ours.
    var earAnnouncesAudioRoute: () -> Bool = { false }
    /// What to do with one — the HUD's announcer.
    var announce: (AlcoveNotice) -> Void = { _ in }
    /// The Mac's Focus as it stands — the start's baseline, then every
    /// flip — whether or not announcements are allowed: the island's
    /// quiet hold follows the Focus even when nothing is said about it.
    /// Called after the flip's announcement, so "Focus off" speaks
    /// before anything the Focus held.
    var onFocus: (_ name: String, _ on: Bool) -> Void = { _, _ in }

    private let focus = FocusWatcher()
    private let bluetooth = BluetoothWatcher()
    private let capsLock = CapsLockWatcher()
    private let displays = DisplayWatcher()
    private(set) var started = false

    func start() {
        guard !started else { return }
        started = true
        focus.onChange = { [weak self] name, on in
            guard let self, self.isAllowed() else { return }
            self.announce(Self.focusNotice(name: name, on: on))
        }
        focus.onSettle = { [weak self] name, on in self?.onFocus(name, on) }
        bluetooth.onChange = { [weak self] change in
            guard let self, self.isAllowed() else { return }
            guard let notice = Self.deviceNotice(change,
                                                 earAnnouncesAudioRoute: self.earAnnouncesAudioRoute())
            else { return }
            self.announce(notice)
        }
        capsLock.onToggle = { [weak self] on in
            guard let self, self.isAllowed() else { return }
            self.announce(Self.capsLockNotice(on: on))
        }
        displays.onChange = { [weak self] connected in
            guard let self, self.isAllowed() else { return }
            self.announce(Self.displayNotice(connected: connected))
        }
        focus.start()
        bluetooth.start()
        capsLock.start()
        displays.start()
    }

    // MARK: Notices

    /// "Work · Focus on" with the mode's own glyph; off names the mode
    /// that ended when the watcher knew it.
    static func focusNotice(name: String, on: Bool) -> AlcoveNotice {
        AlcoveNotice(id: UUID().uuidString, kind: .focus, title: name,
                     subtitle: on ? "Focus on" : "Focus off",
                     key: "focus:\(on ? "on" : "off")",
                     glyph: on ? focusSymbol(for: name) : "moon")
    }

    /// A device joining or leaving. A headphone joining while the ear
    /// announces the audio route is the ear's news — nil here, so the
    /// top of the screen never says "AirPods" twice. Leaving is never
    /// the ear's (the route notice only speaks for where the sound
    /// goes), so a disconnect always speaks.
    static func deviceNotice(_ change: BluetoothWatcher.Change,
                             earAnnouncesAudioRoute: Bool) -> AlcoveNotice? {
        if change.connected, change.isAudio, earAnnouncesAudioRoute { return nil }
        let subtitle: String
        if change.connected {
            subtitle = change.battery.map { "Connected · \($0)%" } ?? "Connected"
        } else {
            subtitle = "Disconnected"
        }
        return AlcoveNotice(id: UUID().uuidString, kind: .device, title: change.name,
                            subtitle: subtitle,
                            key: "device:\(change.name):\(change.connected ? "on" : "off")",
                            glyph: deviceSymbol(name: change.name, isAudio: change.isAudio,
                                                connected: change.connected))
    }

    static func capsLockNotice(on: Bool) -> AlcoveNotice {
        AlcoveNotice(id: UUID().uuidString, kind: .capsLock, title: "Caps Lock",
                     subtitle: on ? "On" : "Off", key: "capslock",
                     glyph: on ? "capslock.fill" : "capslock")
    }

    static func displayNotice(connected: Bool) -> AlcoveNotice {
        AlcoveNotice(id: UUID().uuidString, kind: .display, title: "Display",
                     subtitle: connected ? "Connected" : "Disconnected",
                     key: "display:\(connected ? "on" : "off")",
                     glyph: connected ? "display" : "display.trianglebadge.exclamationmark")
    }

    /// The device's own glyph where its name says what it is — AirPods,
    /// Beats, a keyboard, a mouse or trackpad — else headphones for
    /// audio and a plain Bluetooth mark for the rest.
    static func deviceSymbol(name: String, isAudio: Bool, connected: Bool) -> String {
        let lower = name.lowercased()
        if lower.contains("airpods max") { return "airpodsmax" }
        if lower.contains("airpods pro") { return "airpodspro" }
        if lower.contains("airpods") { return "airpods" }
        if lower.contains("beats") { return "beats.headphones" }
        if lower.contains("keyboard") { return "keyboard" }
        if lower.contains("trackpad") { return "rectangle.and.hand.point.up.left" }
        if lower.contains("mouse") { return "magicmouse" }
        if isAudio { return "headphones" }
        return connected ? "wave.3.right" : "wave.3.right.circle"
    }

    /// The daemon's `focus_sync` reading of the same assertions DB —
    /// forwarded on every state push so an app without Full Disk
    /// Access still hears a toggle. The file watch stays the primary
    /// reader; the daemon feed only lands when it is unreadable.
    func noteDaemonFocus(mode: String?, source: String?) {
        focus.noteDaemon(mode: mode, source: source)
    }

    private static func focusSymbol(for name: String) -> String {
        switch name {
        case "Sleep": return "moon.zzz.fill"
        case "Work": return "briefcase.fill"
        case "Personal": return "person.fill"
        case "Driving": return "car.fill"
        case "Gaming": return "gamecontroller.fill"
        default: return "moon.fill"
        }
    }
}

/// Focus state without the Focus Status entitlement: macOS keeps the
/// live assertion set in `~/Library/DoNotDisturb/DB/Assertions.json`,
/// rewriting the file on every toggle. We watch the directory (the
/// system swaps the file atomically, which a file watch would lose on
/// the first rename) and announce when the set flips between empty and
/// non-empty.
@MainActor
final class FocusWatcher {
    /// A flip worth announcing — never the baseline.
    var onChange: (_ mode: String, _ on: Bool) -> Void = { _, _ in }
    /// The Focus as it now stands: the baseline once, then after every
    /// flip's `onChange`.
    var onSettle: (_ mode: String, _ on: Bool) -> Void = { _, _ in }

    private var source: DispatchSourceFileSystemObject?
    private var debounce: DispatchWorkItem?
    /// The baseline read at start — never announces, only diffs.
    private var active: (on: Bool, mode: String)?
    /// The Assertions.json read; the tests stand in an unreadable one.
    var readFile: () -> (on: Bool, mode: String)? = { FocusWatcher.read() }

    private static var dbDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/DoNotDisturb/DB", isDirectory: true)
    }

    func start() {
        active = readFile()
        if let active { onSettle(active.mode, active.on) }
        let fd = open(Self.dbDirectory.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            // The DB rewrite can be a few writes in a burst — one read
            // per settle, never per event.
            self?.debounce?.cancel()
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.readChanged() }
            }
            self?.debounce = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    private func readChanged() {
        let now = readFile()
        let same = (now?.on == active?.on && now?.mode == active?.mode)
            || (now == nil && active == nil)
        guard !same else { return }
        let before = active
        active = now
        guard let now else { return }
        onChange(Self.announcedName(now: now, before: before), now.on)
        onSettle(now.mode, now.on)
    }

    /// Off reads as the mode that just ended ("Work · Focus off"), not
    /// the empty set's generic "Focus".
    static func announcedName(now: (on: Bool, mode: String),
                              before: (on: Bool, mode: String)?) -> String {
        guard !now.on, let before, before.on else { return now.mode }
        return before.mode
    }

    /// The daemon's view of the same DB. Used only when our own read
    /// came back unreadable — the two feeds read one file, and a
    /// readable file outranks a relayed one.
    func noteDaemon(mode: String?, source: String?) {
        guard readFile() == nil else { return }
        let (on, name) = Self.daemonFocus(mode: mode, source: source)
        // The first relayed document is a baseline, like the file's
        // first read: it settles and says nothing.
        guard let before = active else {
            active = (on, name)
            onSettle(name, on)
            return
        }
        guard on != before.on || name != before.mode else { return }
        active = (on, name)
        onChange(Self.announcedName(now: (on, name), before: before), on)
        onSettle(name, on)
    }

    /// `state.focus` read as a Focus. It describes JR-Bar's whole quiet
    /// state: `mode` is `"off"` when nothing is quiet (never "normal"),
    /// and only `source: "focus"` is a macOS Focus — a quiet mode picked
    /// from the menu or quiet hours are not the Mac's Focus and never
    /// announce as one. The daemon does not name the Focus.
    static func daemonFocus(mode: String?, source: String?) -> (on: Bool, mode: String) {
        let mode = mode?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        let quiet = !mode.isEmpty && mode != "off" && mode != "normal"
        return (quiet && source?.lowercased() == "focus", "Focus")
    }

    /// `(mode name, focused)` — nil when the file is missing or
    /// unreadable, so a schema change can never announce a lie.
    static func read() -> (on: Bool, mode: String)? {
        let url = dbDirectory.appendingPathComponent("Assertions.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let store = root["data"] as? [String: Any],
              let records = store["storeAssertionRecords"] as? [[String: Any]]
        else { return nil }
        // A record carrying a mode identifier is a live assertion; the
        // empty array is focus off.
        guard let record = records.first,
              let details = record["assertionDetails"] as? [String: Any],
              let identifier = details["assertionDetailsModeIdentifier"] as? String
        else { return (false, "Focus") }
        return (true, modeName(for: identifier))
    }

    /// `com.apple.donotdisturb.mode.default` → "Do Not Disturb";
    /// `com.apple.focusmodes.work` → "Work". An identifier we do not
    /// know still announces — as "Focus", never nothing.
    static func modeName(for identifier: String) -> String {
        let known: [(String, String)] = [
            ("donotdisturb.mode.default", "Do Not Disturb"),
            ("sleep", "Sleep"),
            ("work", "Work"),
            ("personal", "Personal"),
            ("driving", "Driving"),
            ("gaming", "Gaming"),
            ("fitness", "Fitness"),
            ("mindfulness", "Mindfulness"),
            ("reading", "Reading"),
        ]
        let lower = identifier.lowercased()
        for (key, name) in known where lower.contains(key) { return name }
        if let mode = identifier.split(separator: ".").last {
            let name = mode.replacingOccurrences(of: "-", with: " ")
            if !name.isEmpty, name.lowercased() != "default" {
                return name.prefix(1).uppercased() + name.dropFirst()
            }
        }
        return "Focus"
    }
}

/// A device joined or left the Mac — IOBluetooth's own connect
/// notification, and a disconnect notification registered on each
/// device as it connects (the one IOBluetooth offers; there is no
/// global disconnect). The first couple of seconds' worth of connects
/// are not announced: registration replays the devices that are
/// already connected, and announcing a desk's worth of hardware at
/// launch is not an announcement — but their disconnects are still
/// registered, so a device that was there at launch still says goodbye.
@MainActor
final class BluetoothWatcher: NSObject {
    /// One device's arrival or departure.
    struct Change: Equatable, Sendable {
        var name: String
        /// The percent the device reported on connect, when it did.
        var battery: Int?
        var connected: Bool
        /// The Bluetooth major class says audio (headphones, speakers)
        /// — the ear's audio-route notice speaks for these.
        var isAudio: Bool
    }

    var onChange: (Change) -> Void = { _ in }

    /// The thread that owns registration and its delivery runloop —
    /// see `BluetoothNotificationThread` for why it exists.
    private var thread: BluetoothNotificationThread?
    /// IOBluetooth calls the selector on its own queue — nothing in
    /// the callback may touch actor state, so the arm window lives
    /// behind its own lock.
    private let armedLock = NSLock()
    nonisolated(unsafe) private var armedAt = Date.distantFuture
    /// Each connected device's disconnect registration, by address —
    /// held so the notification stays alive, dropped when it fires.
    /// Touched only on the notification thread, behind the lock anyway.
    nonisolated(unsafe) private var disconnects: [String: IOBluetoothUserNotification] = [:]
    /// Bluetooth's major device class for audio/video equipment.
    nonisolated static let audioMajorClass: UInt32 = 0x04

    func start() {
        armedLock.lock(); armedAt = Date().addingTimeInterval(3); armedLock.unlock()
        let thread = BluetoothNotificationThread()
        thread.name = "JRBar.bluetooth"
        thread.watcher = self
        thread.start()
        self.thread = thread
    }

    /// nonisolated: IOBluetooth invokes this off the main thread, and
    /// an actor-isolated selector asserted and took the app down.
    /// Everything crosses to main before touching the announce path.
    /// `device` must be optional: the framework can fire the
    /// notification with no peer object, and a nonnull Swift parameter
    /// dereferences the nil pointer during bridging — before any body
    /// code can guard it. It took the app down on a connect event.
    @objc nonisolated fileprivate func deviceConnected(_ note: IOBluetoothUserNotification,
                                                       device: IOBluetoothDevice?) {
        guard let device else { return }
        let name = device.name ?? device.addressString ?? "Bluetooth device"
        // BatteryPercent arrived by KVO — but on 27 responds(to:) alone
        // is no guard: the device forwards the selector while KVO still
        // finds no key, and value(forKey:)'s NSUnknownKeyException cannot
        // be caught in Swift — it took the app down on a connect event.
        // A real method returning an object is the only safe read:
        // class_getInstanceMethod finds none on a forwarding-only class,
        // and perform() never raises for the ones it does find.
        let batterySelector = NSSelectorFromString("batteryPercent")
        var battery: Int? = nil
        if let method = class_getInstanceMethod(type(of: device), batterySelector) {
            let returnType = method_copyReturnType(method)
            defer { free(returnType) }
            if String(cString: returnType).hasPrefix("@") {
                battery = (device.perform(batterySelector)?.takeUnretainedValue() as? NSNumber)
                    .map { $0.intValue }
                    .flatMap { (0...100).contains($0) ? $0 : nil }
            }
        }
        let isAudio = Self.isAudio(device)
        // The goodbye is registered for every device, replayed ones
        // included — IOBluetooth has no global disconnect to listen to.
        watchDisconnect(of: device)
        let at = Date()
        armedLock.lock(); let armed = armedAt; armedLock.unlock()
        guard at >= armed else { return }
        let change = Change(name: name, battery: battery, connected: true, isAudio: isAudio)
        Task { @MainActor [weak self] in
            self?.onChange(change)
        }
    }

    /// Register this device's own disconnect notification, once per
    /// address. Runs on the notification thread (the connect callback's
    /// runloop), so the disconnect delivers there too.
    nonisolated private func watchDisconnect(of device: IOBluetoothDevice) {
        guard let address = device.addressString else { return }
        armedLock.lock()
        let known = disconnects[address] != nil
        armedLock.unlock()
        guard !known,
              let note = device.register(forDisconnectNotification: self,
                                         selector: #selector(deviceDisconnected(_:device:)))
        else { return }
        armedLock.lock()
        disconnects[address] = note
        armedLock.unlock()
    }

    /// The device left. Both arguments optional for the same reason the
    /// connect callback's device is: a nil the framework hands over must
    /// not be dereferenced during bridging.
    @objc nonisolated fileprivate func deviceDisconnected(_ note: IOBluetoothUserNotification?,
                                                          device: IOBluetoothDevice?) {
        note?.unregister()
        guard let device else { return }
        if let address = device.addressString {
            armedLock.lock()
            disconnects[address] = nil
            armedLock.unlock()
        }
        let change = Change(name: device.name ?? device.addressString ?? "Bluetooth device",
                            battery: nil, connected: false, isAudio: Self.isAudio(device))
        Task { @MainActor [weak self] in
            self?.onChange(change)
        }
    }

    /// The major class read off the device's class-of-device — audio
    /// and video equipment is 0x04.
    nonisolated private static func isAudio(_ device: IOBluetoothDevice) -> Bool {
        UInt32(device.deviceClassMajor) == audioMajorClass
    }
}

/// Registration lives on a private thread because
/// `IOBluetoothDevice.register` synchronizes on the CoreBluetooth
/// coordinator's first-contact handshake — on a Mac whose Bluetooth
/// TCC answer is still pending, that semaphore can wait for minutes,
/// and on the main thread it froze launch before the run loop ever
/// spun. The thread owns the runloop the notifications deliver on
/// (they arrive on the registering thread's runloop), so a wedged
/// handshake only ever parks this worker — the announcements simply
/// stay quiet, never the app.
private final class BluetoothNotificationThread: Thread {
    /// Strong: the registration outlives the watcher only if the
    /// watcher can die first — it must not, or IOBluetooth calls a
    /// dead selector target.
    var watcher: BluetoothWatcher?
    /// Held for the thread's lifetime so the token outlives `main()`.
    private var registration: IOBluetoothUserNotification?

    override func main() {
        if let watcher {
            registration = IOBluetoothDevice.register(
                forConnectNotifications: watcher,
                selector: #selector(BluetoothWatcher.deviceConnected(_:device:)))
        }
        // The delivery runloop: IOBluetooth's source fires here. A run
        // loop with no sources returns from `run` instantly — before the
        // handshake attaches its ports, an idle loop would spin a core.
        // The keep-alive port is a permanent source, so `run` parks on
        // the mach port wait until a real notification (or never) wakes
        // it instead of re-arming on a timeout.
        let keepAlive = NSMachPort()
        RunLoop.current.add(keepAlive, forMode: .default)
        while !isCancelled {
            autoreleasepool {
                _ = RunLoop.current.run(mode: .default, before: .distantFuture)
            }
        }
    }
}

/// The Caps Lock state is a flag, not a key event — a flagsChanged
/// monitor sees every toggle. The flag read at start is the baseline;
/// only a flip announces, and repeats while held (some keyboards emit
/// several flagsChanged per press) collapse on the same state.
@MainActor
final class CapsLockWatcher {
    var onToggle: (_ on: Bool) -> Void = { _ in }

    private var monitors: [Any] = []
    private var active: Bool?

    func start() {
        active = NSEvent.modifierFlags.contains(.capsLock)
        let note: (NSEvent) -> Void = { [weak self] event in
            let on = event.modifierFlags.contains(.capsLock)
            Task { @MainActor [weak self] in
                guard let self, self.active != on else { return }
                self.active = on
                self.onToggle(on)
            }
        }
        // Global sees every other app's presses; a local pass covers
        // flagsChanged aimed at our own windows (settings, panels).
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: { note($0) }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { event in
            note(event)
            return event
        }) { monitors.append(local) }
    }
}

/// A screen arriving or leaving — `didChangeScreenParameters` also
/// fires on resolution and layout changes, so only a real count delta
/// announces. The baseline taken at start means a re-plugged dock at
/// launch says nothing.
@MainActor
final class DisplayWatcher {
    var onChange: (_ connected: Bool) -> Void = { _ in }

    private var observer: NSObjectProtocol?
    private var count: Int = 0

    func start() {
        count = NSScreen.screens.count
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = NSScreen.screens.count
                guard now != self.count else { return }
                let connected = now > self.count
                self.count = now
                self.onChange(connected)
            }
        }
    }
}

/// The felt edge a capsule deserves: the system's own Tink, quiet
/// enough that a volume key run does not turn into a woodblock solo.
@MainActor
enum NotchSounds {
    /// Its own copy of Tink: the shared named sound keeps its volume
    /// for everyone else, and a run of presses restarts the click
    /// instead of dropping it while the last one still rings.
    private static let tink: NSSound? = {
        let sound = NSSound(named: NSSound.Name("Tink"))?.copy() as? NSSound
        sound?.volume = 0.12
        return sound
    }()

    static func tick() {
        guard let sound = tink else { return }
        if sound.isPlaying { sound.stop() }
        sound.play()
    }
}
