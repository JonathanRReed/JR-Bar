import AppKit
import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

@Suite("Menu Bar reflow freshness")
@MainActor
struct MenuBarReflowTests {
    @MainActor private final class Clock {
        var waiting: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            guard !Task.isCancelled else { return }
            await withCheckedContinuation { waiting.append($0) }
        }
        func release() {
            let pending = waiting
            waiting = []
            pending.forEach { $0.resume() }
        }
    }

    private func until(_ ready: () -> Bool) async {
        for _ in 0..<10_000 {
            if ready() { return }
            await Task.yield()
        }
        #expect(ready())
    }

    private func hider(clock: Clock) -> MenuBarItemHider {
        let hider = MenuBarItemHider()
        hider.shuttersSuppressed = true
        hider.edgeStore = MenuBarMemoryFitEdgeStore()
        hider.edgeKey = { "fixture" }
        hider.guessedFitEdge = { 900 }
        hider.spacerCeiling = { 300 }
        hider.rowRect = { CGRect(x: 0, y: 0, width: 1440, height: 24) }
        hider.barShowing = { true }
        hider.barIsVisible = { true }
        hider.listingIsScanned = { true }
        hider.listItems = { [] }
        hider.settleSleep = { _ in await clock.wait() }
        return hider
    }

    @Test("clearance recovers from a failed scan and a hidden menu bar", arguments: [true, false])
    func clearanceRecovery(initiallyVisible: Bool) async {
        let clock = Clock()
        let hider = self.hider(clock: clock)
        defer { hider.stop(); clock.release() }
        hider.controlFrames = { MenuBarControlFrames(hidden: CGRect(x: 1000, y: 0, width: 24, height: 24)) }
        var generation = 10
        var visible = initiallyVisible
        var reads = 0
        var plans = 0
        hider.listingGeneration = { generation }
        hider.barIsVisible = { visible }
        hider.refreshListingAfterReflow = { reads += 1; return reads > 1 }
        hider.onPlan = { _ in plans += 1 }
        hider.reveal([.hidden])
        await until { !clock.waiting.isEmpty }
        clock.release()
        await until { plans == 2 }
        #expect(!hider.hasFreshControlListing)
        for _ in 0..<20 { await Task.yield() }
        #expect(clock.waiting.isEmpty, "an unchanged generation must not spin on a failed refresh")
        visible = true
        for _ in 0..<3 {
            if hider.hasFreshControlListing { break }
            let before = plans
            generation += 1
            hider.reconcile()
            await until { !clock.waiting.isEmpty }
            clock.release()
            await until { plans >= before + 2 }
        }
        #expect(hider.hasFreshControlListing)
        #expect(reads == 2)
    }

    @Test("a scan completing after a write cannot release clearance until the post-write scan finishes")
    func clearanceRequiresPostWriteScan() async {
        let clock = Clock()
        let scan = Clock()
        let hider = self.hider(clock: clock)
        defer { hider.stop(); clock.release(); scan.release() }
        hider.controlFrames = { MenuBarControlFrames(hidden: CGRect(x: 1000, y: 0, width: 24, height: 24)) }
        var generation = 10
        hider.listingGeneration = { generation }
        hider.refreshListingAfterReflow = { await scan.wait(); return true }
        hider.reveal([.hidden])
        #expect(!hider.hasFreshControlListing)
        generation = 11
        hider.reconcile()
        #expect(!hider.hasFreshControlListing, "an older in-flight scan can advance the public generation")
        await until { !clock.waiting.isEmpty }
        clock.release()
        await until { !scan.waiting.isEmpty }
        #expect(!hider.hasFreshControlListing)
        scan.release()
        await until { hider.hasFreshControlListing }
    }

    @Test("a reflow refresh survives coalescing and plans only the fresh listing")
    func refreshSurvivesCoalescing() async {
        let clock = Clock()
        let hider = self.hider(clock: clock)
        defer { hider.stop(); clock.release() }
        var fresh = false
        var reads = 0
        var plans = 0
        hider.refreshListingAfterReflow = { reads += 1; fresh = true; return true }
        hider.onPlan = { _ in plans += 1; #expect(fresh) }
        hider.scheduleSettle(refreshListing: true)
        await until { clock.waiting.count == 1 }
        hider.scheduleSettle()
        await until { clock.waiting.count == 2 }
        clock.release()
        await until { plans == 1 }
        #expect(reads == 1)
    }

    @Test("ordinary settling and an invisible bar do not request full AX scans")
    func noUnnecessaryScans() async {
        for visible in [true, false] {
            let clock = Clock()
            let hider = self.hider(clock: clock)
            var reads = 0
            var plans = 0
            hider.barIsVisible = { visible }
            hider.refreshListingAfterReflow = { reads += 1; return true }
            hider.onPlan = { _ in plans += 1 }
            hider.scheduleSettle(refreshListing: !visible)
            await until { !clock.waiting.isEmpty }
            clock.release()
            await until { plans == 1 }
            #expect(reads == 0)
            hider.stop()
            clock.release()
        }
    }

    @Test("stopping cancels the settle armed by restoring the divider")
    func stopCannotRehideAfterRestore() async {
        let clock = Clock()
        let hider = self.hider(clock: clock)
        var reads = 0
        hider.refreshListingAfterReflow = { reads += 1; return true }
        var lengths: [CGFloat] = []
        hider.setControlLength = { _, length in lengths.append(length) }
        hider.scheduleSettle(refreshListing: true)
        await until { !clock.waiting.isEmpty }
        hider.stop()
        #expect(lengths.last == MenuBarControlFrames.glyphLength)
        clock.release()
        for _ in 0..<20 { await Task.yield() }
        #expect(reads == 0)
        #expect(clock.waiting.isEmpty)
    }
}
