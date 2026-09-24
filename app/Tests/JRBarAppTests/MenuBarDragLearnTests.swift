import AppKit
import Foundation
import Testing
@testable import JRBarApp
@testable import JRBarCore

/// ⌘-drag across the icon hides or shows: the pure rules — which side a
/// drop landed on, what the press took hold of, whether the agent really
/// moved it, what a drop writes and what it says — and the settings
/// behind them.
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
        func intent(_ x: CGFloat, y: CGFloat = 18, option: Bool = false) -> MenuBarDragIntent {
            MenuBarDragLearn.intent(from: start, to: CGPoint(x: x, y: y), icon: Self.icon,
                                    row: Self.row, option: option)
        }
        #expect(intent(1000) == .hide(always: false))
        #expect(intent(1000, option: true) == .hide(always: true))
        #expect(intent(1300) == .show)
        #expect(intent(1075) == .none, "on the icon")
        #expect(intent(1040 - 2) == .none, "on the icon's edge, inside the slack")
        #expect(intent(1112 + 2) == .none)
        #expect(intent(1040 - 4) == .hide(always: false), "just past the slack")
        #expect(intent(1000, y: 120) == .none, "dropped off the bar")
        #expect(MenuBarDragLearn.intent(from: start, to: CGPoint(x: 1136, y: 18), icon: Self.icon,
                                        row: Self.row, option: false) == .none, "a ⌘-click, not a drag")
        #expect(MenuBarDragLearn.crossed(from: start, to: CGPoint(x: 1000, y: 18), icon: Self.icon))
        #expect(!MenuBarDragLearn.crossed(from: CGPoint(x: 1012, y: 18), to: CGPoint(x: 990, y: 18),
                                          icon: Self.icon))
    }

    // MARK: The grabbed item

    @Test("the press takes hold of the drawn item under it — never ours, the «, our family or a ghost")
    func grabbed() {
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
        func outcome(_ intent: MenuBarDragIntent, _ grabbed: MenuBarDragLearn.Grabbed,
                     current: MenuBarItemSection = .shown, count: Int = 1) -> MenuBarDragLearn.Outcome {
            MenuBarDragLearn.outcome(intent: intent, current: current, grabbed: grabbed,
                                     appName: "iStat Menus", appItemCount: count)
        }
        let hide = MenuBarDragIntent.hide(always: false)
        #expect(outcome(hide, .app) == .init(section: .hidden))
        #expect(outcome(hide, .system) == .init(note: .systemItem), "macOS's own: a note, never a write")
        #expect(outcome(.show, .system) == .init(), "nothing asked of a system item that stays")
        #expect(outcome(hide, .appleExtra) == .init(section: .hidden, note: .appleExtraCovered))
        #expect(outcome(.show, .appleExtra, current: .hidden) == .init(section: .shown))
        #expect(outcome(hide, .app, count: 2) == .init(section: .hidden,
                                                         note: .wholeApp(name: "iStat Menus", hidden: true)))
        #expect(outcome(.show, .app, current: .hidden, count: 2)
                == .init(section: .shown, note: .wholeApp(name: "iStat Menus", hidden: false)))
        #expect(outcome(hide, .systemConcealable) == .init(section: .hidden))
        #expect(outcome(.none, .app) == .init())
        let notes: [MenuBarDropNote] = [.systemItem, .appleExtraCovered, .otherDisplay,
                                        .wholeApp(name: "iStat Menus", hidden: true), .notMoved]
        #expect(Set(notes.map(\.text)).count == notes.count)
        #expect(MenuBarDropNote.systemItem.text.contains("System Settings › Control Center"))
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
        let crossed = MenuBarDragLearn.verdict(grabbed: tailscale, before: before, after: shifted,
                                               crossed: true, row: Self.row, concealed: [])
        #expect(crossed.confirmed && crossed.anchorDrifted)
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
