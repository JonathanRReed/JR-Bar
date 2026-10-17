import Foundation
import Testing
@testable import JRBarApp

/// The fold's single draw clock: the display-link driver that exists only
/// while something moves, the policy that says when that is, and the gate
/// that never silently drops a wanted frame. No screen, no GPU, no timer:
/// the link is a counter and the clock is the loop.
@Suite("Fold draw clock")
@MainActor
struct FoldDrawClockTests {
    final class FakeLink: FoldTickLink {
        var invalidated = false
        func invalidate() { invalidated = true }
    }

    /// A factory that counts the links it makes.
    @MainActor
    final class Links {
        private(set) var made: [FakeLink] = []
        var live: Int { made.filter { !$0.invalidated }.count }
        func make() -> FoldTickLink {
            let link = FakeLink()
            made.append(link)
            return link
        }
    }

    @Test("no link is made, kept or ticked while nothing is wanted")
    func idleMakesNoLink() {
        let links = Links()
        let driver = FoldTickDriver { _ in links.make() }
        for _ in 0..<1000 {
            #expect(driver.update(wanted: false) == .unchanged)
        }
        #expect(links.made.isEmpty)
        #expect(!driver.isRunning)
        #expect(!driver.stop())
    }

    @Test("a wanted tick makes one link, keeps it, and tears it down when it is not wanted")
    func lifecycle() {
        let links = Links()
        let driver = FoldTickDriver { _ in links.make() }
        #expect(driver.update(wanted: true) == .started)
        for _ in 0..<100 { #expect(driver.update(wanted: true) == .unchanged) }
        #expect(links.made.count == 1 && driver.isRunning)
        #expect(driver.update(wanted: false) == .stopped)
        #expect(links.made[0].invalidated && !driver.isRunning)
        #expect(driver.update(wanted: false) == .unchanged)
        #expect(driver.update(wanted: true) == .started)
        #expect(links.made.count == 2, "a new gesture is a new link")
        #expect(driver.stop())
        #expect(links.live == 0)
    }

    @Test("releasing the driver invalidates its active display link")
    func teardown() {
        let links = Links()
        var driver: FoldTickDriver? = FoldTickDriver { _ in links.make() }
        #expect(driver?.update(wanted: true) == .started)
        #expect(links.live == 1)
        driver = nil
        #expect(links.live == 0)
    }

    @Test("with no screen to tick on, nothing starts")
    func noScreen() {
        let driver = FoldTickDriver { _ in nil }
        #expect(driver.update(wanted: true) == .unchanged)
        #expect(!driver.isRunning)
    }

    @Test("a tick reaches the toy with the frame time the link gave it")
    func tickDelivery() {
        var captured: (@MainActor (TimeInterval) -> Void)?
        let driver = FoldTickDriver { onTick in
            captured = onTick
            return FakeLink()
        }
        var seen: [TimeInterval] = []
        driver.onTick = { seen.append($0) }
        _ = driver.update(wanted: true)
        captured?(10.5)
        captured?(10.508)
        #expect(seen == [10.5, 10.508])
    }

    @Test("the policy wants a tick only while something moves or shows")
    func policy() {
        func wants(armed: Bool = true, target: Double = 0, shown: Double = 0, motion: Bool = true,
                   ease: Bool = true, blackout: Bool = false, fading: Bool = false) -> Bool {
            FoldTickPolicy.wantsTick(armed: armed, targetDelta: target, displayedDelta: shown,
                                     motionAtRest: motion, easeAtRest: ease,
                                     blackout: blackout, entryFading: fading)
        }
        #expect(!wants(), "everything at rest: no clock")
        #expect(!wants(armed: false, target: 1, shown: 1, motion: false, blackout: true),
                "not armed: never")
        #expect(wants(target: 0.1))
        #expect(wants(shown: 0.1))
        #expect(!wants(shown: 0.001), "a hair of delta shows nothing")
        #expect(wants(motion: false))
        #expect(wants(ease: false))
        #expect(wants(blackout: true))
        #expect(wants(fading: true))
    }

    /// The toy's own loop on an injected clock: a recorded close and
    /// reopen through the real motion, the policy and the driver, then
    /// seconds of rest. Counts what ran.
    @Test("a close and reopen runs the link only while the lid moves, and ten seconds of rest run none")
    func restRunsNoLink() throws {
        let links = Links()
        let driver = FoldTickDriver { _ in links.make() }
        var motion = FoldMotion()
        var ease = FoldGateEase()
        var ticks = 0
        var ticksWhileResting = 0
        let reference = 110.0
        let dt = 1.0 / 120
        // The lid: rests at 110, closes to 70 at 40°/s, reopens to 110.
        func truth(_ t: Double) -> Double {
            let t0 = 1.0
            if t < t0 { return reference }
            let down = 40.0 / 40
            if t < t0 + down { return reference - 40 * (t - t0) }
            let hold = 0.3
            if t < t0 + down + hold { return 70 }
            return min(reference, 70 + 40 * (t - t0 - down - hold))
        }
        let movingUntil = 1.0 + 1.0 + 0.3 + 1.0
        var restStart: Double?
        var t = 0.0
        while t < 16 {
            // The sensor polls at 120 Hz while armed; a poll is a reconcile.
            motion.feed(FoldMotionTests.reading(truth, at: t), at: t)
            var shown = ease.value
            func reconcile() {
                let target = max(0, reference - (motion.angle ?? reference)) * .pi / 180
                let wanted = FoldTickPolicy.wantsTick(
                    armed: true, targetDelta: target > 0.002 ? target : 0, displayedDelta: shown,
                    motionAtRest: motion.atRest(at: t), easeAtRest: ease.atRest,
                    blackout: false, entryFading: false)
                _ = driver.update(wanted: wanted)
            }
            reconcile()
            if driver.isRunning {
                // The link's own tick: motion, ease, then the draw.
                ticks += 1
                motion.tick(at: t, dt: dt)
                let angle = motion.angle ?? reference
                shown = ease.tick(target: max(0, reference - angle) * .pi / 180, dt: dt)
                reconcile()
            }
            if t > movingUntil, restStart == nil, !driver.isRunning { restStart = t }
            if restStart != nil, driver.isRunning { ticksWhileResting += 1 }
            t += dt
        }
        let rest = try #require(restStart, "the link never stood down")
        #expect(rest < movingUntil + 2.5, "stood down \(rest - movingUntil) s after the lid stopped")
        #expect(ticksWhileResting == 0, "the link ran \(ticksWhileResting) ticks at rest")
        #expect(links.made.count == 1, "one gesture, one link (\(links.made.count))")
        #expect(links.live == 0)
        #expect(ticks > 200 && ticks < Int((movingUntil + 2.5) * 120), "ticked \(ticks) times")
        #expect(Double(ticks) / 120 < 16 / 3, "and under a third of the run")
    }

    // MARK: Draw gate

    @Test("two frames may be in flight; a third is owed, not dropped")
    func gateCoalesces() {
        var gate = FoldDrawGate()
        let first = gate.request()
        let second = gate.request()
        let third = gate.request()
        #expect(first && second)
        #expect(!third, "the GPU is full")
        #expect(gate.owed)
        // Asking again while full still owes just one frame.
        let fourth = gate.request()
        let fifth = gate.request()
        #expect(!fourth && !fifth)
        let handedBack = gate.finished()
        #expect(handedBack, "the first to land hands the owed frame back")
        #expect(!gate.owed)
        let room = gate.request()
        #expect(room, "and there is room for it")
        let nothingOwed = gate.finished()
        let drained = gate.finished()
        #expect(!nothingOwed && !drained, "nothing owed: nothing to redraw")
        #expect(gate.inFlight == 0)
        let stray = gate.finished()
        #expect(!stray)
        #expect(gate.inFlight == 0, "a stray finish cannot go negative")
    }

    @Test("an owed frame waits for room, not for the whole queue to drain")
    func gateOwedWaitsForRoom() {
        var gate = FoldDrawGate(limit: 1)
        let first = gate.request()
        let second = gate.request()
        #expect(first && !second)
        let handedBack = gate.finished()
        #expect(handedBack)
        let again = gate.request()
        #expect(again)
        #expect(gate.inFlight == 1)
    }
}
