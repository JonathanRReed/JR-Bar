import Foundation

/// A short recovery spell after activity or incomplete inventory, then one
/// safety scan every thirty seconds for apps that send no AX notifications.
struct MenuBarListingPace: Equatable, Sendable {
    nonisolated static let beat: TimeInterval = 2
    nonisolated static let steadyAfter = 2
    nonisolated static let settledAfter = 2
    private(set) var calmScans = 0
    var beats: Int { calmScans >= Self.settledAfter ? 15 : 1 }
    var interval: TimeInterval { Double(beats) * Self.beat }
    mutating func scanned(sameAsBefore: Bool) {
        calmScans = sameAsBefore ? min(calmScans + 1, Self.settledAfter) : 0
    }
    mutating func restart() { calmScans = 0 }
}

/// An activity notification ends the current wait. The timeout is a recovery
/// scan, not a polling beat. Tests supply their own scheduler.
@MainActor
final class MenuBarListingWait {
    private var continuation: CheckedContinuation<Void, Never>?
    private var timeout: DispatchWorkItem?
    var schedule: (TimeInterval, DispatchWorkItem) -> Void = { seconds, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
    var waiting: Bool { continuation != nil }

    func wait(_ seconds: TimeInterval) async {
        guard !Task.isCancelled else { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                let work = DispatchWorkItem { [weak self] in self?.signal() }
                timeout = work
                schedule(seconds, work)
            }
        } onCancel: {
            _ = Task { @MainActor [weak self] in self?.signal() }
        }
    }

    func signal() {
        timeout?.cancel()
        timeout = nil
        let pending = continuation
        continuation = nil
        pending?.resume()
    }
}

/// The Accessibility listing's refresh loop, with its clock, its scan and its
/// view of the screen handed in so a test can run it without a screen or a
/// second of real time.
///
/// Scans only while visible and trusted. Activity interrupts the injected
/// wait; after two calm scans its timeout stretches to thirty seconds.
@MainActor
struct MenuBarListingLoop {
    var visible: @MainActor () -> Bool
    var trusted: @MainActor () -> Bool
    var scan: @MainActor () async -> [MenuBarItem]
    var activity: @MainActor () -> UInt64
    var afterScan: @MainActor () -> Void
    var sleep: @MainActor (TimeInterval) async -> Void
    var complete: @MainActor () -> Bool = { true }
    var keepGoing: @MainActor () -> Bool = { !Task.isCancelled }

    func run() async {
        var pace = MenuBarListingPace()
        var previous: [MenuBarItem] = []
        var seen = activity()
        while keepGoing() {
            if visible(), trusted() {
                let items = await scan()
                guard keepGoing() else { return }
                guard visible(), trusted() else {
                    pace.restart()
                    continue
                }
                pace.scanned(sameAsBefore: complete() && MenuBarItemLister.sameListing(items, previous))
                previous = items
                afterScan()
            }
            if seen != activity() {
                seen = activity()
                pace.restart()
            }
            await sleep(pace.interval)
            if seen != activity() {
                seen = activity()
                pace.restart()
            }
        }
    }
}
