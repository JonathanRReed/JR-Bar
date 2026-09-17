import AppKit
import IOBluetooth
import OSLog

/// The system announcements Alcove surfaces in the island: a Focus
/// mode turning on or off, a Bluetooth device connecting. Each watcher
/// is quiet until something actually changes — no polling, no
/// entitlement asks.
@MainActor
final class NotchAnnouncements {
    static let log = Logger(subsystem: "devin.jrbar", category: "announce")

    /// The notch settings' vote — consulted per announcement so a
    /// mid-flight change never strands a watcher.
    var isAllowed: () -> Bool = { true }
    /// What to do with one — the HUD's toast.
    var announce: (_ text: String, _ symbol: String) -> Void = { _, _ in }

    private let focus = FocusWatcher()
    private let bluetooth = BluetoothWatcher()
    private let capsLock = CapsLockWatcher()
    private let displays = DisplayWatcher()
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        focus.onChange = { [weak self] name, on in
            guard let self, self.isAllowed() else { return }
            self.announce(name, Self.focusSymbol(for: name))
        }
        bluetooth.onConnect = { [weak self] name, battery in
            guard let self, self.isAllowed() else { return }
            let suffix = battery.map { " — \($0)%" } ?? ""
            self.announce("\(name) connected\(suffix)", "headphones")
        }
        capsLock.onToggle = { [weak self] on in
            guard let self, self.isAllowed() else { return }
            self.announce(on ? "Caps Lock on" : "Caps Lock off", "capslock.fill")
        }
        displays.onChange = { [weak self] connected in
            guard let self, self.isAllowed() else { return }
            self.announce(connected ? "Display connected" : "Display disconnected",
                          connected ? "display" : "display.trianglebadge.exclamationmark")
        }
        focus.start()
        bluetooth.start()
        capsLock.start()
        displays.start()
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
    var onChange: (_ mode: String, _ on: Bool) -> Void = { _, _ in }

    private var source: DispatchSourceFileSystemObject?
    private var debounce: DispatchWorkItem?
    /// The baseline read at start — never announces, only diffs.
    private var active: (on: Bool, mode: String)?

    private static var dbDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/DoNotDisturb/DB", isDirectory: true)
    }

    func start() {
        active = Self.read()
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
        let now = Self.read()
        let same = (now?.on == active?.on && now?.mode == active?.mode)
            || (now == nil && active == nil)
        guard !same else { return }
        active = now
        guard let now else { return }
        onChange(now.mode, now.on)
    }

    /// The daemon's view of the same DB. Used only when our own read
    /// came back unreadable — the two feeds read one file, and a
    /// readable file outranks a relayed one.
    func noteDaemon(mode: String?, source: String?) {
        guard Self.read() == nil else { return }
        let on = (mode ?? "normal").lowercased() != "normal"
        let name = on ? (source.map { Self.modeName(for: $0) } ?? "Focus") : "Focus"
        let same = (on == active?.on && name == active?.mode)
        guard !same else { return }
        active = (on, name)
        onChange(name, on)
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

/// A device joined the Mac — IOBluetooth's own connect notification.
/// The first couple of seconds' worth are ignored: registration
/// replays the devices that are already connected, and announcing a
/// desk's worth of hardware at launch is not an announcement.
@MainActor
final class BluetoothWatcher: NSObject {
    /// The device's name plus a battery percent when it reports one.
    var onConnect: (_ name: String, _ batteryPercent: Int?) -> Void = { _, _ in }

    /// The thread that owns registration and its delivery runloop —
    /// see `BluetoothNotificationThread` for why it exists.
    private var thread: BluetoothNotificationThread?
    /// IOBluetooth calls the selector on its own queue — nothing in
    /// the callback may touch actor state, so the arm window lives
    /// behind its own lock.
    private let armedLock = NSLock()
    nonisolated(unsafe) private var armedAt = Date.distantFuture

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
    @objc nonisolated fileprivate func deviceConnected(_ note: IOBluetoothUserNotification,
                                                       device: IOBluetoothDevice) {
        let name = device.name ?? device.addressString ?? "Bluetooth device"
        // BatteryPercent arrives by KVO — value(forKey:) raises
        // NSUnknownKeyException on devices that never report one (docks,
        // most speakers), so the responds(to:) guard gates the read.
        // Best-effort: a number rides the announcement when the device
        // offers it, nothing is promised when it does not.
        let batterySelector = NSSelectorFromString("batteryPercent")
        let battery = device.responds(to: batterySelector)
            ? (device.value(forKey: "batteryPercent") as? NSNumber)
                .map { $0.intValue }
                .flatMap { (0...100).contains($0) ? $0 : nil }
            : nil
        let at = Date()
        armedLock.lock(); let armed = armedAt; armedLock.unlock()
        guard at >= armed else { return }
        Task { @MainActor [weak self] in
            self?.onConnect(name, battery)
        }
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
enum NotchSounds {
    static func tick() {
        guard let sound = NSSound(named: NSSound.Name("Tink")) else { return }
        sound.volume = 0.12
        sound.play()
    }
}
