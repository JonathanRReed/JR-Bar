import Foundation
import Testing
@testable import JRBarCore

/// `BuddyFocus` is the buddy's "what is it doing" pick — one session,
/// in the mood's own precedence — and `BuddyPlacement` is the drag's
/// arithmetic. Both are pure, so the whole decision surface is pinned
/// here rather than at the panels.
@Suite("Buddy presence")
struct BuddyPresenceTests {
    private func session(_ id: String, provider: String = "claude", label: String? = nil,
                         shortId: String? = nil, mode: String? = nil, lifecycle: String? = nil,
                         ask: CoreAsk? = nil, updatedAt: Double? = nil) -> CoreSession {
        CoreSession(id: id, provider: provider, label: label, shortId: shortId,
                    mode: mode, lifecycle: lifecycle, updatedAt: updatedAt, ask: ask)
    }

    @Test("nothing on the clock means nobody to watch")
    func emptyIsNil() {
        #expect(BuddyFocus.pick(from: []) == nil)
        #expect(BuddyFocus.pick(from: [
            session("s-1", mode: "idle"),
            session("s-2", lifecycle: "ended"),
        ]) == nil)
    }

    @Test("an open ask outranks everything and reads as waiting on you")
    func askWins() {
        let focus = BuddyFocus.pick(from: [
            session("s-work", provider: "codex", label: "Codex churn", mode: "working", updatedAt: 100),
            session("s-ask", provider: "claude", label: "Claude rename-the-fish",
                    ask: CoreAsk(session: "s-ask", openedAt: 50), updatedAt: 90),
            session("s-fail", lifecycle: "failed", updatedAt: 200),
        ])
        #expect(focus?.id == "s-ask")
        #expect(focus?.phrase == .waiting)
        #expect(focus?.line == "Claude · rename-the-fish — waiting on you")
    }

    @Test("among asks the longest-waiting is picked; an unopened ask lands last")
    func longestWaitingAsk() {
        let focus = BuddyFocus.pick(from: [
            session("s-new", provider: "codex", label: "newer", ask: CoreAsk(session: "s-new", openedAt: 90)),
            session("s-old", label: "older", ask: CoreAsk(session: "s-old", openedAt: 10)),
            session("s-never", label: "never", ask: CoreAsk(session: "s-never")),
        ])
        #expect(focus?.id == "s-old")
    }

    @Test("a failure outranks work; the freshest of a class wins")
    func failedBeatsWorking() {
        let focus = BuddyFocus.pick(from: [
            session("s-work", mode: "working", updatedAt: 500),
            session("s-old-fail", provider: "codex", label: "Codex oops", lifecycle: "failed", updatedAt: 60),
            session("s-new-fail", label: "the real oops", lifecycle: "failed", updatedAt: 300),
        ])
        #expect(focus?.id == "s-new-fail")
        #expect(focus?.line == "Claude · the real oops — failed")
    }

    @Test("with only work on the clock the most recently touched run is named")
    func mostRecentWorking() {
        let focus = BuddyFocus.pick(from: [
            session("s-stale", provider: "codex", label: "old work", mode: "working", updatedAt: 10),
            session("s-fresh", label: "fresh work", mode: "working", updatedAt: 80),
            session("s-quiet", label: "no clock", mode: "working"),
        ])
        #expect(focus?.id == "s-fresh")
        #expect(focus?.line == "Claude · fresh work — working")
    }

    @Test("a done row is the pick only when nothing live remains")
    func doneIsTheLastResort() {
        #expect(BuddyFocus.pick(from: [
            session("s-done", label: "shipped", lifecycle: "completed", updatedAt: 50),
        ])?.phrase == .done)
        // …but live work still outranks it.
        #expect(BuddyFocus.pick(from: [
            session("s-done", label: "shipped", lifecycle: "completed", updatedAt: 50),
            session("s-work", label: "still going", mode: "working", updatedAt: 5),
        ])?.phrase == .working)
    }

    @Test("the session name is the panel's own label — provider stripped, UUIDs shortened")
    func labelGoesThroughSessionLabel() {
        let focus = BuddyFocus.pick(from: [
            session("s-1", provider: "claude", label: "Claude 123e4567-e89b-12d3-a456-426614174000",
                    mode: "working", updatedAt: 1),
        ])
        #expect(focus?.session == "123e4567")
    }
}

/// `BuddyPlacement` is the pure half of the carry: when a press becomes
/// a drag, how hard the dangle tips, how a parked pill is kept on
/// screen, and which drop snaps home.
@Suite("Buddy placement")
struct BuddyPlacementTests {
    @Test("the threshold keeps a plain click a tap")
    func dragThreshold() {
        #expect(!BuddyPlacement.isDrag(dx: 3.9, dy: 0))
        #expect(BuddyPlacement.isDrag(dx: 4, dy: 0))
        #expect(BuddyPlacement.isDrag(dx: 3, dy: 3), "the diagonal is over four points")
        #expect(!BuddyPlacement.isDrag(dx: 2.8, dy: 2.8))
        #expect(BuddyPlacement.isDrag(dx: 0, dy: -4))
    }

    @Test("the dangle follows the travel direction and clamps")
    func tilt() {
        #expect(BuddyPlacement.dragTilt(dx: 0) == 0)
        #expect(BuddyPlacement.dragTilt(dx: 10) > 0)
        #expect(BuddyPlacement.dragTilt(dx: -10) < 0)
        #expect(BuddyPlacement.dragTilt(dx: 100) == 14)
        #expect(BuddyPlacement.dragTilt(dx: -100) == -14)
    }

    @Test("the dangle settles while the cursor holds still")
    func tiltSettles() {
        #expect(BuddyPlacement.tiltDecay(age: 0) == 1)
        #expect(BuddyPlacement.tiltDecay(age: -1) == 1)
        #expect(BuddyPlacement.tiltDecay(age: 0.22) < 0.5)
        #expect(BuddyPlacement.tiltDecay(age: 2) < 0.01)
    }

    @Test("a 3× buddy parked at the screen edge stays fully on it")
    func clampAtScale() {
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 900)
        // Roughly what BuddyPanel.present measures at 3× with a caption.
        let size = CGSize(width: 180, height: 110)
        let parked = BuddyPlacement.clampedCenter(
            CGPoint(x: 1438, y: 2), size: size, inside: visible)
        #expect(parked.x + size.width / 2 <= visible.maxX)
        #expect(parked.x - size.width / 2 >= visible.minX)
        #expect(parked.y + size.height / 2 <= visible.maxY)
        #expect(parked.y - size.height / 2 >= visible.minY)
    }

    @Test("a parked pill stays whole on the visible screen")
    func clamp() {
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let size = CGSize(width: 40, height: 30)
        #expect(BuddyPlacement.clampedCenter(CGPoint(x: 700, y: 500), size: size, inside: visible)
            == CGPoint(x: 700, y: 500))
        #expect(BuddyPlacement.clampedCenter(CGPoint(x: -500, y: 500), size: size, inside: visible).x == 20)
        #expect(BuddyPlacement.clampedCenter(CGPoint(x: 2000, y: 500), size: size, inside: visible).x == 1420)
        #expect(BuddyPlacement.clampedCenter(CGPoint(x: 700, y: -80), size: size, inside: visible).y == 15)
        #expect(BuddyPlacement.clampedCenter(CGPoint(x: 700, y: 5000), size: size, inside: visible).y == 885)
        // A pill wider than the screen centres rather than pinning an edge.
        #expect(BuddyPlacement.clampedCenter(CGPoint(x: 5, y: 500),
                                           size: CGSize(width: 2000, height: 30), inside: visible).x == 720)
    }

    @Test("a drop inside the dock's reach snaps home, outside it parks")
    func dockRule() {
        let slot = CGPoint(x: 720, y: 960)
        #expect(BuddyPlacement.docksOnDrop(center: slot, slot: slot))
        #expect(BuddyPlacement.docksOnDrop(center: CGPoint(x: 720 + 96, y: 960), slot: slot))
        #expect(BuddyPlacement.docksOnDrop(center: CGPoint(x: 720, y: 960 - 44), slot: slot))
        #expect(!BuddyPlacement.docksOnDrop(center: CGPoint(x: 720 + 97, y: 960), slot: slot))
        #expect(!BuddyPlacement.docksOnDrop(center: CGPoint(x: 720, y: 960 - 45), slot: slot),
                "the pull is tight vertically — the notch is overhead, not everywhere")
    }
}

/// The roaming half of `NotchBuddySettings`: `freePosition` survives a
/// relaunch, a `tucked` buddy stays put until something happens, and
/// the caption flag round-trips — all through the same tolerant decode.
@Suite("Buddy roaming settings")
struct BuddyRoamingSettingsTests {
    private func decode(_ json: String) throws -> NotchBuddySettings {
        try JSONDecoder().decode(NotchBuddySettings.self, from: Data(json.utf8))
    }

    @Test("the new fields round-trip")
    func roundTrip() throws {
        var settings = NotchBuddySettings(enabled: true, character: "crab")
        settings.freePosition = BuddySpot(x: 120.5, y: 804)
        settings.tucked = true
        settings.showCaption = false
        settings.scale = 2.5
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(NotchBuddySettings.self, from: data) == settings)
    }

    @Test("a file from before the fields existed docks and shows")
    func oldFileDefaults() throws {
        let settings = try decode(#"{"enabled": true, "character": "owl"}"#)
        #expect(settings.freePosition == nil)
        #expect(settings.tucked == false)
        #expect(settings.showCaption == true)
        #expect(settings.scale == 1.0)
        #expect(settings.resolvedCharacter == .owl)
    }

    @Test("the size dial decodes tolerantly: missing or mistyped is 1×, out of range clamps")
    func scaleDecode() throws {
        #expect(try decode(#"{}"#).scale == 1.0)
        #expect(try decode(#"{"scale": "enormous"}"#).scale == 1.0)
        #expect(try decode(#"{"scale": 2.25}"#).scale == 2.25)
        #expect(try decode(#"{"scale": 12}"#).scale == 3.0,
                "a hand edit can't grow a screen-filling pet")
        #expect(try decode(#"{"scale": 0.4}"#).scale == 1.0)
        #expect(NotchBuddySettings(scale: 9).scale == 3.0)
    }

    @Test("a mistyped spot reads as docked, not stranded")
    func mistypedSpot() throws {
        #expect(try decode(#"{"freePosition": "somewhere nice"}"#).freePosition == nil)
        #expect(try decode(#"{"freePosition": {"x": "here", "y": 5}}"#).freePosition == nil)
        #expect(try decode(#"{"freePosition": {"x": 12}}"#).freePosition == nil)
        #expect(try decode(#"{"freePosition": {"x": 12, "y": 9}}"#).freePosition == BuddySpot(x: 12, y: 9))
    }

    @Test("mistyped flags fall back to their defaults")
    func mistypedFlags() throws {
        let settings = try decode(#"{"tucked": "away", "showCaption": "yes"}"#)
        #expect(settings.tucked == false)
        #expect(settings.showCaption == true)
    }
}
