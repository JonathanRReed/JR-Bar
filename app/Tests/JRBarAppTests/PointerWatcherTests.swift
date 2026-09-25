import AppKit
import Testing
import JRBarCore
@testable import JRBarApp

/// The one pointer watcher the Dock, the Screen Bar and the menu bar
/// reveal share: moves are paced to 20 Hz, a still pointer costs
/// nothing, and the surfaces read the pointer only when told. The clock,
/// the scheduler and the event source are all the test's; no suite here
/// listens to the real pointer or moves it.
@Suite("Pointer watcher")
@MainActor
struct PointerWatcherTests {
    /// A source the test fires by hand.
    final class FakeSource: PointerMoveSource, @unchecked Sendable {
        var accepts = true
        var starts = 0
        var stops = 0
        var moved: (@Sendable () -> Void)?
        func start(moved: @escaping @Sendable () -> Void) -> Bool {
            starts += 1
            guard accepts else { return false }
            self.moved = moved
            return true
        }
        func stop() { stops += 1; moved = nil }
        func move() { moved?() }
    }

    /// A manual clock and a queue of scheduled work, run by hand.
    final class Rig: @unchecked Sendable {
        var now: TimeInterval = 1_000
        var queue: [(at: TimeInterval, work: @Sendable () -> Void)] = []
        /// Run everything due by `now`, in order.
        @MainActor
        func runDue() {
            while let next = queue.enumerated().filter({ $0.element.at <= now })
                .min(by: { $0.element.at < $1.element.at }) {
                queue.remove(at: next.offset)
                next.element.work()
            }
        }
    }

    static func makeWatcher(_ source: FakeSource, _ rig: Rig) -> PointerWatcher {
        PointerWatcher(source: source, clock: { rig.now },
                       schedule: { delay, work in rig.queue.append((rig.now + delay, work)) })
    }

    @Test("the pacing sends the first move at once and later ones a beat apart")
    func pacer() {
        var pacer = PointerMovePacer(interval: 0.05)
        #expect(pacer.noteMove(at: 10) == 0)
        #expect(pacer.noteMove(at: 10.01) == nil, "a move while one is due joins it")
        pacer.delivered(at: 10)
        let delay = pacer.noteMove(at: 10.02)
        #expect(delay.map { abs($0 - 0.03) < 1e-9 } == true, "waits out the rest of the beat")
        pacer.delivered(at: 10.05)
        #expect(pacer.noteMove(at: 11) == 0, "after a quiet spell the move goes at once")
    }

    @Test("a second of 125 Hz moves reaches a subscriber at most 21 times")
    func pacesToTwentyHertz() {
        let source = FakeSource()
        let rig = Rig()
        let watcher = Self.makeWatcher(source, rig)
        var reads = 0
        let token = watcher.subscribe { reads += 1 }
        #expect(token != nil)
        for step in 0..<125 {
            rig.now = 1_000 + Double(step) * 0.008
            source.move()
            rig.runDue()
        }
        rig.now += 1
        rig.runDue()
        #expect(reads >= 19 && reads <= 21, "reads \(reads)")
    }

    @Test("a still pointer schedules nothing and delivers nothing")
    func stillCostsNothing() {
        let source = FakeSource()
        let rig = Rig()
        let watcher = Self.makeWatcher(source, rig)
        var reads = 0
        _ = watcher.subscribe { reads += 1 }
        rig.now += 60
        rig.runDue()
        #expect(rig.queue.isEmpty)
        #expect(reads == 0)
    }

    @Test("the first subscriber starts the source and the last one stops it")
    func sourceLifecycle() {
        let source = FakeSource()
        let rig = Rig()
        let watcher = Self.makeWatcher(source, rig)
        let a = watcher.subscribe {}
        let b = watcher.subscribe {}
        #expect(source.starts == 1)
        #expect(watcher.subscriberCount == 2)
        watcher.unsubscribe(a!)
        #expect(source.stops == 0)
        watcher.unsubscribe(b!)
        #expect(source.stops == 1)
        #expect(!watcher.listening)
    }

    @Test("a refused source says so, and is asked again only after a while")
    func refusedSource() {
        let source = FakeSource()
        source.accepts = false
        let rig = Rig()
        let watcher = Self.makeWatcher(source, rig)
        #expect(watcher.subscribe {} == nil)
        #expect(watcher.subscribe {} == nil)
        #expect(source.starts == 1, "not hammered")
        rig.now += PointerWatcher.retryAfter
        source.accepts = true
        #expect(watcher.subscribe {} != nil)
        #expect(source.starts == 2)
    }

    @Test("the shared watcher hears nothing in a test process")
    func sharedIsDeafInTests() {
        #expect(PointerWatcher.shared.subscribe {} == nil)
    }

    // MARK: The Screen Bar under the watcher

    @Test("the band subscribes instead of polling, and a still pointer arms no timer")
    func bandSubscribes() {
        let source = FakeSource()
        let rig = Rig()
        let watcher = Self.makeWatcher(source, rig)
        let band = ScreenBarInteraction(card: NotchCardPresenter(model: makeTestCardModel()),
                                        hitRects: { [] }, focus: { nil })
        band.pointerWatch = watcher
        band.installMonitor = { _, _, _ in NSObject() }
        band.removeMonitor = { _ in }
        band.start()
        #expect(band.isPolling, "the watch is armed")
        #expect(watcher.subscriberCount == 1)
        #expect(!band.pollArmed, "nothing engaged: no timer of its own")
        band.setParked(true)
        #expect(watcher.subscriberCount == 0, "parked lets go of the watch")
        #expect(!band.isPolling)
        band.setParked(false)
        #expect(watcher.subscriberCount == 1)
        band.stop()
        #expect(watcher.subscriberCount == 0)
        #expect(!band.isPolling)
    }

    @Test("where the watcher hears nothing, the band polls as before")
    func bandFallsBackToThePoll() {
        let source = FakeSource()
        source.accepts = false
        let band = ScreenBarInteraction(card: NotchCardPresenter(model: makeTestCardModel()),
                                        hitRects: { [] }, focus: { nil })
        band.pointerWatch = Self.makeWatcher(source, Rig())
        band.installMonitor = { _, _, _ in NSObject() }
        band.removeMonitor = { _ in }
        band.start()
        #expect(band.pollArmed)
        band.stop()
        #expect(!band.isPolling)
    }

    // MARK: The menu bar reveal under the watcher

    @Test("the reveal hears a move into the zone and answers it; a still pointer arms nothing")
    func revealFollowsMoves() {
        let source = FakeSource()
        let rig = Rig()
        let watcher = Self.makeWatcher(source, rig)
        let reveal = MenuBarReveal()
        var reveals = 0
        var point = NSPoint(x: 400, y: 400)
        reveal.pointerWatch = watcher
        reveal.settings = { MenuBarSettings(enabled: true, revealOnHover: true) }
        reveal.row = { NSRect(x: 0, y: 958, width: 1512, height: 27) }
        reveal.mouseLocation = { point }
        reveal.onReveal = { reveals += 1 }
        reveal.scheduleRehide = { _, _ in {} }
        reveal.hoverDwell = 0
        reveal.startHoverPoll()
        #expect(reveal.hoverPollArmed)
        #expect(!reveal.hoverTimerArmed, "a still pointer below the bar: no timer")
        #expect(reveals == 0)
        point = NSPoint(x: 400, y: 965)
        source.move()
        rig.runDue()
        #expect(reveals == 1, "the move into the zone is the gesture")
        #expect(!reveal.hoverTimerArmed, "no dwell left to read out")
        reveal.park(.locked)
        #expect(!reveal.hoverPollArmed)
        #expect(watcher.subscriberCount == 0)
        reveal.unpark(.locked)
        #expect(watcher.subscriberCount == 1)
        reveal.stop()
        #expect(watcher.subscriberCount == 0)
    }

    @Test("an entry's dwell is read out even when the pointer stops in the zone")
    func revealDwellKeepsReading() {
        let source = FakeSource()
        let rig = Rig()
        let reveal = MenuBarReveal()
        var point = NSPoint(x: 400, y: 400)
        reveal.pointerWatch = Self.makeWatcher(source, rig)
        reveal.settings = { MenuBarSettings(enabled: true, revealOnHover: true) }
        reveal.row = { NSRect(x: 0, y: 958, width: 1512, height: 27) }
        reveal.mouseLocation = { point }
        reveal.onReveal = {}
        reveal.scheduleRehide = { _, _ in {} }
        reveal.hoverDwell = 60
        reveal.startHoverPoll()
        point = NSPoint(x: 400, y: 965)
        source.move()
        rig.runDue()
        #expect(reveal.hoverTimerArmed, "the dwell is pending: the poll reads it out")
        reveal.stop()
        #expect(!reveal.hoverTimerArmed)
    }

    // MARK: The Dock tick's cadence

    @Test("under the watcher the Dock's tick keeps its beat only while a preview is at stake")
    func dockTickCadence() {
        #expect(DockEnhanceController.nextTickWait(watching: true, engaged: false, near: true) == nil,
                "a still pointer away from a preview: no tick until it moves")
        #expect(DockEnhanceController.nextTickWait(watching: true, engaged: true, near: false)
            == DockEnhanceController.pollInterval)
        #expect(DockEnhanceController.nextTickWait(watching: false, engaged: false, near: true)
            == DockEnhanceController.pollInterval, "polling, near: 20 Hz as before")
        #expect(DockEnhanceController.nextTickWait(watching: false, engaged: false, near: false)
            == DockEnhanceController.farPollInterval, "polling, far: 8 Hz as before")
    }
}
