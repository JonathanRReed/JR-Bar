import CoreGraphics
import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// The floating buddy's walkabout: up onto the frontmost window's top
/// edge (or the screen bottom), a short stroll, and home — only its own
/// panel moves.
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
        #expect(plan.legs.count == 3)
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
        let mid = try #require(plan.point(at: hopEnd + plan.legs[1].duration / 2))
        #expect(abs(mid.y - plan.legs[1].from.y) < 0.001, "along the edge, level")
        let back = BuddyStroll.homeward(from: CGPoint(x: 10, y: 10), home: home)
        #expect(back.legs.count == 1 && back.point(at: back.duration + 1) == nil)
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
