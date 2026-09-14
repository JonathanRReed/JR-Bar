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
/// fires once, marked, never again.
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

        var remaining: TimeInterval { deadline.timeIntervalSinceNow }
        var overdue: Bool { remaining <= 0 }
    }

    /// Longest settable timer — a shelf timer is minutes, not days.
    static let maxDuration: TimeInterval = 12 * 3600

    private(set) var entries: [Entry] = []
    /// Set by the app when notifications are wired; a fired timer calls
    /// it once. Without it the timer still marks itself — recovery of a
    /// long-dead timer shows "overdue" in the strip, not silence.
    var onFire: (@MainActor (Entry) -> Void)?

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
    func add(label: String, duration: TimeInterval) -> Entry {
        let clamped = min(max(1, duration), Self.maxDuration)
        let entry = Entry(id: UUID().uuidString, label: label.isEmpty ? "Timer" : label,
                          deadline: Date().addingTimeInterval(clamped), fired: false)
        entries.append(entry)
        entries.sort { $0.deadline < $1.deadline }
        persist()
        return entry
    }

    /// Removes a timer entirely — cancel and dismiss are the same act.
    func remove(_ entry: Entry) {
        entries.removeAll { $0.id == entry.id }
        persist()
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
    private func sweep() {
        var changed = false
        for index in entries.indices where !entries[index].fired && entries[index].overdue {
            entries[index].fired = true
            changed = true
            onFire?(entries[index])
        }
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
