import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import JRBarApp

/// The Accessibility listing's pace: a bar that sits still is asked about
/// less often, a bar nobody can see is not asked at all, and anything that
/// can move the bar brings the quick pace back. The loop runs on a clock
/// the test turns by hand, one beat per sleep.
@Suite("Menu Bar — the listing loop's pace")
struct MenuBarListingLoopTests {
    private func item(_ id: String, x: CGFloat, width: CGFloat = 30, pid: pid_t = 100) -> MenuBarItem {
        MenuBarItem(id: id, ownerPID: pid, ownerName: id, bounds: CGRect(x: x, y: 0, width: width, height: 24),
                    title: nil, windowID: 0)
    }

    /// What the loop's closures share with the test.
    @MainActor
    final class Room {
        var visible = true
        var trusted = true
        var complete = true
        var activity: UInt64 = 0
        var items: [MenuBarItem] = []
        var scans: [Int] = []
        var reconciles = 0
        var beats = 0
        var limit = 0
        /// Run at the end of each beat, with the beat's number.
        var onBeat: (Int) -> Void = { _ in }
    }

    @MainActor
    private func run(_ room: Room, beats: Int) async {
        room.limit = beats
        let loop = MenuBarListingLoop(
            visible: { room.visible },
            trusted: { room.trusted },
            scan: {
                room.scans.append(room.beats)
                return room.items
            },
            activity: { room.activity },
            afterScan: { room.reconciles += 1 },
            sleep: { seconds in
                room.beats += Int(seconds / MenuBarListingPace.beat)
                room.onBeat(room.beats)
            },
            complete: { room.complete },
            keepGoing: { room.beats < room.limit })
        await loop.run()
    }

    @Test("two calm scans switch recovery polling to thirty seconds")
    func paceLadder() {
        var pace = MenuBarListingPace()
        #expect(pace.interval == 2)
        pace.scanned(sameAsBefore: true)
        #expect(pace.interval == 2)
        pace.scanned(sameAsBefore: true)
        #expect(pace.interval == 30)
        for _ in 0..<100 { pace.scanned(sameAsBefore: true) }
        #expect(pace.interval == 30)
        pace.restart()
        #expect(pace.interval == 2)
        pace.scanned(sameAsBefore: false)
        #expect(pace.interval == 2)
    }

    @MainActor
    @Test("identical incomplete scans keep the two-second retry pace")
    func incompleteScansDoNotBecomeCalm() async {
        let failed = Room()
        failed.items = [item("fixture", x: 900)]
        failed.complete = false
        await run(failed, beats: 60)
        #expect(failed.scans == Array(0..<60))
        let recovered = Room()
        recovered.items = failed.items
        await run(recovered, beats: 60)
        #expect(recovered.scans.count < failed.scans.count)
    }

    @Test("two scans of the same bar differ by nothing the eye can see: a point or two of the clock's width is not news")
    func sameListing() {
        let a = [item("clock", x: 1200, width: 80), item("wifi", x: 1150)]
        let nudged = [item("clock", x: 1198.5, width: 81.5), item("wifi", x: 1148.5)]
        #expect(MenuBarItemLister.sameListing(a, nudged))
        #expect(MenuBarItemLister.sameListing([], []))
        #expect(!MenuBarItemLister.sameListing(a, [item("clock", x: 1200, width: 80)]), "an item left")
        #expect(!MenuBarItemLister.sameListing(a, [item("clock", x: 1200, width: 80), item("battery", x: 1150)]),
                "a different item in the same place")
        #expect(!MenuBarItemLister.sameListing(a, [item("clock", x: 1200, width: 80), item("wifi", x: 1130)]),
                "an item moved twenty points")
        #expect(!MenuBarItemLister.sameListing(a, [item("clock", x: 1200, width: 80), item("wifi", x: 1150, pid: 101)]),
                "another app now owns it")
    }

    @MainActor
    @Test("a calm bar needs two scans a minute after recovery")
    func stillBarIsScannedLess() async {
        let room = Room()
        room.items = [item("clock", x: 1200), item("wifi", x: 1150)]

        await run(room, beats: 300)

        // 300 beats of two seconds is ten minutes. Always-quick would
        // scan on every beat.
        #expect(room.scans.count == 22)
        #expect(room.reconciles == room.scans.count, "every scan is reconciled")
        #expect(Array(room.scans.prefix(3)) == [0, 1, 2], "the first scans use the recovery pace")
        let gaps = zip(room.scans.dropFirst(), room.scans).map { $0 - $1 }
        #expect(gaps.last == 15, "settled at thirty seconds")
    }

    @MainActor
    @Test("a bar that keeps changing stays on the quick pace")
    func movingBarStaysQuick() async {
        let room = Room()
        room.items = [item("clock", x: 1200)]
        room.onBeat = { beat in room.items = [self.item("meter", x: CGFloat(1000 + beat * 20))] }

        await run(room, beats: 100)

        #expect(room.scans.count == 100)
    }

    @MainActor
    @Test("a launch, a reveal or a screen change ends the long wait and the quick pace returns")
    func activityBringsTheQuickPaceBack() async {
        let room = Room()
        room.items = [item("clock", x: 1200)]
        room.onBeat = { beat in
            if beat >= 200, room.activity == 0 { room.activity += 1 }
        }

        await run(room, beats: 215)

        let after = room.scans.filter { $0 >= 200 }
        #expect(after.first == 212, "the scan restarts recovery after timeout activity")
        #expect(after == [212, 213], "two recovery scans run before the calm wait")
    }

    @MainActor
    @Test("nothing is scanned while the displays sleep or the screen is locked, and scanning resumes on the wake")
    func parkedBarIsNotScanned() async {
        let room = Room()
        room.items = [item("clock", x: 1200)]
        room.visible = false

        await run(room, beats: 600)
        #expect(room.scans.isEmpty && room.reconciles == 0, "twenty minutes asleep, no Accessibility calls")

        room.visible = true
        room.activity += 1
        await run(room, beats: 610)
        #expect(room.scans.first == 600, "the first scan comes on the first beat after the wake")
    }

    @MainActor
    @Test("without the Accessibility grant nothing is scanned")
    func untrustedIsNotScanned() async {
        let room = Room()
        room.trusted = false

        await run(room, beats: 100)

        #expect(room.scans.isEmpty)
    }

    @MainActor
    @Test("stopping during a scan does not reconcile its late answer")
    func stoppedScanDoesNotReconcile() async {
        var running = true
        var reconciles = 0
        let loop = MenuBarListingLoop(
            visible: { true }, trusted: { true },
            scan: { running = false; return [] },
            activity: { 0 }, afterScan: { reconciles += 1 },
            sleep: { _ in }, keepGoing: { running })
        await loop.run()
        #expect(reconciles == 0)
    }

    @MainActor
    @Test("a display that sleeps during a scan does not reconcile its late answer")
    func sleepingScanDoesNotReconcile() async {
        var visible = true
        var running = true
        var reconciles = 0
        let loop = MenuBarListingLoop(
            visible: { visible }, trusted: { true },
            scan: { visible = false; return [] },
            activity: { 0 }, afterScan: { reconciles += 1 },
            sleep: { _ in running = false }, keepGoing: { running })
        await loop.run()
        #expect(reconciles == 0)
    }

    @MainActor
    @Test("activity interrupts a calm wait and retires its timeout")
    func eventInterruptsWait() async {
        let wait = MenuBarListingWait()
        var scheduled: DispatchWorkItem?
        var delay: TimeInterval?
        wait.schedule = { seconds, work in
            delay = seconds
            scheduled = work
            wait.signal()
        }
        await wait.wait(30)
        #expect(delay == 30)
        #expect(scheduled?.isCancelled == true)
        #expect(!wait.waiting)
    }

    @MainActor
    @Test("display notification bursts schedule one remeasurement")
    func displayChangesDebounce() {
        let hider = MenuBarItemHider()
        var work: [DispatchWorkItem] = []
        hider.scheduleDisplayChange = { _, item in work.append(item) }
        for _ in 0..<48 { hider.displaysChanged() }
        #expect(work.count == 48)
        let retired = work.dropLast().allSatisfy { $0.isCancelled }
        #expect(retired)
        #expect(work.last?.isCancelled == false)
        hider.stop()
        #expect(work.last?.isCancelled == true)
    }

    @Test("the workspace notices that park the bar are the four that carry a presence fact")
    func presenceNotices() {
        #expect(MenuBarItemHider.presenceEvent(for: NSWorkspace.screensDidSleepNotification) == .displaysSlept)
        #expect(MenuBarItemHider.presenceEvent(for: NSWorkspace.screensDidWakeNotification) == .displaysWoke)
        #expect(MenuBarItemHider.presenceEvent(for: NSWorkspace.sessionDidResignActiveNotification) == .sessionLeft)
        #expect(MenuBarItemHider.presenceEvent(for: NSWorkspace.sessionDidBecomeActiveNotification) == .sessionReturned)
        #expect(MenuBarItemHider.presenceEvent(for: NSWorkspace.willSleepNotification) == nil)
        #expect(MenuBarItemHider.presenceEvent(for: NSWorkspace.didWakeNotification) == nil)
    }

    @MainActor
    @Test("the 1 Hz pass stands down while nobody can see the bar")
    func timerPassStandsDown() {
        let hider = MenuBarItemHider()
        var plans = 0
        hider.onPlan = { _ in plans += 1 }
        hider.rowRect = { CGRect(x: 0, y: 0, width: 1440, height: 24) }
        hider.listItems = { [] }
        hider.listingIsScanned = { false }
        hider.barIsVisible = { false }

        hider.timerTick()
        #expect(plans == 0)

        hider.barIsVisible = { true }
        hider.timerTick()
        #expect(plans == 1)
    }
}
