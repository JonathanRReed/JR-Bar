import AppKit
import Foundation
import Testing
@testable import JRBarApp
@testable import JRBarCore

/// ⌘-drag across the icon hides or shows: the pure rules — which side a
/// drop landed on, what the press took hold of, whether the agent really
/// moved it, what a drop writes and what it says — and the utility's
/// guards, the `424c08ad` lessons pinned: only an observed press and
/// release writes, one write per drag, and a listing that changes on
/// its own never writes.
@Suite("Menu Bar — ⌘-drag across the icon")
struct MenuBarDragLearnTests {
    /// The bar the tests drag on, in Quartz points: the band's edge at
    /// 980, the icon's mirror standing at 1040–1112 over our slim real
    /// slot, then the drawn run right of it.
    static let row = CGRect(x: 0, y: 0, width: 1512, height: 37)
    static let icon: ClosedRange<CGFloat> = 1040...1112
    static let ourPID = ProcessInfo.processInfo.processIdentifier

    static func item(_ id: String, owner: String, pid: pid_t, x: CGFloat, width: CGFloat = 24,
                     bundle: String?, identifier: String? = nil, y: CGFloat = 6.5) -> MenuBarItem {
        MenuBarItem(id: id, ownerPID: pid, ownerName: owner,
                    bounds: CGRect(x: x, y: y, width: width, height: 24),
                    title: nil, windowID: 0, identifier: identifier, bundleID: bundle)
    }

    static let tailscaleID = "io.tailscale.ipn.macsys"
    static let istatID = "com.bjango.istatmenus"
    static let slackID = "com.tinyspeck.slackmacgap"

    /// Slack stands shown left of the icon (no gap fits it elsewhere);
    /// right of the icon Tailscale, iStat's two items, Passwords, Wi-Fi,
    /// Weather, Control Center and the clock.
    static func bar(shift: CGFloat = 0, rightOfCC: CGFloat = 0) -> [MenuBarItem] {
        [
            item("Slack", owner: "Slack", pid: 301, x: 1000 + shift, bundle: slackID),
            item("JR-Bar·status", owner: "JR-Bar", pid: ourPID, x: 1076 + shift, width: 30,
                 bundle: Bundle.main.bundleIdentifier, identifier: StatusItemController.accessibilityIdentifier),
            item("Tailscale", owner: "Tailscale", pid: 302, x: 1119 + shift, bundle: tailscaleID),
            item("iStat Menus#0", owner: "iStat Menus", pid: 303, x: 1150 + shift, width: 30, bundle: istatID),
            item("iStat Menus#1", owner: "iStat Menus", pid: 303, x: 1187 + shift, width: 30, bundle: istatID),
            item("Passwords", owner: "Passwords", pid: 304, x: 1224 + shift, width: 39,
                 bundle: "com.apple.Passwords.MenuBarExtra"),
            item("MenuBarAgent·com.apple.menuextra.wifi", owner: "MenuBarAgent", pid: 690, x: 1270 + shift,
                 width: 22, bundle: "com.apple.MenuBarAgent", identifier: "com.apple.menuextra.wifi"),
            item("Weather", owner: "Weather", pid: 305, x: 1299 + shift, width: 60, bundle: "com.apple.weather.menu"),
            item("Control Center·com.apple.menuextra.controlcenter", owner: "Control Center", pid: 400,
                 x: 1366 + rightOfCC, width: 26, bundle: "com.apple.controlcenter",
                 identifier: "com.apple.menuextra.controlcenter"),
            item("Control Center·com.apple.menuextra.clock", owner: "Control Center", pid: 400,
                 x: 1399 + rightOfCC, width: 100, bundle: "com.apple.controlcenter",
                 identifier: "com.apple.menuextra.clock"),
        ]
    }

    /// The bar after the agent moved `id` to `x` — nothing else moves.
    static func moved(_ id: String, to x: CGFloat, in listing: [MenuBarItem]) -> [MenuBarItem] {
        listing.map { item in
            guard item.id == id else { return item }
            return MenuBarItem(id: item.id, ownerPID: item.ownerPID, ownerName: item.ownerName,
                               bounds: CGRect(x: x, y: item.bounds.minY, width: item.bounds.width,
                                              height: item.bounds.height),
                               title: item.title, windowID: 0, identifier: item.identifier,
                               bundleID: item.bundleID)
        }
    }

    // MARK: Intent

    @Test("the intent table: left hides, right shows, on the icon or off the row or a ⌘-click is nothing, ⌥ is Always")
    func intentTable() {
        let start = CGPoint(x: 1131, y: 18)
        func dropIntent(_ x: CGFloat, y: CGFloat = 18, option: Bool = false) -> MenuBarDragIntent {
            MenuBarDragLearn.intent(from: start, to: CGPoint(x: x, y: y), icon: Self.icon,
                                    row: Self.row, option: option)
        }
        #expect(dropIntent(1000) == .hide(always: false))
        #expect(dropIntent(1000, option: true) == .hide(always: true))
        #expect(dropIntent(1300) == .show)
        #expect(dropIntent(1075) == .none, "on the icon")
        #expect(dropIntent(1040 - 2) == .none, "on the icon's edge, inside the slack")
        #expect(dropIntent(1112 + 2) == .none)
        #expect(dropIntent(1040 - 4) == .hide(always: false), "just past the slack")
        #expect(dropIntent(1000, y: 120) == .none, "dropped off the bar")
        #expect(MenuBarDragLearn.intent(from: start, to: CGPoint(x: 1136, y: 18), icon: Self.icon,
                                        row: Self.row, option: false) == .none, "a ⌘-click, not a drag")
        #expect(MenuBarDragLearn.crossed(from: start, to: CGPoint(x: 1000, y: 18), icon: Self.icon))
        #expect(!MenuBarDragLearn.crossed(from: CGPoint(x: 1012, y: 18), to: CGPoint(x: 990, y: 18),
                                          icon: Self.icon))
    }

    // MARK: The grabbed item

    @Test("the press takes hold of the drawn item under it — never ours, the «, our family or a ghost")
    func grabbedItem() {
        let bar = Self.bar()
        func grab(_ x: CGFloat, items: [MenuBarItem] = Self.bar(), concealed: Set<String> = []) -> String? {
            MenuBarDragLearn.grabbed(at: CGPoint(x: x, y: 2), items: items, concealed: concealed,
                                     ourPID: Self.ourPID, row: Self.row)?.id
        }
        #expect(grab(1131) == "Tailscale", "a press at the bar's very top edge still counts")
        #expect(grab(1090) == nil, "our own slot under the icon")
        #expect(grab(1280) == "MenuBarAgent·com.apple.menuextra.wifi", "macOS's own is grabbed — it gets its note")
        let overflow = MenuBarItem(id: "«", ownerPID: 690, ownerName: "MenuBarAgent",
                                   bounds: CGRect(x: 960, y: 6.5, width: 17, height: 24), title: nil,
                                   windowID: 0, isNativeOverflowControl: true, bundleID: "com.apple.MenuBarAgent")
        #expect(grab(965, items: bar + [overflow]) == nil, "never the «")
        // A concealed app's ghost stacked on Tailscale's frame: the live
        // item speaks, the ghost never does.
        let ghost = Self.item("ChatGPT", owner: "ChatGPT", pid: 306, x: 1121, bundle: "com.openai.chat")
        #expect(grab(1131, items: bar + [ghost], concealed: ["com.openai.chat"]) == "Tailscale")
        #expect(grab(1123, items: [ghost], concealed: ["com.openai.chat"]) == nil)
        if let own = Bundle.main.bundleIdentifier {
            let meter = Self.item("jrbar-core", owner: "jrbar-core", pid: 307, x: 1450, bundle: own + ".core")
            #expect(grab(1455, items: [meter]) == nil, "our own family's items are never a pick")
        }
    }

    // MARK: Sections and notes

    @Test("a hide keeps Always, ⌥ asks for Always, a show clears both, a drop where it already is writes nothing")
    func sectionMapping() {
        #expect(MenuBarDragLearn.section(for: .hide(always: false), current: .shown) == .hidden)
        #expect(MenuBarDragLearn.section(for: .hide(always: false), current: .hidden) == nil)
        #expect(MenuBarDragLearn.section(for: .hide(always: false), current: .alwaysHidden) == nil,
                "an existing Always survives a hide-drop")
        #expect(MenuBarDragLearn.section(for: .hide(always: true), current: .hidden) == .alwaysHidden)
        #expect(MenuBarDragLearn.section(for: .hide(always: true), current: .alwaysHidden) == nil)
        #expect(MenuBarDragLearn.section(for: .show, current: .alwaysHidden) == .shown)
        #expect(MenuBarDragLearn.section(for: .show, current: .hidden) == .shown)
        #expect(MenuBarDragLearn.section(for: .show, current: .shown) == nil, "a reorder is only a reorder")
        #expect(MenuBarDragLearn.section(for: .none, current: .shown) == nil)
    }

    @Test("every drop that asked for something says what it did — or why not")
    func outcomes() {
        func dropOutcome(_ intent: MenuBarDragIntent, _ grabbed: MenuBarDragLearn.Grabbed,
                     current: MenuBarItemSection = .shown, count: Int = 1) -> MenuBarDragLearn.Outcome {
            MenuBarDragLearn.outcome(intent: intent, current: current, grabbed: grabbed,
                                     appName: "iStat Menus", appItemCount: count)
        }
        let hide = MenuBarDragIntent.hide(always: false)
        #expect(dropOutcome(hide, .app) == .init(section: .hidden))
        #expect(dropOutcome(hide, .system) == .init(note: .systemItem), "macOS's own: a note, never a write")
        #expect(dropOutcome(.show, .system) == .init(), "nothing asked of a system item that stays")
        #expect(dropOutcome(hide, .appleExtra) == .init(section: .hidden, note: .appleExtraCovered))
        #expect(dropOutcome(.show, .appleExtra, current: .hidden) == .init(section: .shown))
        #expect(dropOutcome(hide, .app, count: 2) == .init(section: .hidden,
                                                         note: .wholeApp(name: "iStat Menus", hidden: true)))
        #expect(dropOutcome(.show, .app, current: .hidden, count: 2)
                == .init(section: .shown, note: .wholeApp(name: "iStat Menus", hidden: false)))
        #expect(dropOutcome(hide, .systemConcealable) == .init(section: .hidden))
        #expect(dropOutcome(.none, .app) == .init())
        let notes: [MenuBarDropNote] = [.systemItem, .appleExtraCovered, .otherDisplay,
                                        .wholeApp(name: "iStat Menus", hidden: true), .notMoved]
        #expect(Set(notes.map(\.text)).count == notes.count)
        #expect(MenuBarDropNote.systemItem.text.contains("System Settings › Menu Bar"))
        #expect(MenuBarDropNote.wholeApp(name: "iStat Menus", hidden: true).text == "Hid all of iStat Menus's items")
    }

    // MARK: Confirmation

    @Test("confirmed rejects an unmoved frame; a real reorder confirms")
    func confirmedUnmoved() throws {
        let before = Self.bar()
        let tailscale = try #require(before.first { $0.id == "Tailscale" })
        let unmoved = MenuBarDragLearn.verdict(grabbed: tailscale, before: before, after: before,
                                               crossed: true, row: Self.row, concealed: [])
        #expect(!unmoved.confirmed)
        let after = Self.moved("Tailscale", to: 1045, in: before)
        #expect(MenuBarDragLearn.verdict(grabbed: tailscale, before: before, after: after,
                                         crossed: true, row: Self.row, concealed: []).confirmed)
        #expect(MenuBarDragLearn.reordered(tailscale, before: before, after: after, row: Self.row, concealed: []))
    }

    @Test("a 56 pt whole-bar shift is no confirmation — only a drop that crossed the icon is believed")
    func wholeBarShift() throws {
        let before = Self.bar()
        let slack = try #require(before.first { $0.id == "Slack" })
        // The recording indicator: every item, the clock included, 56 pt left.
        let shifted = Self.bar(shift: -56, rightOfCC: -56)
        let notCrossed = MenuBarDragLearn.verdict(grabbed: slack, before: before, after: shifted,
                                                  crossed: false, row: Self.row, concealed: [])
        #expect(!notCrossed.confirmed)
        #expect(notCrossed.anchorDrifted)
        let tailscale = try #require(before.first { $0.id == "Tailscale" })
        let acrossIcon = MenuBarDragLearn.verdict(grabbed: tailscale, before: before, after: shifted,
                                                  crossed: true, row: Self.row, concealed: [])
        #expect(acrossIcon.confirmed && acrossIcon.anchorDrifted)
        // The indicator between the item and a clock that stays put: the
        // item moved against the anchor, but nothing reordered.
        let between = Self.bar(shift: -56)
        #expect(!MenuBarDragLearn.verdict(grabbed: slack, before: before, after: between,
                                          crossed: false, row: Self.row, concealed: []).confirmed)
        // Accessibility did not answer: only the crossing drop.
        #expect(MenuBarDragLearn.verdict(grabbed: tailscale, before: before, after: nil,
                                         crossed: true, row: Self.row, concealed: []).confirmed)
        #expect(!MenuBarDragLearn.verdict(grabbed: slack, before: before, after: nil,
                                          crossed: false, row: Self.row, concealed: []).confirmed)
    }

    // MARK: The utility — one press, one release, one write

    /// Records what the utility's concealer asks of the agent.
    @MainActor
    private final class FakeBackend: MenuBarConcealBackend {
        var n = 0
        func activate(allowedBundleIDs: [String]) async throws -> MenuBarAssertionToken {
            n += 1
            return MenuBarAssertionToken(NSNumber(value: n))
        }
        func invalidate(_ token: MenuBarAssertionToken) {}
    }

    /// A utility under a fake concealer on the test bar, with the drag's
    /// seams steered: the press snapshot, the confirming read, no settle,
    /// the icon at 1040–1112, and notes recorded instead of shown.
    @MainActor
    private final class Harness {
        let utility: MenuBarUtility
        var state: MenuBarSettings
        var writes = 0
        var notes: [String] = []
        var listing: [MenuBarItem]
        var fresh: [MenuBarItem]?
        var rows: [CGRect] = [MenuBarDragLearnTests.row]

        init(state: MenuBarSettings = MenuBarSettings(enabled: true, concealSeeded: true),
             listing: [MenuBarItem] = MenuBarDragLearnTests.bar()) {
            self.state = state
            self.listing = listing
            self.fresh = listing
            utility = MenuBarUtility(runningBundleIDRead: {
                [MenuBarDragLearnTests.tailscaleID, MenuBarDragLearnTests.istatID, MenuBarDragLearnTests.slackID]
            })
            utility.settings = { [unowned self] in self.state }
            utility.onSettingsChange = { [unowned self] draft in
                self.state = draft
                self.writes += 1
            }
            utility.concealer = MenuBarConcealer(backend: FakeBackend())
            utility.concealerStartedAt = .distantPast
            utility.dragListing = { [unowned self] in self.listing }
            utility.dragFreshListing = { [unowned self] _ in self.fresh }
            utility.dragSettle = 0
            utility.dragUnfreezeDelay = 0
            utility.dragIconSpan = { MenuBarDragLearnTests.icon }
            utility.dragRows = { [unowned self] in self.rows }
            utility.presentDropNote = { [unowned self] text in self.notes.append(text) }
            utility.hider.listItems = { [unowned self] in self.listing }
            utility.hider.rowRect = { MenuBarDragLearnTests.row }
            utility.hider.shuttersSuppressed = true
        }

        /// One ⌘-drag from `from` to `to` (x on the row), settled.
        func drag(from: CGFloat, to: CGFloat, option: Bool = false, y: CGFloat = 18) async {
            utility.commandPressed(at: CGPoint(x: from, y: 18))
            utility.commandReleased(at: CGPoint(x: to, y: y), option: option)
            await utility.dragConfirmTask?.value
            utility.dragConfirmTask = nil
        }
    }

    @MainActor
    @Test("one press and release across the icon writes exactly one app — and a second release writes nothing")
    func pressReleaseWritesOnce() async {
        let h = Harness()
        h.fresh = Self.moved("Tailscale", to: 1045, in: h.listing)
        await h.drag(from: 1131, to: 1000)
        #expect(h.state.concealedApps == [Self.tailscaleID: .hidden])
        #expect(h.writes == 1)
        #expect(h.notes.isEmpty)
        // No press, no drag: a stray release is nothing.
        h.utility.commandReleased(at: CGPoint(x: 1000, y: 18), option: false)
        await h.utility.dragConfirmTask?.value
        #expect(h.writes == 1, "one write per drag")
        #expect(!h.utility.dragFrozen, "the icon thaws once the drop is settled")
    }

    @MainActor
    @Test("a listing reflow with no press writes nothing — the 424c08ad regression")
    func reflowWritesNothing() async {
        let h = Harness()
        // The bar reflows under nobody's hand: Tailscale lands left of
        // the icon, the recording indicator shifts everything, a
        // relaunch reorders — pass after pass.
        for listing in [Self.moved("Tailscale", to: 1045, in: h.listing), Self.bar(shift: -56),
                        Self.bar(shift: -56, rightOfCC: -56), Self.bar()] {
            h.listing = listing
            h.fresh = listing
            h.utility.hider.reconcile()
        }
        await Task.yield()
        #expect(h.writes == 0)
        #expect(h.state.concealedApps.isEmpty && h.state.sections.isEmpty)
    }

    @MainActor
    @Test("a drag under a profile that speaks for the app writes the profile's delta, not the base")
    func profileDelta() async {
        var state = MenuBarSettings(enabled: true, concealSeeded: true)
        state.profiles = [MenuBarSettings.Profile(id: "work", name: "Work", sections: [:],
                                                  concealedApps: [Self.tailscaleID: .shown])]
        state.curation.activeProfileID = "work"
        let h = Harness(state: state)
        h.fresh = Self.moved("Tailscale", to: 1045, in: h.listing)
        await h.drag(from: 1131, to: 1000)
        #expect(h.state.profiles.first?.concealedApps[Self.tailscaleID] == .hidden)
        #expect(h.state.concealedApps[Self.tailscaleID] == nil, "the base is untouched")
        #expect(h.writes == 1)
    }

    @MainActor
    @Test("⌥ at the drop writes Always Hidden; a drop back right of the icon shows it again")
    func optionAndShow() async {
        let h = Harness()
        h.fresh = Self.moved("Tailscale", to: 1045, in: h.listing)
        await h.drag(from: 1131, to: 1000, option: true)
        #expect(h.state.concealedApps[Self.tailscaleID] == .alwaysHidden)
        // Revealed inline, the assertion holds nothing and Tailscale
        // stands drawn left of the icon; dragged back out.
        h.utility.concealer = MenuBarConcealer(backend: FakeBackend())
        h.listing = Self.moved("Tailscale", to: 1045, in: Self.bar())
        h.fresh = Self.bar()
        await h.drag(from: 1057, to: 1300)
        #expect(h.state.concealedApps[Self.tailscaleID] == .shown)
        #expect(h.writes == 2)
    }

    @MainActor
    @Test("a 56 pt whole-bar shift with no reorder writes nothing unless the drop crossed the icon")
    func shiftGuard() async {
        let h = Harness()
        h.fresh = Self.bar(shift: -56, rightOfCC: -56)
        // Slack, shown left of the icon, dragged further left: no crossing.
        await h.drag(from: 1012, to: 990)
        #expect(h.writes == 0)
        #expect(h.notes == [MenuBarDropNote.notMoved.text])
        // Tailscale across the icon under the same shift: believed.
        await h.drag(from: 1131, to: 1000)
        #expect(h.state.concealedApps == [Self.tailscaleID: .hidden])
        #expect(h.writes == 1)
    }

    @MainActor
    @Test("each drop the bar cannot honour says why and writes nothing")
    func unhonouredNotes() async {
        let h = Harness()
        // macOS's own item.
        await h.drag(from: 1280, to: 1000)
        #expect(h.notes.last == MenuBarDropNote.systemItem.text)
        // Another display's bar.
        let second = CGRect(x: 1512, y: 0, width: 1920, height: 24)
        h.rows = [Self.row, second]
        h.utility.commandPressed(at: CGPoint(x: 1600, y: 10))
        h.utility.commandReleased(at: CGPoint(x: 1560, y: 10), option: false)
        #expect(h.notes.last == MenuBarDropNote.otherDisplay.text)
        // The agent did not move it.
        h.fresh = h.listing
        await h.drag(from: 1131, to: 1000)
        #expect(h.notes.last == MenuBarDropNote.notMoved.text)
        #expect(h.writes == 0)
        #expect(h.notes.count == 3)
    }

    @MainActor
    @Test("Apple's extra takes its cover and says so; a multi-item app says the whole app moved")
    func notesWithWrites() async {
        let h = Harness()
        h.fresh = Self.moved("Passwords", to: 1045, in: h.listing)
        await h.drag(from: 1240, to: 1000)
        #expect(h.state.sections["Passwords"] == .hidden, "a cover where it sits")
        #expect(h.state.concealedApps.isEmpty)
        #expect(h.notes.last == MenuBarDropNote.appleExtraCovered.text)
        h.fresh = Self.moved("iStat Menus#0", to: 1045, in: h.listing)
        await h.drag(from: 1165, to: 1000)
        #expect(h.state.concealedApps[Self.istatID] == .hidden)
        #expect(h.notes.last == MenuBarDropNote.wholeApp(name: "iStat Menus", hidden: true).text)
        #expect(h.writes == 2)
    }

    @MainActor
    @Test("with concealAppleExtras on, Apple's extra hides through the agent like any app")
    func appleExtraConcealed() async {
        var state = MenuBarSettings(enabled: true, concealSeeded: true)
        state.curation.concealAppleExtras = true
        let h = Harness(state: state)
        h.fresh = Self.moved("Passwords", to: 1045, in: h.listing)
        await h.drag(from: 1240, to: 1000)
        #expect(h.state.concealedApps["com.apple.Passwords.MenuBarExtra"] == .hidden)
        #expect(h.state.sections.isEmpty)
        #expect(h.notes.isEmpty)
    }

    @MainActor
    @Test("never during the start grace, never with the setting off, never our own slot")
    func guards() async {
        let h = Harness()
        h.fresh = Self.moved("Tailscale", to: 1045, in: h.listing)
        h.utility.concealerStartedAt = Date()
        await h.drag(from: 1131, to: 1000)
        #expect(h.writes == 0, "the engine's first seconds")
        h.utility.concealerStartedAt = .distantPast
        h.state.curation.dragToHide = false
        await h.drag(from: 1131, to: 1000)
        #expect(h.writes == 0, "switched off")
        h.state.curation.dragToHide = true
        await h.drag(from: 1090, to: 1000)
        #expect(h.writes == 0, "our own slot is not an item to pick")
        #expect(!h.utility.dragFrozen)
        h.utility.concealer = nil
        await h.drag(from: 1131, to: 1000)
        #expect(h.writes == 0, "only under the concealer")
    }

    @MainActor
    @Test("the drag freezes the icon and the hover reveal until the drop is settled")
    func freezeLifecycle() async {
        let h = Harness()
        h.utility.dragUnfreezeDelay = 60
        h.utility.commandPressed(at: CGPoint(x: 1131, y: 18))
        #expect(h.utility.dragFrozen)
        #expect(h.utility.dragFrozenMaxX == Self.icon.upperBound)
        #expect(h.utility.reveal.suppressed(), "the hover reveal stands down mid-drag")
        h.fresh = Self.moved("Tailscale", to: 1045, in: h.listing)
        h.utility.commandReleased(at: CGPoint(x: 1000, y: 18), option: false)
        await h.utility.dragConfirmTask?.value
        #expect(h.utility.dragFrozen, "a beat after the write, still frozen")
        h.utility.thawDrag(after: 0)
        #expect(!h.utility.dragFrozen)
    }

    @MainActor
    @Test("a press that grabs nothing, or lands on another display, never holds the freeze past its thaw")
    func emptyPressNeverSticks() async {
        let h = Harness()
        h.utility.dragUnfreezeDelay = 60
        h.fresh = Self.moved("Tailscale", to: 1045, in: h.listing)
        await h.drag(from: 1131, to: 1000)
        #expect(h.utility.dragFrozen, "the drop's thaw is still waiting")
        // Inside that window: a ⌘-press on the icon itself, which takes
        // hold of nothing. It holds nothing, so the waiting thaw lands.
        h.utility.commandPressed(at: CGPoint(x: 1090, y: 18))
        #expect(h.utility.dragInFlight == nil)
        h.utility.thawDrag(after: 0)
        #expect(!h.utility.dragFrozen)
        h.utility.commandReleased(at: CGPoint(x: 1000, y: 18), option: false)
        #expect(!h.utility.dragFrozen)
        // Frozen again by a second drop; then a press on another
        // display's bar: it waits for its release to say its note, but
        // the thaw does not wait for it.
        h.state.concealedApps = [:]
        h.utility.concealer = MenuBarConcealer(backend: FakeBackend())
        await h.drag(from: 1131, to: 1000)
        #expect(h.utility.dragFrozen)
        h.rows = [Self.row, CGRect(x: 1512, y: 0, width: 1920, height: 24)]
        h.utility.commandPressed(at: CGPoint(x: 1600, y: 10))
        h.utility.thawDrag(after: 0)
        #expect(!h.utility.dragFrozen)
        h.utility.commandReleased(at: CGPoint(x: 1560, y: 10), option: false)
        #expect(h.notes.last == MenuBarDropNote.otherDisplay.text)
        #expect(h.writes == 2)
    }

    @MainActor
    @Test("a press whose release was lost never pairs with the next press's release")
    func lostReleaseNeverPairs() async {
        let h = Harness()
        h.fresh = Self.moved("Tailscale", to: 1045, in: h.listing)
        // Tailscale pressed; its release never arrives.
        h.utility.commandPressed(at: CGPoint(x: 1131, y: 18))
        #expect(h.utility.dragFrozen)
        // The next ⌘-press lands on the blank stretch, and its release
        // left of the icon: Tailscale's press must not speak for it.
        h.utility.commandPressed(at: CGPoint(x: 1032, y: 18))
        #expect(!h.utility.dragFrozen, "the lost drag let go")
        h.utility.commandReleased(at: CGPoint(x: 1000, y: 18), option: false)
        await h.utility.dragConfirmTask?.value
        #expect(h.writes == 0)
        #expect(h.state.concealedApps.isEmpty)
    }

    // MARK: Settings

    @Test("the drag's settings default right, round-trip, and read tolerantly")
    func curationKeys() throws {
        let fresh = MenuBarCuration()
        #expect(fresh.dragToHide)
        #expect(!fresh.concealAppleExtras && !fresh.revealWhileDragging && !fresh.concealSystemItems)
        #expect(fresh.mirrorSeat == .gap && fresh.itemBarAt == .icon && fresh.newItems == .asPlaced)
        #expect(fresh.layoutTableBookmark == nil)
        var custom = MenuBarCuration()
        custom.dragToHide = false
        custom.concealAppleExtras = true
        custom.mirrorSeat = .slot
        custom.revealWhileDragging = true
        custom.layoutTableBookmark = Data([1, 2, 3])
        custom.itemBarAt = .pointer
        custom.newItems = .hidden
        custom.concealSystemItems = true
        let decoded = try JSONDecoder().decode(MenuBarCuration.self, from: JSONEncoder().encode(custom))
        #expect(decoded == custom)
        // Missing keys are the defaults; mistyped ones and unknown cases too.
        let empty = try JSONDecoder().decode(MenuBarCuration.self, from: Data("{}".utf8))
        #expect(empty == MenuBarCuration(profileModel: 0))
        let odd = Data("""
            {"dragToHide": "yes", "mirrorSeat": "sideways", "itemBarAt": 3, "newItems": "later",
             "concealAppleExtras": 1, "layoutTableBookmark": 12}
            """.utf8)
        let tolerant = try JSONDecoder().decode(MenuBarCuration.self, from: odd)
        #expect(tolerant.dragToHide && tolerant.mirrorSeat == .gap && tolerant.itemBarAt == .icon)
        #expect(tolerant.newItems == .asPlaced && !tolerant.concealAppleExtras)
        #expect(tolerant.layoutTableBookmark == nil)
        // Apple's extras: a file that never chose writes nothing and
        // follows the code default, so flipping it (J23) reaches it; a
        // choice made on the card is kept either way.
        let untouched = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(MenuBarCuration())) as? [String: Any]
        #expect(untouched?["concealAppleExtras"] == nil)
        #expect(fresh.concealAppleExtrasChoice == nil)
        #expect(fresh.concealAppleExtras == MenuBarCuration.concealAppleExtrasDefault)
        let chosenOff = try JSONDecoder().decode(MenuBarCuration.self,
                                                 from: Data(#"{"concealAppleExtras": false}"#.utf8))
        #expect(chosenOff.concealAppleExtrasChoice == false)
        #expect(!chosenOff.concealAppleExtras)
        // A bookmark past the limit is not one.
        #expect(MenuBarCuration.clampedBookmark(Data(count: MenuBarCuration.bookmarkLimit + 1)) == nil)
        #expect(MenuBarCuration.clampedBookmark(Data()) == nil)
        // The whole settings file carries them.
        var settings = MenuBarSettings()
        settings.curation = custom
        let round = try JSONDecoder().decode(MenuBarSettings.self, from: JSONEncoder().encode(settings))
        #expect(round.curation == custom)
    }

    @Test("the focus-change rehide round-trips; an unknown mode reads as timed")
    func rehideMode() throws {
        var settings = MenuBarSettings()
        settings.rehideMode = .focusChange
        let round = try JSONDecoder().decode(MenuBarSettings.self, from: JSONEncoder().encode(settings))
        #expect(round.rehideMode == .focusChange)
        let odd = Data(#"{"rehideMode": "whenever"}"#.utf8)
        #expect(try JSONDecoder().decode(MenuBarSettings.self, from: odd).rehideMode == .timed)
    }
}
