import AppKit
import QuartzCore
import Testing
@testable import JRBarApp
@testable import JRBarLEDS

/// A keyframe plan costs main-thread time to put on the layers, and the
/// band's width follows the notch island. These pin that a plan is not
/// re-installed while the band is still changing size or the island is in
/// use, and that the frame clock is left to paint in the meantime. Time
/// is cranked by hand: no run loop timer is waited on.
@Suite("Screen Bar install hold")
@MainActor
struct ScreenBarInstallHoldTests {
    /// A view with a hand-cranked clock and a queue of delayed looks.
    @MainActor
    final class Bench {
        let view: ScreenBarView
        var now: CFTimeInterval = 1_000
        var held = false
        var renders = 0
        private var looks: [(at: CFTimeInterval, work: @MainActor () -> Void)] = []

        init(width: CGFloat = 220) {
            view = ScreenBarView(frame: CGRect(x: 0, y: 0, width: width, height: 24))
            view.relayout()
            view.mediaNow = { [unowned self] in self.now }
            view.installsHeld = { [unowned self] in self.held }
            view.afterDelay = { [unowned self] delay, work in self.looks.append((self.now + delay, work)) }
            view.gradientRenderer = { [weak self] plan, width, reduced in
                await MainActor.run { self?.renders += 1 }
                return ScreenBarGradientFrames.build(plan: plan, width: width, reduced: reduced)
            }
        }

        /// Move the clock on and run every look that came due, in order.
        func advance(_ seconds: TimeInterval) async {
            now += seconds
            while let index = looks.indices.filter({ looks[$0].at <= now }).min(by: { looks[$0].at < looks[$1].at }) {
                let look = looks.remove(at: index)
                look.work()
            }
            await view.waitForKeyframes()
        }

        func resize(to width: CGFloat) {
            view.frame = CGRect(x: 0, y: 0, width: width, height: 24)
            view.relayout()
        }

        var waitingLooks: Int { looks.count }
    }

    private func plan(_ text: String = "#10121F 250ms linear\n#000000 250ms linear\nrepeat") throws -> LEDSKeyframePlan {
        let sampler = LEDSSampler(program: try LEDSProgram.parse(text, ledCount: 8))
        return try #require(LEDSKeyframePlan.render(sampler: sampler))
    }

    @Test("the wait is nothing at rest, the rest of the settle after a resize, and a short second look while the island is in use")
    func waitTable() {
        typealias View = ScreenBarView
        #expect(View.installWait(sinceResize: .infinity, settle: 0.4, held: false, heldFor: 0) == nil)
        #expect(View.installWait(sinceResize: 0.4, settle: 0.4, held: false, heldFor: 0) == nil)
        let part = View.installWait(sinceResize: 0.1, settle: 0.4, held: false, heldFor: 0)
        #expect(part.map { abs($0 - 0.3) < 1e-9 } == true)
        #expect(View.installWait(sinceResize: .infinity, settle: 0.4, held: true, heldFor: 0) == View.holdRecheck)
        #expect(View.installWait(sinceResize: .infinity, settle: 0.4, held: true, heldFor: 59) == View.holdRecheck)
        // An island left open for a minute stops holding the band on its clock.
        #expect(View.installWait(sinceResize: .infinity, settle: 0.4, held: true, heldFor: 60) == nil)
        #expect(View.installWait(sinceResize: 0.1, settle: 0.4, held: true, heldFor: 60) != nil,
                "but a band still changing size waits out its settle all the same")
    }

    @Test("a first plan installs at once, exactly as before")
    func firstPlayInstallsAtOnce() async throws {
        let bench = Bench()
        bench.view.play(plan: try plan(), anchor: bench.now)
        #expect(!bench.view.installWaiting)
        await bench.view.waitForKeyframes()
        #expect(bench.view.keyframesInstalled)
        #expect(bench.renders == 1)
        #expect(bench.waitingLooks == 0)
    }

    @Test("a band changing size installs nothing until it has held still for the settle, however many steps the move took")
    func resizeWaitsForTheSettle() async throws {
        let bench = Bench()
        let program = try plan()
        bench.view.play(plan: program, anchor: bench.now)
        await bench.view.waitForKeyframes()
        #expect(bench.renders == 1)
        // The island opens: thirty steps of a morph, each a new width.
        for step in 1...30 {
            bench.resize(to: 220 + CGFloat(step) * 8)
            bench.view.play(plan: program, anchor: 1_000)
            await bench.advance(1.0 / 120)
            #expect(!bench.view.keyframesInstalled, "step \(step) put a plan on the layers")
            #expect(bench.view.isPlayingKeyframes && bench.view.installWaiting)
        }
        #expect(bench.renders == 1, "nothing was rendered for a width the band only passed through")
        await bench.advance(0.2)
        #expect(!bench.view.keyframesInstalled, "the settle has not run out")
        await bench.advance(0.25)
        #expect(bench.view.keyframesInstalled)
        #expect(bench.renders == 2, "one render and one install, for the width the band came to rest at")
        #expect(!bench.view.installWaiting)
    }

    @Test("while the island is hovered, open or moving, no plan goes on, even a new program's; it goes on once the island is let go")
    func heldByTheIsland() async throws {
        let bench = Bench()
        bench.view.play(plan: try plan(), anchor: bench.now)
        await bench.view.waitForKeyframes()
        bench.held = true
        // The light program changes while the card is open.
        let next = try plan("#FF0B00 400ms linear\n#2C0300 400ms linear\nrepeat")
        bench.view.play(plan: next, anchor: bench.now)
        #expect(bench.view.installWaiting && !bench.view.keyframesInstalled)
        for _ in 0..<20 {
            await bench.advance(0.5)
            #expect(!bench.view.keyframesInstalled)
        }
        #expect(bench.renders == 1)
        #expect(bench.waitingLooks == 1, "one look is pending at a time")
        bench.held = false
        await bench.advance(0.5)
        #expect(bench.view.keyframesInstalled)
        #expect(bench.renders == 2)
    }

    @Test("an island left open for a minute stops holding the band on its frame clock")
    func longestHold() async throws {
        let bench = Bench()
        bench.held = true
        bench.view.play(plan: try plan(), anchor: bench.now)
        await bench.advance(59)
        #expect(!bench.view.keyframesInstalled)
        await bench.advance(1.5)
        #expect(bench.view.keyframesInstalled)
    }

    @Test("stopping while a plan waits drops it: the late look installs nothing")
    func stopDropsAWaitingInstall() async throws {
        let bench = Bench()
        bench.held = true
        bench.view.play(plan: try plan(), anchor: bench.now)
        #expect(bench.view.installWaiting)
        bench.view.stopKeyframes()
        #expect(!bench.view.installWaiting)
        bench.held = false
        await bench.advance(5)
        #expect(!bench.view.isPlayingKeyframes && !bench.view.keyframesInstalled)
        #expect(bench.renders == 0)
    }
}
