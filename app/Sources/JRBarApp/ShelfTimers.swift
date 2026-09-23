import AppKit
import Foundation

/// W12's shelf timers: absolute-deadline countdowns persisted to disk,
/// so they span sleep, restart, and clock changes (T51). Expiry is
/// one-shot — a fired timer delivers exactly one notification and then
/// sits dismissed; recovery never launches an agent or fires twice.
///
/// Deadlines are wall-clock: a 5-minute timer set before sleep is due
/// 5 minutes of *real* time later. A clock change re-reads `now`, so
/// an adjusted clock can make a pending timer instantly overdue — it
/// fires once, marked, never again. A paused timer banks its remaining
/// time instead and gets a fresh absolute deadline when it resumes.
///
/// Two kinds are about the agents: a timer set to a quota window's
/// reset, and a nudge watching a session ("if it's still running in 20
/// minutes, tell me"). The nudge's watch is checked when it comes due
/// (`firePredicate`): a run that finished in the meantime owes no
/// interruption, and the timer retires quietly.
@MainActor
@Observable
final class ShelfTimerModel {
    struct Entry: Codable, Equatable, Identifiable {
        let id: String
        var label: String
        /// The absolute due instant — persisted so restarts recover it.
        var deadline: Date
        /// Set when the expiry notification was delivered — the
        /// one-shot marker that survives restart.
        var fired: Bool
        /// The seconds left when the timer was paused; nil while it
        /// runs. The deadline is meaningless until it resumes.
        var pausedRemaining: TimeInterval?
        /// A nudge's session: it only speaks if that session is still
        /// working when the timer comes due.
        var watchSession: String?

        init(id: String, label: String, deadline: Date, fired: Bool,
             pausedRemaining: TimeInterval? = nil, watchSession: String? = nil) {
            self.id = id
            self.label = label
            self.deadline = deadline
            self.fired = fired
            self.pausedRemaining = pausedRemaining
            self.watchSession = watchSession
        }

        var paused: Bool { pausedRemaining != nil }
        var remaining: TimeInterval { pausedRemaining ?? deadline.timeIntervalSinceNow }
        var overdue: Bool { !paused && remaining <= 0 }
    }

    /// The done chip's quick extensions, in seconds.
    static let extensions: [TimeInterval] = [60, 300]

    /// Longest settable timer — a shelf timer is minutes, not days.
    static let maxDuration: TimeInterval = 12 * 3600

    private(set) var entries: [Entry] = []
    /// Set by the app when notifications are wired; a fired timer calls
    /// it once. Without it the timer still marks itself — recovery of a
    /// long-dead timer shows "overdue" in the strip, not silence.
    var onFire: (@MainActor (Entry) -> Void)?
    /// The island's half of a firing — the timer capsule at the notch.
    /// A second listener beside `onFire`, so neither has to know the
    /// other.
    var onFireNotice: (@MainActor (Entry) -> Void)?
    /// Whether a due timer still has something to say — a nudge whose
    /// session is no longer working does not. nil (or true) speaks.
    /// A silenced timer still marks itself fired and leaves the strip.
    var firePredicate: (@MainActor (Entry) -> Bool)?

    private var tick: Timer?
    private var observers: [NSObjectProtocol] = []
    private let storeURL: URL

    /// `storeURL` is injectable so tests never touch the real file.
    init(storeURL: URL? = nil) {
        self.storeURL = storeURL ?? Self.defaultStoreURL()
        entries = Self.load(from: self.storeURL)
        // Recovery sweep: anything that came due while the app was down
        // fires exactly once now (T51's "one overdue notification").
        sweep()
        startTicking()
        observeClockAndWake()
    }

    // No deinit cleanup: the model lives for the app's run — the tick
    // is a main-runloop timer and the observers are app-lifetime too.
    // Isolated deinit would be nonisolated and can't touch them anyway.

    // MARK: - Mutations

    /// Adds a timer with an absolute deadline. Durations past
    /// `maxDuration` clamp rather than silently accepting a typo.
    @discardableResult
    func add(label: String, duration: TimeInterval, watchSession: String? = nil) -> Entry {
        let clamped = min(max(1, duration), Self.maxDuration)
        let entry = Entry(id: UUID().uuidString, label: label.isEmpty ? "Timer" : label,
                          deadline: Date().addingTimeInterval(clamped), fired: false,
                          watchSession: watchSession)
        entries.append(entry)
        sortEntries()
        persist()
        return entry
    }

    /// A timer due at an absolute instant — a quota window's reset. nil
    /// when the instant is already past or beyond `maxDuration`.
    @discardableResult
    func add(label: String, until instant: Date, now: Date = Date()) -> Entry? {
        let span = instant.timeIntervalSince(now)
        guard span >= 1, span <= Self.maxDuration else { return nil }
        return add(label: label, duration: span)
    }

    /// Removes a timer entirely — cancel and dismiss are the same act.
    func remove(_ entry: Entry) {
        entries.removeAll { $0.id == entry.id }
        persist()
    }

    /// Bank the time left; the chip reads "paused" and nothing fires.
    func pause(_ entry: Entry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }),
              !entries[index].fired, !entries[index].paused else { return }
        entries[index].pausedRemaining = max(1, entries[index].deadline.timeIntervalSinceNow)
        persist()
    }

    /// Carry on from where it was paused, on a fresh absolute deadline.
    func resume(_ entry: Entry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }),
              let left = entries[index].pausedRemaining else { return }
        entries[index].deadline = Date().addingTimeInterval(left)
        entries[index].pausedRemaining = nil
        sortEntries()
        persist()
    }

    /// "+1 min", "+5 min": a running timer gains the time; a done one
    /// runs again for it — snooze, one tap. Clamped to `maxDuration`
    /// from now.
    func extend(_ entry: Entry, by seconds: TimeInterval) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        let now = Date()
        if let left = entries[index].pausedRemaining {
            entries[index].pausedRemaining = min(Self.maxDuration, left + seconds)
        } else if entries[index].fired || entries[index].overdue {
            entries[index].deadline = now.addingTimeInterval(min(Self.maxDuration, seconds))
            entries[index].fired = false
        } else {
            let base = max(now, entries[index].deadline)
            entries[index].deadline = min(now.addingTimeInterval(Self.maxDuration),
                                          base.addingTimeInterval(seconds))
        }
        sortEntries()
        persist()
    }

    /// Soonest first; paused timers sort by what they have left.
    private func sortEntries() {
        entries.sort { $0.remaining < $1.remaining }
    }

    // MARK: - Tick and recovery

    /// The 1 s heartbeat; firing is edge-triggered on `fired` so a
    /// restart after the deadline delivers one notice, not a storm.
    private func startTicking() {
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sweep() }
        }
        timer.tolerance = 0.3
        RunLoop.main.add(timer, forMode: .common)
        tick = timer
    }

    /// Re-check every deadline — called by the tick, by wake, and by
    /// clock-change so sleep and wall-clock edits are handled the same.
    /// Internal so tests can run a sweep without the heartbeat.
    func sweep() {
        var changed = false
        var retired: [String] = []
        for index in entries.indices where !entries[index].fired && entries[index].overdue {
            entries[index].fired = true
            changed = true
            let entry = entries[index]
            // A nudge whose run already finished owes no interruption:
            // it retires without a word rather than sit "Done".
            guard firePredicate?(entry) ?? true else {
                retired.append(entry.id)
                continue
            }
            onFire?(entry)
            onFireNotice?(entry)
        }
        if !retired.isEmpty { entries.removeAll { retired.contains($0.id) } }
        if changed { persist() }
    }

    private func observeClockAndWake() {
        // Wake and clock-change both mean "re-read now" — the absolute
        // deadline is the truth, not elapsed ticks.
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSNotification.Name.NSSystemClockDidChange, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.sweep() } })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.sweep() } })
    }

    // MARK: - Persistence

    static func defaultStoreURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = support.appendingPathComponent("JR-Bar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("shelf-timers.json")
    }

    static func load(from url: URL) -> [Entry] {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([Entry].self, from: data)
        else { return [] }
        // Corrupt entries are dropped wholesale; a half-written file is
        // not a timer set.
        return decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}
