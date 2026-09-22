import AppKit
import CoreAudio
import CoreWLAN
import Intents
import IOKit.ps
import JRBarCore

/// The persisted halves of this file's vocabulary — `MenuBarTrigger`,
/// `MenuBarTriggerAction`, `MenuBarTriggerRule` — live in
/// `JRBarCore/MenuBarActionsModel.swift` so `MenuBarSettings` can carry
/// them; what remains here is everything that cannot be persisted:
/// the event enum, the evaluation engine, and the system feed.

/// What an event source reports. Levels, not edges, where the system
/// only tells us state — the engine owns the edge detection so every
/// source can stay dumb and every transition is testable.
enum MenuBarTriggerEvent: Equatable, Sendable {
    case screenLocked
    case screenUnlocked
    /// The frontmost app changed; the payload is its bundle id.
    case appActivated(bundleID: String)
    /// The clock ticked; the payload is the wall-clock hour/minute.
    /// Sources may send repeats — the engine dedupes per rule per day.
    case minute(hour: Int, minute: Int)
    /// A power-source sample: true = on AC (charger in). A *sample*,
    /// not an event — send the current state whenever it is read; the
    /// engine turns it into connect/disconnect edges.
    case onACPower(Bool)
    /// A charge-level sample — the same baseline-and-edge contract as
    /// `onACPower`, on the internal battery's percent.
    case batteryPercent(Int)
    /// The system's "the network changed" — CoreWLAN's ssid-did-change
    /// note. Fires whether or not the name is readable, so the unnamed
    /// `wifiJoined("")` rule works without Location Services.
    case wifiChanged
    /// The readable SSID right now (nil = none or unreadable). A
    /// sample like `onACPower` — the engine edges it.
    case wifiSSID(String?)
    /// Default-input-running sample — the mic is live somewhere.
    case micInUse(Bool)
    /// Focus-mode sample — true while any Focus is on.
    case focusOn(Bool)
}

/// The evaluation engine. A mutable struct on purpose: the edge
/// detectors are a few bytes of state (last AC sample, per-rule day
/// dedupe) that belong to the evaluation, not to a long-lived object.
/// Everything is a function of `rules` + the event + that state, so a
/// test drives the whole thing with made-up events.
struct MenuBarTriggerEngine: Sendable {
    /// The last AC sample — nil until the first one, and the first one
    /// is a baseline: a rule never fires for a state the machine was
    /// already in when the source started.
    private(set) var lastOnAC: Bool?
    /// The last charge sample — the same baseline rule as AC.
    private(set) var lastBatteryPercent: Int?
    /// The last readable SSID sample — same baseline rule as AC.
    private(set) var lastSSID: String?
    /// The first sample must not read as a join/leave edge.
    private(set) var ssidSeen = false
    private(set) var lastMic: Bool?
    private(set) var lastFocus: Bool?
    /// rule id → the day stamp it last fired on (timeOfDay dedupe).
    private(set) var lastTimeFired: [String: String] = [:]

    /// The actions one event earns, in rule order. `dayStamp` is any
    /// string that changes once a day — the source passes a yyyy-MM-dd;
    /// a test passes "day-1"/"day-2".
    mutating func actions(for event: MenuBarTriggerEvent,
                          rules: [MenuBarTriggerRule],
                          dayStamp: String = "") -> [MenuBarTriggerAction] {
        var fired: [MenuBarTriggerAction] = []
        // The level edges are computed before rule matching so each
        // sample updates state even with no rules at all.
        var acEdge: Bool?
        if case .onACPower(let onAC) = event {
            acEdge = lastOnAC == onAC || lastOnAC == nil ? nil : onAC
            lastOnAC = onAC
        }
        // The percent edge is (previous, current) — a rule decides
        // which direction of crossing it answers.
        var percentEdge: (from: Int, to: Int)?
        if case .batteryPercent(let percent) = event {
            if let last = lastBatteryPercent, last != percent {
                percentEdge = (last, percent)
            }
            lastBatteryPercent = percent
        }
        var ssidEdge: (from: String?, to: String?)?
        if case .wifiSSID(let ssid) = event {
            if ssidSeen, ssid != lastSSID { ssidEdge = (lastSSID, ssid) }
            lastSSID = ssid
            ssidSeen = true
        }
        var micEdge: Bool?
        if case .micInUse(let live) = event {
            micEdge = lastMic == live || lastMic == nil ? nil : live
            lastMic = live
        }
        var focusEdge: Bool?
        if case .focusOn(let on) = event {
            focusEdge = lastFocus == on || lastFocus == nil ? nil : on
            lastFocus = on
        }
        for rule in rules where rule.enabled {
            guard matches(rule.trigger, event: event, acEdge: acEdge,
                          percentEdge: percentEdge,
                          ssidEdge: ssidEdge, micEdge: micEdge, focusEdge: focusEdge,
                          ruleID: rule.id, dayStamp: dayStamp) else { continue }
            fired.append(rule.action)
        }
        return fired
    }

    private mutating func matches(_ trigger: MenuBarTrigger,
                                  event: MenuBarTriggerEvent,
                                  acEdge: Bool?,
                                  percentEdge: (from: Int, to: Int)?,
                                  ssidEdge: (from: String?, to: String?)?,
                                  micEdge: Bool?,
                                  focusEdge: Bool?,
                                  ruleID: String,
                                  dayStamp: String) -> Bool {
        switch (trigger, event) {
        case (.screenLocked, .screenLocked),
             (.screenUnlocked, .screenUnlocked):
            return true
        case (.appActivated(let wanted), .appActivated(let bundleID)):
            return wanted.localizedCaseInsensitiveCompare(bundleID) == .orderedSame
        case (.timeOfDay(let h, let m), .minute(let hour, let minute)):
            guard h == hour, m == minute else { return false }
            guard lastTimeFired[ruleID] != dayStamp else { return false }
            lastTimeFired[ruleID] = dayStamp
            return true
        case (.chargerConnected, .onACPower):
            return acEdge == true
        case (.chargerDisconnected, .onACPower):
            return acEdge == false
        case (.batteryBelow(let p), .batteryPercent):
            // Crossed the threshold downward: last read above it,
            // this one at or under it.
            guard let edge = percentEdge else { return false }
            return edge.from > p && edge.to <= p
        case (.batteryAbove(let p), .batteryPercent):
            guard let edge = percentEdge else { return false }
            return edge.from < p && edge.to >= p
        case (.wifiJoined(let wanted), .wifiChanged):
            // The unnamed flavour — a network changed, name or no name.
            return wanted.isEmpty
        case (.wifiJoined(let wanted), .wifiSSID):
            guard let to = ssidEdge?.to, !wanted.isEmpty else { return false }
            return to.localizedCaseInsensitiveCompare(wanted) == .orderedSame
        case (.wifiLeft, .wifiSSID):
            return ssidEdge?.to == nil && ssidEdge?.from != nil
        case (.microphoneInUse, .micInUse):
            return micEdge == true
        case (.microphoneIdle, .micInUse):
            return micEdge == false
        case (.focusEnabled, .focusOn):
            return focusEdge == true
        case (.focusDisabled, .focusOn):
            return focusEdge == false
        default:
            return false
        }
    }
}

/// Where events come from. The maintainer feeds the engine one
/// implementation — `MenuBarSystemTriggerSource` below is the real
/// one; a test feeds `MenuBarTriggerEvent`s straight into
/// `engine.actions(for:rules:)` and never touches a source.
@MainActor
protocol MenuBarTriggerSource: AnyObject {
    /// Every event the source produces lands here.
    var onEvent: (@MainActor (MenuBarTriggerEvent) -> Void)? { get set }
    func start()
    func stop()
}

/// The real feed, three system surfaces behind one protocol:
///   * lock/unlock — `DistributedNotificationCenter`'s
///     `com.apple.screenIsLocked`/`…Unlocked`;
///   * app activation — `NSWorkspace.didActivateApplicationNotification`;
///   * clock + charger — one 15 s timer that emits a `.minute` tick
///     whenever the wall-clock minute changes and samples
///     `IOPSCopyPowerSourcesInfo` for the internal battery's
///     `Power Source State` (the same read `AlcovePowerMonitor` does).
/// The timer is the only always-on cost, and it exists only between
/// `start` and `stop` — the maintainer should run it only while at
/// least one rule is enabled.
@MainActor
final class MenuBarSystemTriggerSource: MenuBarTriggerSource {
    var onEvent: (@MainActor (MenuBarTriggerEvent) -> Void)?

    private var observers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private var timer: Timer?
    /// The CoreWLAN client + delegate pair, kept for the run of the
    /// source — the delegate is weak on the client, so both live here.
    private var wifiClient: CWWiFiClient?
    private var wifiDelegate: WiFiEventDelegate?
    /// The last minute a tick was emitted for — a 15 s poll can see
    /// the same minute twice and must not double-tick.
    private var lastMinuteKey: Int = -1

    /// The poll cadence for clock + power. 15 s lands inside every
    /// minute window with margin and costs one IOKit read per pass.
    nonisolated static let pollInterval: TimeInterval = 15

    func start() {
        guard timer == nil else { return }
        let distributed = DistributedNotificationCenter.default()
        for (name, event) in [
            ("com.apple.screenIsLocked", MenuBarTriggerEvent.screenLocked),
            ("com.apple.screenIsUnlocked", MenuBarTriggerEvent.screenUnlocked),
        ] {
            distributedObservers.append(distributed.addObserver(
                forName: NSNotification.Name(name), object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.onEvent?(event) }
            })
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication,
                  let bundleID = app.bundleIdentifier else { return }
            MainActor.assumeIsolated { self?.onEvent?(.appActivated(bundleID: bundleID)) }
        })
        // CoreWLAN's change event fires whether or not Location
        // Services lets us read the name — the unnamed Wi-Fi rule
        // rides it. The event surfaces through a client delegate, not
        // NotificationCenter.
        let client = CWWiFiClient()
        let delegate = makeWiFiDelegate()
        client.delegate = delegate
        wifiClient = client
        wifiDelegate = delegate
        try? client.startMonitoringEvent(with: .ssidDidChange)
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        poll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        lastMinuteKey = -1
        if let wifiClient { try? wifiClient.stopMonitoringEvent(with: .ssidDidChange) }
        wifiClient?.delegate = nil
        wifiClient = nil
        wifiDelegate = nil
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers = []
        for observer in distributedObservers {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        distributedObservers = []
    }

    isolated deinit { stop() }

    /// The SSID-change forwarder. CoreWLAN calls it on its own private
    /// thread, so it hops to the main actor — asserting isolation there
    /// trapped on the first network change once any rule was on.
    func makeWiFiDelegate() -> WiFiEventDelegate {
        WiFiEventDelegate { [weak self] in
            Task { @MainActor [weak self] in
                self?.onEvent?(.wifiChanged)
                self?.onEvent?(.wifiSSID(MenuBarSystemTriggerSource.currentSSID()))
            }
        }
    }

    /// One poll: a `.minute` tick when the wall-clock minute rolled,
    /// plus a `.onACPower` sample (only on machines with an internal
    /// battery — a Mac without one has no charger events to give).
    private func poll() {
        let now = Date()
        let comps = Calendar.current.dateComponents([.hour, .minute], from: now)
        if let hour = comps.hour, let minute = comps.minute {
            let key = hour * 60 + minute
            if key != lastMinuteKey {
                lastMinuteKey = key
                onEvent?(.minute(hour: hour, minute: minute))
            }
        }
        let power = AlcovePowerMonitor.read()
        if power.hasBattery {
            onEvent?(.onACPower(power.onAC))
            if let percent = power.percent {
                onEvent?(.batteryPercent(percent))
            }
        }
        onEvent?(.wifiSSID(Self.currentSSID()))
        onEvent?(.micInUse(Self.microphoneInUse()))
        // Focus is read only once granted — a bare poll must never be
        // the thing that raises the consent prompt.
        if INFocusStatusCenter.default.authorizationStatus == .authorized {
            onEvent?(.focusOn(INFocusStatusCenter.default.focusStatus.isFocused ?? false))
        }
    }

    /// The network name, when Location Services lets CoreWLAN say it —
    /// nil covers "no network" and "not allowed to know" alike.
    nonisolated static func currentSSID() -> String? {
        CWWiFiClient.shared().interface()?.ssid()
    }

    /// Whether anything holds the default input running — a CoreAudio
    /// read, no mic permission needed (running-state isn't capture).
    nonisolated static func microphoneInUse() -> Bool {
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        ) == noErr, deviceID != kAudioObjectUnknown else { return false }
        var running: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &running) == noErr
        else { return false }
        return running != 0
    }

    /// The card's ask for the Focus grant — only ever called from the
    /// "add rule" path, so the prompt lands on an explicit user action.
    static func requestFocusAuthorization(then: @escaping @MainActor (Bool) -> Void) {
        INFocusStatusCenter.default.requestAuthorization { status in
            Task { @MainActor in
                then(status == .authorized)
            }
        }
    }

    /// The day stamp the engine's timeOfDay dedupe expects.
    nonisolated static func dayStamp(for date: Date = Date()) -> String {
        let comps = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d",
                      comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
    }
}

/// CoreWLAN events arrive on a client delegate, not NotificationCenter
/// — one tiny forwarder per source. `ssidDidChange` fires with or
/// without the Location grant; only reading the name needs it. The
/// callback runs on CoreWLAN's thread, never the main one.
final class WiFiEventDelegate: NSObject, CWEventDelegate, Sendable {
    let onChange: @Sendable () -> Void
    init(onChange: @escaping @Sendable () -> Void) { self.onChange = onChange }
    func ssidDidChangeForWiFiInterface(withName interfaceName: String) { onChange() }
}
