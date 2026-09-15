import AppKit
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
    /// rule id → the day stamp it last fired on (timeOfDay dedupe).
    private(set) var lastTimeFired: [String: String] = [:]

    /// The actions one event earns, in rule order. `dayStamp` is any
    /// string that changes once a day — the source passes a yyyy-MM-dd;
    /// a test passes "day-1"/"day-2".
    mutating func actions(for event: MenuBarTriggerEvent,
                          rules: [MenuBarTriggerRule],
                          dayStamp: String = "") -> [MenuBarTriggerAction] {
        var fired: [MenuBarTriggerAction] = []
        // The power edge is computed before rule matching so the
        // sample updates state even with no rules at all.
        var acEdge: Bool?
        if case .onACPower(let onAC) = event {
            acEdge = lastOnAC == onAC || lastOnAC == nil ? nil : onAC
            lastOnAC = onAC
        }
        for rule in rules where rule.enabled {
            guard matches(rule.trigger, event: event, acEdge: acEdge,
                          ruleID: rule.id, dayStamp: dayStamp) else { continue }
            fired.append(rule.action)
        }
        return fired
    }

    private mutating func matches(_ trigger: MenuBarTrigger,
                                  event: MenuBarTriggerEvent,
                                  acEdge: Bool?,
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
        }
    }

    /// The day stamp the engine's timeOfDay dedupe expects.
    nonisolated static func dayStamp(for date: Date = Date()) -> String {
        let comps = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d",
                      comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
    }
}
