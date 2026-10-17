import Foundation

/// How often the Accessibility listing re-scans. Each scan is a round of
/// calls into every app that owns a menu extra, so a bar that has sat still
/// for a while is looked at less often than one that is moving. The pace
/// counts scans in a row that found the same bar; a different bar, or
/// anything that can move one (`MenuBarItemLister.barActivity`), starts it
/// over at the quick pace.
struct MenuBarListingPace: Equatable, Sendable {
    /// The beat the listing loop wakes on; a scan lands on a beat.
    nonisolated static let beat: TimeInterval = 2
    /// Calm scans in a row before the pace slows to two beats.
    nonisolated static let steadyAfter = 10
    /// ... and to three.
    nonisolated static let settledAfter = 40

    private(set) var calmScans = 0

    /// Beats to let pass before the next scan: 1 while the bar moves
    /// (every two seconds, as it always was), 2 after ten calm scans, 3
    /// after forty.
    var beats: Int {
        if calmScans >= Self.settledAfter { return 3 }
        if calmScans >= Self.steadyAfter { return 2 }
        return 1
    }

    var interval: TimeInterval { Double(beats) * Self.beat }

    mutating func scanned(sameAsBefore: Bool) {
        calmScans = sameAsBefore ? min(calmScans + 1, Self.settledAfter) : 0
    }

    mutating func restart() {
        calmScans = 0
    }
}

/// The Accessibility listing's refresh loop, with its clock, its scan and its
/// view of the screen handed in so a test can run it without a screen or a
/// second of real time.
///
/// It wakes every `MenuBarListingPace.beat`. On a beat it scans when the bar
/// can be seen and Accessibility is granted, hands the result to `afterScan`
/// (the hider's reconcile), then lets the pace's number of beats go by before
/// the next scan. Anything that moved `activity` ends the wait at once and
/// puts the pace back to quick.
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
            var waited: TimeInterval = 0
            while waited < pace.interval, keepGoing() {
                await sleep(MenuBarListingPace.beat)
                waited += MenuBarListingPace.beat
                if seen != activity() { break }
            }
            if seen != activity() {
                seen = activity()
                pace.restart()
            }
        }
    }
}
