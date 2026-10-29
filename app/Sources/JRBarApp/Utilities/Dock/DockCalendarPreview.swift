import AppKit
@preconcurrency import EventKit

/// A visible Dock card borrows the shelf's cache. Hovering never asks for access.
@MainActor
final class DockCalendarPreview {
    enum State: Equatable {
        case loading
        case noAccess
        case events([ShelfCalendarModel.Event])
    }

    var authorization: () -> EKAuthorizationStatus = { EKEventStore.authorizationStatus(for: .event) }
    var clock: () -> Date = { Date() }
    var onChange: (State) -> Void = { _ in }
    var scheduleRefreshOverride: (() -> Void)?
    let reader: ShelfCalendarReader
    let queue = DispatchQueue(label: "jrbar.dock-calendar", qos: .userInitiated)
    private(set) var running = false
    private var work: DispatchWorkItem?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var generation = 0
    private var dirty = false

    init(reader: ShelfCalendarReader = .shared) { self.reader = reader }

    func start() {
        stop()
        running = true
        onChange(authorization() == .fullAccess ? .loading : .noAccess)
        observers.append(reader.notifications.addObserver(
            forName: ShelfCalendarReader.didChange, object: reader, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.storeChanged() }
        })
        observers.append(reader.notifications.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reader.invalidate()
                self?.storeChanged()
            }
        })
        refresh()
    }

    func stop() {
        running = false
        generation += 1
        work?.cancel()
        work = nil
        timer?.invalidate()
        timer = nil
        for observer in observers {
            reader.notifications.removeObserver(observer)
        }
        observers.removeAll()
        dirty = false
    }

    func storeChanged() {
        guard running else { return }
        if work != nil { dirty = true } else { refresh() }
    }

    /// Tests advance time and call this directly, without a run-loop timer.
    func refresh() {
        guard running else { return }
        guard authorization() == .fullAccess else {
            onChange(.noAccess)
            scheduleRefresh()
            return
        }
        guard work == nil else { return }
        let generation = self.generation
        let reader = self.reader
        let now = clock()
        let next = DispatchWorkItem { @Sendable [weak self] in
            let events = reader.events(from: now)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.running, self.generation == generation else { return }
                    self.work = nil
                    self.onChange(self.authorization() == .fullAccess ? .events(events) : .noAccess)
                    if self.dirty {
                        self.dirty = false
                        self.refresh()
                    } else {
                        self.scheduleRefresh()
                    }
                }
            }
        }
        work = next
        queue.async(execute: next)
    }

    private func scheduleRefresh() {
        timer?.invalidate()
        timer = nil
        guard running else { return }
        if let scheduleRefreshOverride { scheduleRefreshOverride(); return }
        let timer = Timer(timeInterval: 60, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}
