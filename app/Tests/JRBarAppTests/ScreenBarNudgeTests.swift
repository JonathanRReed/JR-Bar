import AppKit
import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// Newcomers and changed hidden items, on the right ear: an app new to
/// the menu bar, or a hidden item that changed, shows as its glyph on
/// the ear for a beat; the peek offers Keep / Tuck away / Always; and
/// ignoring it changes nothing.
@Suite("Screen Bar ear nudges")
@MainActor
struct ScreenBarNudgeTests {
    private func item(_ id: String, owner: String = "Example", bundle: String? = "com.example.app",
                      title: String? = nil, overflow: Bool = false) -> MenuBarItem {
        MenuBarItem(id: id, ownerPID: 1, ownerName: owner,
                    bounds: CGRect(x: 100, y: 0, width: 16, height: 24), title: title,
                    windowID: 1, isNativeOverflowControl: overflow, bundleID: bundle)
    }

    private func nudge(_ id: String = "newcomer-1-a", kind: MenuBarEarFeed.Nudge.Kind = .newcomer,
                       face: MenuBarGlyphCache.Face? = nil, icon: NSImage? = nil,
                       detail: String? = nil, section: MenuBarItemSection = .shown) -> MenuBarEarFeed.Nudge {
        MenuBarEarFeed.Nudge(id: id, kind: kind,
                             tile: MenuBarEarFeed.Tile(item: item("a", owner: "Tailscale"), face: face),
                             icon: icon, detail: detail, section: section)
    }

    // MARK: Who is new

    @Test func onlySomeoneElsesConcealableAppsCount() {
        let own = Bundle.main.bundleIdentifier ?? "com.jonathanreed.jrbar"
        let items = [
            item("t1", owner: "Tailscale", bundle: "io.tailscale.ipn.macsys"),
            item("t2", owner: "Tailscale", bundle: "io.tailscale.ipn.macsys"),
            item("wifi", owner: "Control Center", bundle: "com.apple.controlcenter"),
            item("clock", owner: "SystemUIServer", bundle: "com.apple.systemuiserver"),
            item("helper", owner: "helperd", bundle: nil),
            item("ours", owner: "JR-Bar", bundle: own),
            item("core", owner: "jrbar-core", bundle: own + ".core"),
            item("more", owner: "MenuBarAgent", bundle: "com.example.agent", overflow: true),
            item("drop", owner: "Dropbox", bundle: "com.getdropbox.dropbox"),
        ]
        #expect(MenuBarNewcomers.candidates(items, ownBundleID: own)
                == ["io.tailscale.ipn.macsys", "com.getdropbox.dropbox"],
                "bar order, once each; never Apple's extras, a bare helper, our own family or the «")
    }

    @Test func theFirstListingIsLearnedInSilence() {
        let step = MenuBarNewcomers.step(candidates: ["a", "b"], seen: nil, mapped: ["c"])
        #expect(step.arrivals.isEmpty, "turning it on never nudges about the whole bar")
        #expect(step.remember == ["a", "b", "c"])
        // An empty listing (the grant missing) teaches nothing at all.
        let empty = MenuBarNewcomers.step(candidates: [], seen: nil, mapped: ["c"])
        #expect(empty.remember == nil && empty.arrivals.isEmpty)
    }

    @Test func anAppNeverSeenAndNeverPlacedIsNews() {
        let step = MenuBarNewcomers.step(candidates: ["a", "new", "sorted"], seen: ["a"], mapped: ["sorted"])
        #expect(step.arrivals == ["new"], "one the person already gave a section is not news")
        #expect(step.remember == ["a", "new"])
        let nothing = MenuBarNewcomers.step(candidates: ["a"], seen: ["a"], mapped: [])
        #expect(nothing.remember == nil && nothing.arrivals.isEmpty, "no write when nothing moved")
    }

    @Test func theFirstSecondsOfARunAreLearnedInSilenceToo() {
        let step = MenuBarNewcomers.step(candidates: ["a", "login-item"], seen: ["a"], mapped: [],
                                         settling: true)
        #expect(step.arrivals.isEmpty)
        #expect(step.remember == ["a", "login-item"], "remembered, so it never nudges later either")
    }

    @Test func theMemoryReadsOnceAndWritesTheWholeSet() {
        var stored: [String]? = nil
        var loads = 0
        let memory = MenuBarNewcomerMemory(load: { loads += 1; return stored }, save: { stored = $0 })
        #expect(memory.seen == nil)
        #expect(memory.seen == nil)
        #expect(loads == 1, "a pass per second must not re-read the defaults")
        memory.remember(["b", "a"])
        #expect(stored == ["a", "b"])
        #expect(memory.seen == ["a", "b"])
    }

    @Test func aWatchedChangeIsTheOneTheEarSays() throws {
        let vpn = item("vpn", owner: "VPN", bundle: "com.example.vpn", title: "Connected")
        let clock = item("clock", owner: "Clock", bundle: "com.example.clock", title: "12:01")
        #expect(MenuBarUtility.earUpdate(changed: [clock, vpn], watch: []) == clock, "an empty list watches all")
        #expect(MenuBarUtility.earUpdate(changed: [clock, vpn], watch: ["com.example.vpn"]) == vpn,
                "a VPN can interrupt and a clock can't")
        #expect(MenuBarUtility.earUpdate(changed: [clock], watch: ["com.example.vpn"]) == nil)
    }

    // MARK: The answers

    @Test func theThreeAnswersAreTheThreeSections() {
        #expect(MenuBarEarChoice.allCases.map(\.title) == ["Keep", "Tuck away", "Always"])
        #expect(MenuBarEarChoice.keep.section == .shown)
        #expect(MenuBarEarChoice.tuckAway.section == .hidden)
        #expect(MenuBarEarChoice.always.section == .alwaysHidden)
    }

    @Test func aParkedUtilityAnswersNothing() {
        let utility = MenuBarUtility()
        // No nudge stands: a stale answer from a peek changes nothing.
        utility.chooseFromEar(.always, nudgeID: "newcomer-1-a")
        #expect(utility.settings().concealedApps.isEmpty)
        #expect(utility.earFeed == nil)
    }

    // MARK: The mark

    @Test func theMarkIsTheItemsOwnGlyphThenItsIconNeverItsName() throws {
        let image = NSImage(size: NSSize(width: 16, height: 16))
        let photographed = ScreenBarMenuBarMarks.nudgeSlot(
            nudge(face: MenuBarGlyphCache.Face(image: image, width: 16, template: true)))
        let glyph = try #require(photographed.glyph)
        #expect(glyph.image === image && glyph.template)
        #expect(photographed.symbol == nil && photographed.provider == nil)
        #expect(photographed.hasMark)
        #expect(photographed.markID == "newcomer-1-a")
        #expect(photographed.text == "Tailscale is new in the menu bar", "the name is VoiceOver's")

        let icon = NSImage(size: NSSize(width: 32, height: 32))
        let unphotographed = ScreenBarMenuBarMarks.nudgeSlot(nudge(icon: icon))
        #expect(unphotographed.glyph?.image === icon)
        #expect(unphotographed.glyph?.template == false, "an app icon keeps its colours")

        let bare = ScreenBarMenuBarMarks.nudgeSlot(nudge())
        #expect(bare.glyph == nil && bare.symbol == "sparkle")
    }

    @Test func aFaceCarryingWordsNeverReachesTheEar() throws {
        // A VPN's "Connected", 58 pt wide: a photograph of words.
        let words = NSImage(size: NSSize(width: 58, height: 24))
        let wide = MenuBarGlyphCache.Face(image: words, width: 58, template: true)
        let icon = NSImage(size: NSSize(width: 32, height: 32))
        let withIcon = ScreenBarMenuBarMarks.nudgeSlot(nudge(kind: .update, face: wide, icon: icon))
        let glyph = try #require(withIcon.glyph)
        #expect(glyph.image === icon && !glyph.template, "the app's icon stands in for the words")
        #expect(withIcon.symbol == nil)
        let bare = ScreenBarMenuBarMarks.nudgeSlot(nudge(kind: .update, face: wide))
        #expect(bare.glyph == nil && bare.symbol == "sparkle", "no icon: the sparkle, still never the words")
        // The cache's own icon width is the line: at it, the photograph is the mark.
        let edge = MenuBarGlyphCache.Face(image: words, width: CGFloat(MenuBarGlyphCache.persistMaxWidth),
                                          template: true)
        #expect(ScreenBarMenuBarMarks.nudgeSlot(nudge(face: edge, icon: icon)).glyph?.image === words)
    }

    @Test func aChangeSaysWhatItBecameInThePeekNotOnTheEar() {
        let change = nudge(kind: .update, detail: "Connected", section: .hidden)
        #expect(change.heading == "Changed while tucked away")
        #expect(change.words == "Tailscale changed while tucked away: Connected")
        #expect(nudge().heading == "New in your menu bar")
        #expect(ScreenBarMenuBarMarks.nudgeSlot(change).text == change.words)
    }

    @Test func aNudgeHoldsTheEarForItsBeatThenTheSideComesBack() throws {
        let meter = ScreenBarWingSlot(text: "42%", provider: "codex", meter: 0.42)
        let base = ScreenBarWings(left: nil, right: meter)
        let feed = MenuBarEarFeed(hidden: [], nudge: nudge())
        let during = ScreenBarMenuBarMarks.apply(ScreenBarMenuBarMarks(feed: feed, showsNudge: true), to: base)
        #expect(during.right?.markID == "newcomer-1-a")
        let after = ScreenBarMenuBarMarks.apply(ScreenBarMenuBarMarks(feed: feed, showsNudge: false), to: base)
        #expect(after.right == meter, "the beat over, the meter has its ear back")
        // A failure outranks a nudge.
        var failing = feed
        failing.failure = "why"
        let alert = ScreenBarMenuBarMarks.apply(ScreenBarMenuBarMarks(feed: failing), to: base)
        #expect(alert.right?.tone == .alert)
        // The nudge alone gives the peek something to show.
        #expect(!feed.isEmpty)
    }

    @Test func eachNudgeIsNewsEvenToADismissedEar() {
        let first = ScreenBarMenuBarMarks.nudgeSlot(nudge("newcomer-1-a"))
        let second = ScreenBarMenuBarMarks.nudgeSlot(nudge("update-2-a", kind: .update))
        #expect(!ScreenBarController.sameWingSubject(first, second))
        #expect(ScreenBarController.sameWingSubject(first, first))
        let meter = ScreenBarWingSlot(text: "42%", provider: "codex", meter: 0.42)
        #expect(!ScreenBarController.sameWingSubject(first, meter))
    }
}
