import AppKit
import Foundation
import Testing
@testable import JRBarApp

/// The icon under the macOS 27 concealer: macOS will not draw our own
/// item under our assertion, so `MenuBarIconMirror` is the icon — seated
/// at the right end of the blank run, wearing the face the real item
/// pushes, answering clicks the way the real button does. These pin the
/// seat, the frame, the click routing, when the mirror stands, and the
/// real item's blank face and record.
@Suite("Menu Bar — the icon's mirror")
struct MenuBarIconMirrorTests {
    private func rect(_ x: CGFloat, _ w: CGFloat) -> CGRect {
        CGRect(x: x, y: 6.5, width: w, height: 24)
    }

    // MARK: The seat

    /// The live layout of 2026-09-22 with the concealer up: the band
    /// window claims the notch flank to 980, the concealed apps left
    /// blank holes, and the first item that stays drawn is Wi-Fi.
    private var todaysRun: [CGRect] {
        [rect(1131, 30),   // Wi-Fi
         rect(1168, 56),   // Weather
         rect(1231, 40),   // Battery
         rect(1278, 28),   // Passwords
         rect(1313, 30),   // Control Center
         rect(1350, 150)]  // Clock
    }

    @Test("today's bar: the icon stands flush left of Wi-Fi, one item gap from it")
    func seatFlushLeftOfWiFi() throws {
        let seat = try #require(MenuBarIconMirror.seatMinX(drawn: todaysRun, clearOf: 980, width: 70))
        #expect(seat == 1131 - MenuBarIconMirror.itemGap - 70)
        #expect(seat + 70 + MenuBarIconMirror.itemGap == 1131)
        #expect(seat > 1040, "the right end of the blank run, not the band's edge at 986")
    }

    @Test("a shown item standing in the blank run pushes the icon to the next gap that fits")
    func seatFallsToTheNextGap() throws {
        // An app the person keeps shown stands at 1060–1090: the gap to
        // Wi-Fi (1090–1131) is too narrow for a 40 pt face, the one left
        // of it (980–1060) fits.
        let drawn = todaysRun + [rect(1060, 30)]
        let seat = try #require(MenuBarIconMirror.seatMinX(drawn: drawn, clearOf: 980, width: 40))
        #expect(seat == 1060 - MenuBarIconMirror.itemGap - 40)
    }

    @Test("nothing fits: no seat — `seat` relaxes the gaps, then covers the least")
    func seatNothingFits() {
        // A crowded bar: items every 37 pt from the band's edge on.
        let crowded = stride(from: CGFloat(990), to: 1500, by: 37).map { rect($0, 30) }
        #expect(MenuBarIconMirror.seatMinX(drawn: crowded, clearOf: 980, width: 70) == nil)
        #expect(MenuBarIconMirror.seatMinX(drawn: [], clearOf: 980, width: 70) == nil,
                "an empty listing bounds no gap")
        #expect(MenuBarIconMirror.seat(drawn: [], clearOf: 980, width: 70, rowMaxX: 1512)
                == 980 + MenuBarIconMirror.itemGap,
                "nothing drawn to cover: one item gap clear of the band")
    }

    /// How much of `drawn` a panel at `seat`, `width` wide, stands on.
    private func covered(_ drawn: [CGRect], seat: CGFloat, width: CGFloat) -> CGFloat {
        drawn.reduce(0) { $0 + max(0, min($1.maxX, seat + width) - max($1.minX, seat)) }
    }

    @Test("a hole the agent left open: too narrow for both gaps, the face stands flush in it")
    func seatInAHoleWithoutGaps() {
        // A crowded bar with one small app concealed: its 22-pt slot
        // left 1090–1131 open between ChatGPT and Wi-Fi. A 38-pt face
        // needs 52 with both gaps; the strip right of the band (980 to
        // the first item at 983) is narrower still.
        let drawn = [rect(983, 30), rect(1020, 33), rect(1060, 30)] + todaysRun
        #expect(MenuBarIconMirror.seatMinX(drawn: drawn, clearOf: 980, width: 38) == nil)
        let seat = MenuBarIconMirror.seat(drawn: drawn, clearOf: 980, width: 38, rowMaxX: 1512)
        #expect(seat == 1093, "flush left of Wi-Fi, touching it")
        #expect(covered(drawn, seat: seat, width: 38) == 0, "clear of every drawn item")
    }

    @Test("a repacked crowded bar: the last resort covers the first item by only what the gap lacks")
    func seatLeastOverlap() {
        // The agent closed the concealed apps' slots: the run starts at
        // 1017, 37 pt right of the band, every gap in it 7 pt.
        let drawn = stride(from: CGFloat(1017), to: 1500, by: 37).map { rect($0, 30) }
        #expect(MenuBarIconMirror.seatMinX(drawn: drawn, clearOf: 980, width: 38,
                                           trailingGap: 0, leadingGap: 0) == nil)
        let seat = MenuBarIconMirror.seat(drawn: drawn, clearOf: 980, width: 38, rowMaxX: 1512)
        #expect(seat == 980, "the widest gap's left edge — never under the band")
        let lacking: CGFloat = 38 - (1017 - 980)
        #expect(covered(drawn, seat: seat, width: 38) == lacking,
                "only the width the gap lacks — the old clear+6 stood 7 pt on the first item")
        // Equal gaps: the leftmost, so the clock's end of the bar stays drawn.
        let even = stride(from: CGFloat(987), to: 1500, by: 37).map { rect($0, 30) }
        #expect(MenuBarIconMirror.seat(drawn: even, clearOf: 980, width: 38, rowMaxX: 1512) == 980)
    }

    @Test("items under the band never bound a gap; a straddler and stacked ghosts count as one run")
    func seatIgnoresCoveredAndMergesOverlaps() throws {
        // Codex's mark under the band's ear, a straddler across the
        // band's edge (970–1000), and a ghost stacked on Wi-Fi.
        let drawn = [rect(866, 24), rect(970, 30), rect(1131, 30), rect(1135, 30)]
            + todaysRun.dropFirst()
        let seat = try #require(MenuBarIconMirror.seatMinX(drawn: drawn, clearOf: 980, width: 70))
        #expect(seat == 1131 - MenuBarIconMirror.itemGap - 70)
        // Only 1000–1131 is open left of Wi-Fi now: a face that needs
        // more than that minus both gaps finds nothing.
        #expect(MenuBarIconMirror.seatMinX(drawn: drawn, clearOf: 980, width: 120) == nil)
    }

    @Test("the front app's menus bound the seat like the notch and the band; an edge off the origin display never counts")
    func clearOfTakesTheAppMenus() {
        let row = CGRect(x: 0, y: 0, width: 1512, height: 37)
        func clear(notch: CGFloat? = nil, covering: CGFloat? = nil, menus: CGFloat?) -> CGFloat {
            MenuBarUtility.mirrorClearOf(notch: notch, covering: covering, appMenuEdge: menus, row: row)
        }
        #expect(clear(notch: 848.5, covering: 980, menus: 620) == 980, "menus that fit left of the notch")
        #expect(clear(notch: 848.5, covering: 980, menus: 1010) == 1010, "menus spilling past the band")
        #expect(clear(notch: 848.5, menus: nil) == 848.5, "a front app that did not answer AX")
        #expect(clear(menus: 640) == 640, "a notch-less primary with no band: the menus alone")
        #expect(clear(menus: 1800) == 0, "the front app's menus on a display right of the origin one")
        #expect(clear(menus: -400) == 0, "…or left of it")
    }

    @Test("a crowded bar's leftmost gap starts where the front app's menus end, not under them")
    func seatClearOfTheMenus() throws {
        // A notch-less primary with no band: items from 700 on, 7 pt apart.
        let crowded = stride(from: CGFloat(700), to: 1500, by: 37).map { rect($0, 30) }
        let blind = try #require(MenuBarIconMirror.seatMinX(drawn: crowded, clearOf: 0, width: 70))
        #expect(blind < 650, "clear of nothing, the icon would stand on menus that end at 650")
        let seat = try #require(MenuBarIconMirror.seatMinX(drawn: crowded, clearOf: 600, width: 70))
        #expect(seat == 700 - MenuBarIconMirror.itemGap - 70, "menus to 600 leave it room")
        #expect(MenuBarIconMirror.seatMinX(drawn: crowded, clearOf: 650, width: 70) == nil,
                "menus to 650 leave no gap that fits")
        #expect(MenuBarIconMirror.seat(drawn: crowded, clearOf: 650, width: 70, rowMaxX: 1512) == 650,
                "the last resort starts right of the menus, never on them")
    }

    // MARK: The frame

    @Test("the panel is one item high, centred on the row, flipped against the origin display")
    func frameMath() {
        // A notch Mac's row is 37 pt deep; the primary is 982 pt tall.
        let row = CGRect(x: 0, y: 0, width: 1512, height: 37)
        let frame = MenuBarIconMirror.frame(seatMinX: 1054, width: 70, row: row, primaryMaxY: 982)
        #expect(frame == NSRect(x: 1054, y: 982 - (18.5 - 12) - 24, width: 70, height: 24))
        #expect(frame.height == MenuBarIconMirror.itemHeight)
        // Quartz midY of the panel is the row's midY — the other items'.
        #expect(982 - frame.midY == row.midY)
    }

    @Test("the ‹ zone widens the panel to the left; the face keeps its slice on the right")
    func chevronZone() {
        #expect(MenuBarIconMirror.panelWidth(faceWidth: 44, hiddenCount: 0) == 44)
        #expect(MenuBarIconMirror.panelWidth(faceWidth: 44, hiddenCount: 3)
                == 44 + MenuBarIconMirror.chevronZone)
        let panel = NSRect(x: 1040, y: 951.5, width: 58, height: 24)
        #expect(MenuBarIconMirror.faceFrame(in: panel, chevronWidth: 14)
                == NSRect(x: 1054, y: 951.5, width: 44, height: 24))
        #expect(MenuBarIconMirror.faceFrame(in: panel, chevronWidth: 0) == panel)
    }

    @MainActor
    @Test("the mirror wears the face at its natural width, plus the ‹ while anything hides")
    func mirrorWidthFollowsTheFace() {
        let strip = NSImage(size: NSSize(width: 62, height: 18), flipped: false) { _ in true }
        let mirror = MenuBarIconMirror()
        mirror.update(face: MenuBarIconFace(image: strip, length: 62))
        #expect(mirror.panelWidth == 62)
        mirror.update(face: MenuBarIconFace(image: strip, length: 62, hiddenCount: 2))
        #expect(mirror.panelWidth == 62 + MenuBarIconMirror.chevronZone)
        let glyph = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in true }
        mirror.update(face: MenuBarIconFace(image: glyph, length: 24))
        #expect(mirror.panelWidth == 24, "a square style takes the item's square, not the glyph")
    }

    @MainActor
    @Test("a first face as wide as the starting panel, nothing hidden, is still laid out")
    func sameSizeFirstFaceIsLaidOut() throws {
        // The panel starts 30 pt wide; a 30-pt face with no ‹ only moves
        // it, and a move never reaches `resizeSubviews`.
        let mirror = MenuBarIconMirror()
        let glyph = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in true }
        mirror.update(face: MenuBarIconFace(image: glyph, length: 30))
        #expect(mirror.panelWidth == 30)
        mirror.setFrame(NSRect(x: 1054, y: 951.5, width: mirror.panelWidth, height: 24), display: false)
        let content = try #require(mirror.contentView)
        let button = try #require(content.subviews.compactMap { $0 as? NSButton }.first)
        #expect(button.frame == NSRect(x: 0, y: 0, width: 30, height: MenuBarIconMirror.itemHeight),
                "a 0×0 button is an icon with nothing drawn")
    }

    // MARK: Clicks

    @Test("a click's meaning: secondary is the menu anywhere; the ‹ zone toggles the run; the rest is the face")
    func clickMeaning() {
        #expect(MenuBarIconMirror.click(atX: 5, chevronWidth: 14, secondary: false) == .chevron)
        #expect(MenuBarIconMirror.click(atX: 20, chevronWidth: 14, secondary: false) == .face)
        #expect(MenuBarIconMirror.click(atX: 5, chevronWidth: 0, secondary: false) == .face,
                "no ‹ while nothing hides")
        #expect(MenuBarIconMirror.click(atX: 20, chevronWidth: 14, secondary: true) == .menu)
        #expect(MenuBarIconMirror.click(atX: 5, chevronWidth: 14, secondary: true) == .menu)
    }

    /// The utility's host, recording what the mirror asks of it.
    @MainActor
    private final class Host: MenuBarBoundaryHost {
        var boundaryFrame: CGRect? { nil }
        var boundaryGlyphLength: CGFloat = 24
        func setBoundarySpacer(_ length: CGFloat) {}
        var anchorWantsVisibleSeat = true
        func setFaceMirrored(_ mirrored: Bool) {}
        var mirroredFaceFrame: NSRect?
        var face = MenuBarIconFace()
        var onFaceChange: (@MainActor () -> Void)?
        var faceClicks = 0
        func faceClicked() { faceClicks += 1 }
        var menuPops = 0
        func popUpMenu(in view: NSView) { menuPops += 1 }
        var onBoundaryClick: (@MainActor () -> Void)?
        var hiddenItemsMenu: (@MainActor () -> NSMenu?)?
        var hiddenCount = 0
        var hiddenRevealed = false
    }

    @MainActor
    @Test("the face's click is the panel — never the hidden run; right-click is the item's menu, the ‹ the run")
    func clickRouting() {
        let utility = MenuBarUtility()
        let host = Host()
        utility.host = host
        var boundaryClicks = 0
        host.onBoundaryClick = { boundaryClicks += 1 }
        let mirror = utility.makeIconMirror()
        let view = NSView()
        mirror.route(.face, from: view)
        #expect(host.faceClicks == 1)
        #expect(boundaryClicks == 0, "the icon's click opens the panel; it never toggles the hidden run")
        mirror.route(.menu, from: view)
        #expect(host.menuPops == 1)
        #expect(boundaryClicks == 0)
        mirror.route(.chevron, from: view)
        #expect(boundaryClicks == 1)
        #expect(host.faceClicks == 1)
        // The mirror's moves become the host's anchor.
        let face = NSRect(x: 1054, y: 951.5, width: 70, height: 24)
        mirror.onPlace?(face)
        #expect(host.mirroredFaceFrame == face)
        mirror.onPlace?(nil)
        #expect(host.mirroredFaceFrame == nil)
    }

    @MainActor
    @Test("mouse events on the content land where the zones say")
    func eventsReachTheRoutes() throws {
        let mirror = MenuBarIconMirror()
        var clicks: [String] = []
        mirror.onPrimaryClick = { clicks.append("face") }
        mirror.onSecondaryClick = { _ in clicks.append("menu") }
        mirror.onChevronClick = { clicks.append("chevron") }
        let glyph = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in true }
        mirror.update(face: MenuBarIconFace(image: glyph, length: 24, hiddenCount: 1))
        mirror.setFrame(NSRect(x: 0, y: 0, width: mirror.panelWidth, height: 24), display: false)
        let content = try #require(mirror.contentView)
        func event(_ type: NSEvent.EventType, x: CGFloat, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 12),
                                            modifierFlags: flags, timestamp: 0,
                                            windowNumber: 0, context: nil,
                                            eventNumber: 0, clickCount: 1, pressure: 1))
        }
        content.mouseDown(with: try event(.leftMouseDown, x: 5))
        content.mouseDown(with: try event(.leftMouseDown, x: 26))
        content.mouseDown(with: try event(.leftMouseDown, x: 26, flags: .option))
        content.rightMouseDown(with: try event(.rightMouseDown, x: 26))
        #expect(clicks == ["chevron", "face", "menu", "menu"])
        #expect(content.hitTest(NSPoint(x: 26, y: 12)) === content,
                "the button draws; the content takes every click")
    }

    // MARK: When the mirror stands

    @Test("the mirror carries the icon while the engine conceals, lifts, or is about to — never for the hidden style")
    func mirroredPredicate() {
        let up = { (concealing: Bool, suspended: Bool, targetEmpty: Bool) in
            MenuBarUtility.mirrorsIcon(engineUp: true, styleDrawsIcon: true, concealing: concealing,
                                       suspended: suspended, targetEmpty: targetEmpty)
        }
        #expect(up(true, false, false), "assertion live")
        #expect(up(false, true, false), "a bridged click's 0.45 s lift is a suspend, not a teardown")
        #expect(up(false, false, false), "engine start: a target waiting out the drain grace")
        #expect(up(true, false, true), "the last app shown — until the drop lands")
        #expect(!up(false, false, true), "nothing concealed: macOS draws the real item itself")
        #expect(!MenuBarUtility.mirrorsIcon(engineUp: false, styleDrawsIcon: true, concealing: false,
                                            suspended: false, targetEmpty: false))
        #expect(!MenuBarUtility.mirrorsIcon(engineUp: true, styleDrawsIcon: false, concealing: true,
                                            suspended: false, targetEmpty: false))
        // An engine whose activations keep throwing holds nothing: macOS
        // draws the real item, so the mirror must not blank it.
        let failing = { (concealing: Bool, suspended: Bool) in
            MenuBarUtility.mirrorsIcon(engineUp: true, styleDrawsIcon: true, concealing: concealing,
                                       suspended: suspended, targetEmpty: false, activationFailing: true)
        }
        #expect(!failing(false, false), "a target the agent keeps refusing is not about to be concealed")
        #expect(!failing(false, true), "a bridged click on a failing engine lifts nothing")
        #expect(failing(true, false), "a failed swap leaves the old assertion concealing")
    }

    @Test("the reveal zone is the blank run up to the mirror — never the ears, never the icon")
    func revealSpan() {
        #expect(MenuBarUtility.concealedRevealSpan(start: 980, mirrorMinX: 1040,
                                                   shownMinXs: [1131, 1168]) == 980...1040)
        #expect(MenuBarUtility.concealedRevealSpan(start: 980, mirrorMinX: nil,
                                                   shownMinXs: [866, 1131, 1168]) == 980...1131,
                "no mirror: the first foreign shown item right of the start; the ear's mark never counts")
        #expect(MenuBarUtility.concealedRevealSpan(start: 980, mirrorMinX: 980, shownMinXs: []) == nil)
        #expect(MenuBarUtility.concealedRevealSpan(start: 980, mirrorMinX: nil, shownMinXs: [900]) == nil)
    }

    // MARK: The real item

    @Test("while mirrored the button wears nothing — a lift can never flash a second icon")
    func blankFace() {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in true }
        let blank = StatusItemController.worn(image: image, label: "2 working", mirrored: true)
        #expect(blank.image == nil)
        #expect(blank.label == nil)
        let dressed = StatusItemController.worn(image: image, label: "2 working", mirrored: false)
        #expect(dressed.image === image)
        #expect(dressed.label == "2 working")
    }

    @MainActor
    @Test("while mirrored the item is slim; otherwise every style gets its natural length back")
    func slimLength() {
        func length(mirrored: Bool = false, label: Bool = false, spacer: CGFloat = 0,
                    strip: CGFloat = 0) -> CGFloat {
            StatusItemController.itemLength(mirrored: mirrored, hasLabel: label, spacer: spacer,
                                            stripWidth: strip, glyphWidth: 22)
        }
        #expect(length(mirrored: true, label: true, strip: 62) == StatusItemController.anchorSlimLength)
        #expect(length(label: true) == NSStatusItem.variableLength)
        #expect(length(strip: 62) == 62)
        #expect(length() == NSStatusItem.squareLength)
        #expect(length(spacer: 30) == 52, "the spacer engine folds the glyph and its blank stretch")
        #expect(length(spacer: 30, strip: 62) == 92)
    }

    @Test("a fresh record's key sorts just left of Wi-Fi's — larger sorts further left")
    func seedKey() {
        #expect(StatusItemController.rightSideSeedKey(wifi: 300) == 304)
        #expect(StatusItemController.rightSideSeedKey(wifi: nil) == 250)
    }

    @MainActor
    @Test("the walk's records go once; the seed lands only while none exists — a ⌘-drag is never overwritten")
    func seedMigration() throws {
        let suite = "jrbar.tests.statusItemSeat.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = StatusItemController.preferredPositionKey
        let agents = "NSStatusItem Preferred Position com.jonathanreed.jrbar.menubar-agents"
        // What the retired seat walk left behind, and another item's record.
        defaults.set(267.0, forKey: key)
        defaults.set(267.0, forKey: key + "-r5")
        defaults.set(207.0, forKey: key + "-r7")
        defaults.set(490.0, forKey: agents)
        StatusItemController.seedPreferredPosition(defaults: defaults, wifi: { 300 })
        #expect(defaults.double(forKey: key) == 304)
        #expect(defaults.object(forKey: key + "-r5") == nil)
        #expect(defaults.object(forKey: key + "-r7") == nil)
        #expect(defaults.double(forKey: agents) == 490, "other items' records are not ours to sweep")
        #expect(defaults.bool(forKey: StatusItemController.seatMigrationKey))
        // The person ⌘-drags the item: that record is theirs from here on.
        defaults.set(512.0, forKey: key)
        StatusItemController.seedPreferredPosition(defaults: defaults, wifi: { 300 })
        #expect(defaults.double(forKey: key) == 512)
    }
}
