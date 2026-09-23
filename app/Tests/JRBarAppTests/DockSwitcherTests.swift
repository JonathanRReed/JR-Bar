import ApplicationServices
import Testing
@testable import JRBarApp
@testable import JRBarCore

/// The ⌥⇥ switcher's pure half: the CGWindow/AX merge, the recency
/// order, and the selection walk.
struct DockSwitcherTests {

    private func row(pid: pid_t, wid: CGWindowID, title: String = "",
                     x: CGFloat = 0, y: CGFloat = 0,
                     w: CGFloat = 800, h: CGFloat = 600) -> SwitcherWindowRow {
        SwitcherWindowRow(pid: pid, windowID: wid, title: title,
                          bounds: CGRect(x: x, y: y, width: w, height: h))
    }

    private func window(id: Int, title: String, minimized: Bool = false,
                        frame: CGRect? = nil) -> DockPreviewWindow {
        DockPreviewWindow(id: id, title: title, minimized: minimized,
                          fullScreen: nil, frame: frame, thumbnail: nil, element: nil)
    }

    @Test("on-screen windows lead in z-order, AX leftovers follow by app recency")
    func ordering() {
        let rows = [
            row(pid: 1, wid: 10, title: "Front", x: 100, y: 100),
            row(pid: 2, wid: 20, title: "Second", x: 200, y: 200),
        ]
        let windows: [pid_t: [DockPreviewWindow]] = [
            1: [window(id: 0, title: "Front", frame: CGRect(x: 100, y: 100, width: 800, height: 600)),
                window(id: 1, title: "Minimized", minimized: true)],
            2: [window(id: 0, title: "Second", frame: CGRect(x: 200, y: 200, width: 800, height: 600))],
        ]
        let items = DockSwitcherList.order(
            rows: rows,
            windowsForApp: { windows[$0] ?? [] },
            appName: { "App\($0)" },
            icon: { _ in nil })
        #expect(items.map(\.title) == ["Front", "Second", "Minimized"])
        #expect(items[2].minimized && !items[2].onScreen)
        // The AX match carries the element for the raise.
        #expect(items[0].element == nil && items[0].windowID == 10)
    }

    @Test("a CGWindow with no AX twin still lists — with the CG title")
    func unmatchedRow() {
        let rows = [row(pid: 7, wid: 42, title: "AX-less")]
        let items = DockSwitcherList.order(
            rows: rows, windowsForApp: { _ in [] },
            appName: { _ in "Ghost" }, icon: { _ in nil })
        #expect(items.count == 1)
        #expect(items[0].title == "AX-less")
        #expect(items[0].element == nil)
    }

    @Test("frame matches before title — two same-named windows split by geometry")
    func frameFirst() {
        let rows = [row(pid: 3, wid: 30, title: "Doc", x: 50, y: 50)]
        let windows: [pid_t: [DockPreviewWindow]] = [
            3: [window(id: 0, title: "Doc", frame: CGRect(x: 900, y: 900, width: 800, height: 600)),
                window(id: 1, title: "Doc", frame: CGRect(x: 50, y: 50, width: 800, height: 600))],
        ]
        let items = DockSwitcherList.order(
            rows: rows, windowsForApp: { windows[$0] ?? [] },
            appName: { _ in "Editor" }, icon: { _ in nil })
        // The frame-matched twin took the on-screen slot; the other
        // window follows in the AX leftover run.
        #expect(items.map(\.title) == ["Doc", "Doc"])
        #expect(items[1].onScreen == false)
    }

    @Test("an all-minimized app still fetches its AX pool — leftover windows list and the row takes the element's truth")
    func offScreenOnlyFetch() {
        // Nothing on-screen for pid 9: the only row is a minimized one.
        // The unmatched pool must be fetched here or every row lands
        // elementless and commit can only activate, never restore.
        let items = DockSwitcherList.order(
            rows: [],
            offRows: [row(pid: 9, wid: 90, title: "Doc")],
            windowsForApp: { _ in
                [window(id: 0, title: "Doc"),          // the row's twin — AX says not minimized
                 window(id: 1, title: "Second")]       // unmatched — must still list
            },
            appName: { _ in "Editor" }, icon: { _ in nil })
        #expect(items.count == 2)
        // The hit's `minimized` wins over the row's assumed true.
        #expect(items[0].title == "Doc" && items[0].minimized == false)
        #expect(items[1].title == "Second" && items[1].onScreen == false)
    }

    @Test("the pick starts on the second window — back to what I was in")
    func initialSelection() {
        var model = SwitcherModel()
        model.open(with: (0..<3).map {
            SwitcherItem(id: "i\($0)", pid: 1, appName: "A", icon: nil,
                         title: "W\($0)", minimized: false, onScreen: true,
                         element: nil, windowID: nil)
        })
        #expect(model.selection == 1)
        model.open(with: [SwitcherItem(id: "only", pid: 1, appName: "A", icon: nil,
                                     title: "W", minimized: false, onScreen: true,
                                     element: nil, windowID: nil)])
        #expect(model.selection == 0)
    }

    @Test("Tab walks forward, ⇧Tab back, both wrap")
    func wrapAround() {
        var model = SwitcherModel()
        model.open(with: (0..<4).map {
            SwitcherItem(id: "i\($0)", pid: 1, appName: "A", icon: nil,
                         title: "W\($0)", minimized: false, onScreen: true,
                         element: nil, windowID: nil)
        })
        #expect(model.selection == 1)
        model.advance(by: 3)
        #expect(model.selection == 0)
        model.advance(by: 1)
        #expect(model.selection == 1)
        model.advance(by: -2)
        #expect(model.selection == 3)
        // A click lands the selection where the pointer said.
        model.select(index: 2)
        #expect(model.selected?.title == "W2")
        model.select(index: 99)
        #expect(model.selection == 2)
    }

    private func named(_ app: String, _ title: String) -> SwitcherItem {
        SwitcherItem(id: "\(app)-\(title)", pid: 1, appName: app, icon: nil,
                     title: title, minimized: false, onScreen: true,
                     element: nil, windowID: nil)
    }

    @Test("typing narrows the strip to matching windows and apps")
    func typeAhead() {
        var model = SwitcherModel()
        model.open(with: [named("Safari", "Inbox"), named("Terminal", "zsh"),
                          named("Safari", "Docs")])
        model.type("s")
        model.type("a")
        #expect(model.query == "sa")
        #expect(model.items.map(\.appName) == ["Safari", "Safari"])
        model.backspace()
        #expect(model.items.count == 3)
        // The window title matches too — "zsh" lands Terminal.
        model.backspace()
        model.type("z")
        #expect(model.items.map(\.title) == ["zsh"])
        // An empty filter shows everything again.
        model.backspace()
        #expect(model.items.count == 3)
    }

    @Test("the selection keeps its row when the row still matches")
    func filterKeepsSelection() {
        var model = SwitcherModel()
        model.open(with: [named("Safari", "Inbox"), named("Terminal", "zsh"),
                          named("Safari", "Docs")])
        model.select(index: 2)
        model.type("s")
        #expect(model.selected?.title == "Docs")
        // The picked row filtered out — the selection clamps in range.
        model.type("z")
        #expect(model.selected == nil)
    }

    @Test("type-ahead is a subsequence, not a substring — Witch's fuzzy")
    func fuzzyTypeAhead() {
        var model = SwitcherModel()
        model.open(with: [named("Safari", "Inbox"), named("Terminal", "zsh"),
                          named("Safari", "Docs"), named("Finder", "Files")])
        // "sfr" is inside "Safari" in order but never contiguous.
        model.type("s"); model.type("f"); model.type("r")
        #expect(model.items.map(\.appName) == ["Safari", "Safari"])
        // A window title fuzzies the same way — "zsh" answers "zs".
        var again = SwitcherModel()
        again.open(with: [named("Safari", "Inbox"), named("Terminal", "zsh")])
        again.type("z"); again.type("s")
        #expect(again.items.map(\.title) == ["zsh"])
    }

    @Test("the unfiltered list survives the query — stills stay attached")
    func allItemsUnderFilter() {
        var model = SwitcherModel()
        model.open(with: [named("Safari", "Inbox"), named("Terminal", "zsh")])
        model.type("z")
        #expect(model.items.count == 1)
        #expect(model.allItems.count == 2)
    }

    @Test("a verb's refresh keeps the row that survived and clamps when it left")
    func refreshKeepsSelection() {
        var model = SwitcherModel()
        model.open(with: [named("Safari", "Inbox"), named("Terminal", "zsh"),
                          named("Safari", "Docs")])
        model.select(index: 2)
        // The rebuild re-ordered but "Docs" survived — selection follows it.
        model.refresh(with: [named("Terminal", "zsh"), named("Safari", "Docs")])
        #expect(model.selected?.title == "Docs")
        // The picked row closed — the selection clamps in range.
        model.refresh(with: [named("Terminal", "zsh")])
        #expect(model.selected?.title == "zsh")
        // The query still filters a refresh — type-ahead and verbs compose.
        model.type("z")
        model.refresh(with: [named("Terminal", "zsh"), named("Safari", "Docs")])
        #expect(model.items.map(\.appName) == ["Terminal"])
        #expect(model.allItems.count == 2)
    }

    @Test("a typed query ranks best-first — a title hit beats an app-only one")
    func rankedFiltering() {
        var model = SwitcherModel()
        // "notes": every app carries it in the name, but only the
        // second row's *title* spells it — the title hit outranks.
        model.open(with: [named("Notes", "groceries"), named("Noter", "notes"),
                          named("Annotate", "scratch")])
        for ch in ["n", "o", "t", "e"] { model.type(ch) }
        #expect(model.items.first?.title == "notes",
                "the exact title beats the fuzzy app names")
        // Ties keep recency — equal-scored rows never reshuffle.
        var tied = SwitcherModel()
        tied.open(with: [named("Safari", "Inbox"), named("Safari", "Docs")])
        tied.type("s")
        #expect(tied.items.map(\.title) == ["Inbox", "Docs"])
    }

    @Test("the ranked order survives a refresh — recency tie-break uses the new list")
    func rankedRefresh() {
        var model = SwitcherModel()
        model.open(with: [named("Alpha", "memo"), named("Beta", "room")])
        model.type("m")
        // "m" hits "memo" (title, prefix bonus) and "room" (title at
        // index 2 — weaker). memo leads.
        #expect(model.items.first?.title == "memo")
        // The rebuild puts "room" first in recency — but the rank
        // still puts memo's stronger match ahead.
        model.refresh(with: [named("Beta", "room"), named("Alpha", "memo")])
        #expect(model.items.first?.title == "memo")
        #expect(model.items.count == 2)
    }

    // MARK: Minimized-window tiles

    @Test("a minimized tile's owner needs a sole claimant — no guessing")
    func minimizedOwner() {
        let rows = [
            row(pid: 1, wid: 10, title: "Doc"),
            row(pid: 2, wid: 20, title: "Doc"),
            row(pid: 3, wid: 30, title: "Solo"),
        ]
        #expect(DockSwitcherList.minimizedOwnerPID(title: "Doc", rows: rows) == nil,
                "two apps claim the title — the tile stays tile-backed")
        #expect(DockSwitcherList.minimizedOwnerPID(title: "Solo", rows: rows) == 3)
        #expect(DockSwitcherList.minimizedOwnerPID(title: "Gone", rows: rows) == nil)
        // Two same-titled windows of ONE app still resolve the owner —
        // the AX match downstream picks between them.
        let sameApp = [row(pid: 4, wid: 40, title: "Doc"),
                       row(pid: 4, wid: 41, title: "Doc")]
        #expect(DockSwitcherList.minimizedOwnerPID(title: "Doc", rows: sameApp) == 4)
    }

    // MARK: The preview key surface

    /// nil from `handle` is an eaten event; a returned event passed.
    private func passes(_ tap: SwitcherKeyTap, _ event: CGEvent) -> Bool {
        tap.handle(type: .keyDown, event: event)?.takeRetainedValue() != nil
    }

    @Test("the preview's keys are the tap's while its panel floats")
    func previewKeyRouting() throws {
        let tap = SwitcherKeyTap()
        let arrow = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 124, keyDown: true))
        // No flag set: the arrow passes through to the front app.
        #expect(passes(tap, arrow))
        tap.setPreviewOpen(true)
        #expect(!passes(tap, arrow),
                "the panel can't take key status — the tap eats its arrows")
        let esc = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true))
        let enter = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: true))
        #expect(!passes(tap, esc) && !passes(tap, enter))
        // A letter still passes — the preview owns only its keys.
        let a = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))
        #expect(passes(tap, a))
        tap.setPreviewOpen(false)
        #expect(passes(tap, arrow), "closing the panel hands the keys back")
    }

    @Test("only this display keeps the windows centred on it — minimized and frameless rows stay")
    func displayFilter() {
        func item(_ id: String, x: CGFloat?, minimized: Bool = false) -> SwitcherItem {
            SwitcherItem(id: id, pid: 1, appName: "A", icon: nil, title: id,
                         minimized: minimized, onScreen: !minimized, element: nil, windowID: nil,
                         frame: x.map { CGRect(x: $0, y: 100, width: 400, height: 300) })
        }
        let left = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let kept = DockSwitcherList.onDisplay([
            item("here", x: 100), item("there", x: 2000), item("parked", x: 2000, minimized: true),
            item("unknown", x: nil), item("straddle", x: 1300),
        ], display: left)
        #expect(kept.map(\.id) == ["here", "parked", "unknown"],
                "a window mostly on the next screen belongs to that screen")
        let windows = [
            DockPreviewWindow(id: 1, title: "a", minimized: false, fullScreen: nil,
                              frame: CGRect(x: 10, y: 10, width: 100, height: 100), thumbnail: nil, element: nil),
            DockPreviewWindow(id: 2, title: "b", minimized: false, fullScreen: nil,
                              frame: CGRect(x: 2000, y: 10, width: 100, height: 100), thumbnail: nil, element: nil),
            DockPreviewWindow(id: 3, title: "c", minimized: true, fullScreen: nil,
                              frame: CGRect(x: 2000, y: 10, width: 100, height: 100), thumbnail: nil, element: nil),
        ]
        #expect(DockEnhanceMath.onDisplay(windows, display: left).map(\.id) == [1, 3])
    }

    @Test("the live strip rebuilds on window and agent changes, not retitles")
    func liveSignature() {
        let rows = [row(pid: 1, wid: 10, title: "⠂ Claude"), row(pid: 2, wid: 20)]
        let before = DockSwitcherList.signature(rows: rows, offRows: [], marks: [])
        let retitled = DockSwitcherList.signature(
            rows: [row(pid: 1, wid: 10, title: "⠐ Claude"), row(pid: 2, wid: 20)], offRows: [], marks: [])
        #expect(before == retitled, "a terminal's spinner must not rebuild the strip every frame")
        let opened = DockSwitcherList.signature(rows: rows + [row(pid: 1, wid: 11)], offRows: [], marks: [])
        #expect(before != opened, "a new window re-lists")
        let minimized = DockSwitcherList.signature(rows: [row(pid: 2, wid: 20)],
                                                   offRows: [row(pid: 1, wid: 10)], marks: [])
        #expect(before == minimized, "a window moving off-screen is the same window")
    }

    @Test("` under the open strip is the scope toggle, not a typed character")
    func scopeKey() throws {
        let tap = SwitcherKeyTap()
        let grave = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 50, keyDown: true))
        #expect(passes(tap, grave), "closed: ` types as usual")
        tap.setOpen(true)
        #expect(!passes(tap, grave))
        tap.setOpen(false)
    }

    @Test("stills capture the selected card first, then the strip in order")
    func captureOrder() {
        let items = ["a", "b", "c", "d"].map { named("App", $0) }
        #expect(DockSwitcherThumbs.captureOrder(items, selectedID: "App-c").map(\.title) == ["c", "a", "b", "d"])
        #expect(DockSwitcherThumbs.captureOrder(items, selectedID: nil).map(\.title) == ["a", "b", "c", "d"])
        #expect(DockSwitcherThumbs.captureOrder(items, selectedID: "gone").map(\.title) == ["a", "b", "c", "d"])
    }

    @MainActor
    @Test("the strip joins fullscreen spaces like the preview panel")
    func stripIsFullScreenAuxiliary() {
        let panel = DockSwitcherPanel(controller: DockSwitcherController())
        #expect(panel.collectionBehavior.contains(.fullScreenAuxiliary),
                "without it the switcher can't surface over a fullscreen space")
        panel.close()
    }
}
