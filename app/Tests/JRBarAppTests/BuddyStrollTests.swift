import CoreGraphics
import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// The floating buddy's walkabout: up onto the frontmost window's top
/// edge (or the screen bottom), a short stroll, a turn on the spot, part
/// of the way back, and home — only its own panel moves, and never by
/// more than a step a frame outside a hop.
@Suite("Buddy stroll")
struct BuddyStrollTests {
    private let visible = CGRect(x: 0, y: 80, width: 1440, height: 790)   // menu bar & Dock off
    private let size = CGSize(width: 40, height: 34)
    private let home = CGPoint(x: 1300, y: 700)

    @Test("it strolls on the frontmost window with room above it")
    func frontmostLedge() throws {
        let maximized = CGRect(x: 0, y: 80, width: 1440, height: 790)
        let editor = CGRect(x: 200, y: 200, width: 900, height: 500)
        let behind = CGRect(x: 100, y: 100, width: 600, height: 400)
        let plan = try #require(BuddyStroll.plan(home: home, size: size, visible: visible,
                                                 windows: [maximized, editor, behind],
                                                 rightward: false))
        #expect(plan.ledge == editor, "a maximized window leaves no room on top")
        #expect(plan.legs.count == 5, "hop up, out, turn, back, hop home")
        #expect(plan.legs[0].from == home)
        #expect(plan.legs.last?.to == home)
        let walk = plan.legs[1]
        #expect(!walk.hop)
        #expect(walk.from.y == editor.maxY + size.height / 2 - 1, "feet on the edge")
        #expect(walk.from.x <= editor.maxX - size.width / 2 - 6, "starts on the edge")
        #expect(walk.to.x < walk.from.x, "leftward, as asked")
        #expect(abs(walk.to.x - walk.from.x) <= BuddyStroll.maxStroll)
        #expect(walk.to.x >= editor.minX + size.width / 2 + 6)
    }

    @Test("no window with room: the bottom of the screen")
    func bottomFallback() throws {
        let narrow = CGRect(x: 500, y: 300, width: 90, height: 200)
        let corner = CGPoint(x: 1405, y: 700)
        let plan = try #require(BuddyStroll.plan(home: corner, size: size, visible: visible,
                                                 windows: [narrow], rightward: true))
        #expect(plan.ledge == nil)
        #expect(plan.legs[1].from.y == visible.minY + size.height / 2 + 1)
        // Parked against the right edge, "rightward" has no room: it turns.
        #expect(plan.legs[1].to.x < plan.legs[1].from.x)
    }

    @Test("the path starts and ends at home, and faces the way it walks")
    func walking() throws {
        let plan = try #require(BuddyStroll.plan(home: home, size: size, visible: visible,
                                                 windows: [], rightward: false))
        #expect(plan.point(at: 0) == home)
        #expect(plan.point(at: plan.duration + 0.01) == nil, "home, done")
        let hopEnd = plan.legs[0].duration
        #expect(plan.heading(at: hopEnd / 2) == nil, "the hop keeps its own pose")
        #expect(plan.heading(at: hopEnd + 0.1) == -1)
        // Round on the spot at the far end, then back the other way.
        let outEnd = hopEnd + plan.legs[1].duration
        #expect(plan.heading(at: outEnd + 0.01) == 1, "the turn faces the way back while it stands")
        #expect(plan.point(at: outEnd + 0.01) == plan.point(at: outEnd + BuddyStroll.turnPause - 0.01))
        #expect(plan.heading(at: outEnd + BuddyStroll.turnPause + 0.1) == 1)
        let back = plan.legs[3]
        #expect(back.to.x > back.from.x)
        #expect(abs(abs(back.to.x - back.from.x) - abs(plan.legs[1].to.x - plan.legs[1].from.x)
                    * BuddyStroll.backShare) < 1e-9)
        #expect(plan.heading(at: plan.duration - 0.05) == nil, "the hop home keeps its own pose")
        let mid = try #require(plan.point(at: hopEnd + plan.legs[1].duration / 2))
        #expect(abs(mid.y - plan.legs[1].from.y) < 0.001, "along the edge, level")
        let homeward = BuddyStroll.homeward(from: CGPoint(x: 10, y: 10), home: home)
        #expect(homeward.legs.count == 1 && homeward.point(at: homeward.duration + 1) == nil)
    }

    @Test("the edge stands while its window does")
    func ledgeStands() {
        let editor = CGRect(x: 200, y: 200, width: 900, height: 500)
        #expect(BuddyStroll.ledgeStands(nil, in: []))
        #expect(BuddyStroll.ledgeStands(editor, in: [editor.offsetBy(dx: 2, dy: -1)]))
        #expect(!BuddyStroll.ledgeStands(editor, in: [editor.offsetBy(dx: 0, dy: 40)]))
        #expect(!BuddyStroll.ledgeStands(editor, in: []))
    }

    @Test("only a working, unbothered buddy strolls, and not too often")
    func when() {
        func go(working: Int = 1, waiting: Int = 0, failed: Int = 0, dragging: Bool = false,
                reduceMotion: Bool = false, since: TimeInterval = 3600, roll: Double = 0.1) -> Bool {
            BuddyStroll.shouldStroll(working: working, waiting: waiting, failed: failed,
                                     dragging: dragging, reduceMotion: reduceMotion,
                                     sinceLast: since, roll: roll)
        }
        #expect(go())
        #expect(!go(working: 0), "asleep, it stays put")
        #expect(!go(waiting: 1), "an ask keeps it home")
        #expect(!go(failed: 1))
        #expect(!go(dragging: true))
        #expect(!go(reduceMotion: true))
        #expect(!go(since: 60), "not twice in a row")
        #expect(!go(roll: 0.9), "and only now and then")
    }

    @Test("a walk under way heads home once walks are off, an ask opens or its edge goes")
    func walkCarriesOn() {
        var looked = 0
        func keepsOn(working: Int = 1, waiting: Int = 0, failed: Int = 0, showing: Bool = true,
                     free: Bool = true, takesWalks: Bool = true, ledge: Bool = true) -> Bool {
            BuddyStroll.carriesOn(working: working, waiting: waiting, failed: failed,
                                  showing: showing, free: free, takesWalks: takesWalks,
                                  ledgeStands: { () -> Bool in looked += 1; return ledge }())
        }
        #expect(keepsOn())
        #expect(!keepsOn(takesWalks: false), "Take walks turned off mid-walk")
        #expect(!keepsOn(waiting: 1))
        #expect(!keepsOn(failed: 1))
        #expect(!keepsOn(working: 0))
        #expect(!keepsOn(showing: false))
        #expect(!keepsOn(free: false))
        #expect(!keepsOn(ledge: false))
        #expect(looked == 2, "the window list is read only when everything else holds")
    }

    @Test("the walk dial sets the cadence, and twelve minutes is the old one")
    func cadence() {
        #expect(BuddyStroll.minGap(every: 12) == 8 * 60)
        #expect(BuddyStroll.chance(every: 12) == 0.25)
        #expect(BuddyStroll.minGap(every: 3) == 2 * 60)
        #expect(BuddyStroll.chance(every: 3) == 1)
        #expect(BuddyStroll.minGap(every: 1) == BuddyStroll.minGap(every: 3), "the dial clamps")
        #expect(BuddyStroll.chance(every: .nan) == 0.25, "a broken value is the default")
        func go(every: Double, since: TimeInterval, roll: Double) -> Bool {
            BuddyStroll.shouldStroll(working: 1, waiting: 0, failed: 0, dragging: false,
                                     reduceMotion: false, sinceLast: since, roll: roll, every: every)
        }
        #expect(go(every: 5, since: 210, roll: 0.5), "often: soon, and more likely")
        #expect(!go(every: 12, since: 210, roll: 0.1), "the default still waits eight minutes")
        #expect(!go(every: 40, since: 30 * 60, roll: 0.1), "rarely: a long quiet stretch")
        #expect(go(every: 40, since: 40 * 60, roll: 0.05))
    }

    @Test("across a leg change the pet moves a step a frame, never a jump")
    func noPopAcrossLegs() throws {
        let plan = try #require(BuddyStroll.plan(home: home, size: size, visible: visible,
                                                 windows: [], rightward: false))
        let walk = BuddyWalk(plan: plan, began: 0)
        let dt = 1.0 / 30.0
        let bound = BuddyStroll.strollSpeed * dt + 2
        // From the first step on the edge to the last one before the hop
        // home: out, the turn on the spot, and back.
        let from = plan.legs[0].duration
        let until = from + plan.legs[1].duration + plan.legs[2].duration + plan.legs[3].duration
        var last: CGPoint?
        var t = from
        var frames = 0
        while t < until {
            let centre = try #require(walk.centre(at: t))
            let origin = BuddyWalk.origin(for: centre, size: size)
            if let last { #expect(hypot(origin.x - last.x, origin.y - last.y) <= bound, "jumped at \(t)s") }
            last = origin
            frames += 1
            t += dt
        }
        #expect(frames > 100)
    }

    @Test("a ledge that goes mid-walk sends it home from where it stands, without a jump")
    func noPopOnReplan() throws {
        let editor = CGRect(x: 200, y: 200, width: 900, height: 500)
        let plan = try #require(BuddyStroll.plan(home: home, size: size, visible: visible,
                                                 windows: [editor], rightward: false))
        var walk = BuddyWalk(plan: plan, began: 0)
        let dt = 1.0 / 30.0
        let bound = BuddyStroll.strollSpeed * dt + 2
        let gone = plan.legs[0].duration + plan.legs[1].duration * 0.4
        var last: CGPoint?
        var t = gone - 0.2
        var replanned = false
        // The hop home is a deliberate hop and picks up speed; the frames
        // either side of the change are the ones that must not jump.
        while t < gone + 0.1 {
            if !replanned, t >= gone {
                // The panel re-plans from the frame it drew.
                let drawn = try #require(last)
                walk.headHome(from: CGPoint(x: drawn.x + size.width / 2, y: drawn.y + size.height / 2),
                              home: home, at: t)
                replanned = true
            }
            let centre = try #require(walk.centre(at: t))
            let origin = BuddyWalk.origin(for: centre, size: size)
            if let last { #expect(hypot(origin.x - last.x, origin.y - last.y) <= bound, "jumped at \(t)s") }
            last = origin
            t += dt
        }
        #expect(replanned)
        #expect(walk.plan.legs.count == 1 && walk.plan.legs[0].to == home)
    }

    @Test("a press holds it still, and the release picks up where it stopped")
    func holdAndRelease() throws {
        let plan = try #require(BuddyStroll.plan(home: home, size: size, visible: visible,
                                                 windows: [], rightward: false))
        var walk = BuddyWalk(plan: plan, began: 100)
        let pressed = 100 + plan.legs[0].duration + 1
        let before = try #require(walk.centre(at: pressed))
        walk.hold(at: pressed)
        #expect(walk.centre(at: pressed + 3) == before, "stands under the pointer")
        walk.hold(at: pressed + 3)
        walk.release(at: pressed + 3)
        #expect(walk.centre(at: pressed + 3) == before, "no jump on the release")
        #expect(walk.heading(at: pressed + 3) == -1)
        let later = try #require(walk.centre(at: pressed + 4))
        #expect(abs(abs(later.x - before.x) - BuddyStroll.strollSpeed) < 1e-6)
    }

    @Test("the setting defaults on and reads tolerantly")
    func setting() throws {
        #expect(NotchBuddySettings().walkabout)
        let off = try JSONDecoder().decode(NotchBuddySettings.self,
                                           from: Data(#"{"walkabout": false}"#.utf8))
        #expect(!off.walkabout)
        let junk = try JSONDecoder().decode(NotchBuddySettings.self,
                                            from: Data(#"{"walkabout": "sometimes"}"#.utf8))
        #expect(junk.walkabout)
    }
}
