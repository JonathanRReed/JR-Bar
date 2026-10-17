import CoreGraphics
import Foundation
import Testing
@testable import JRBarApp
import JRBarCore

/// The list the bar's positions spell out, and the suggestions the old
/// saved list leaves behind. Under the divider the list is only a record;
/// it never hides anything.
@Suite("Menu Bar — the positional list and the suggestions")
struct MenuBarPositionalListTests {
    private func item(_ id: String, app: String?, x: Double, width: Double = 28,
                      overflow: Bool = false) -> MenuBarItem {
        var item = MenuBarItem(id: id, ownerPID: 100, ownerName: id,
                               bounds: CGRect(x: x, y: 4, width: width, height: 24),
                               title: nil, windowID: 1)
        item.bundleID = app
        item.isNativeOverflowControl = overflow
        return item
    }

    private func makePlan(shown: [MenuBarItem] = [], hidden: [MenuBarItem] = [],
                          always: [MenuBarItem] = []) -> MenuBarHidePlan {
        var plan = MenuBarHidePlan()
        plan.shown = shown
        plan.hidden = hidden
        plan.alwaysHidden = always
        return plan
    }

    @Test("the positional list names apps wholly left of the icon and keeps their section")
    func positionalList() {
        let plan = makePlan(shown: [item("s", app: "s.app", x: 1100)],
                            hidden: [item("h", app: "h.app", x: 900), item("n", app: nil, x: 920)],
                            always: [item("z", app: "z.app", x: 880)])
        let list = MenuBarUtility.positionalList(plan: plan)
        #expect(list == ["h.app": .hidden, "z.app": .alwaysHidden])
    }

    @Test("an app with an item still shown is not on the positional list")
    func splitApp() {
        let plan = makePlan(shown: [item("a2", app: "a.app", x: 1100)],
                            hidden: [item("a1", app: "a.app", x: 900)])
        #expect(MenuBarUtility.positionalList(plan: plan).isEmpty)
    }

    @Test("Apple's apps and the overflow control stay off the list")
    func notRecorded() {
        let plan = makePlan(hidden: [item("h", app: "com.apple.h", x: 900),
                                     item("«", app: "x.app", x: 880, overflow: true)])
        #expect(MenuBarUtility.positionalList(plan: plan).isEmpty)
    }

    // MARK: Suggestions

    @Test("a suggested app already left of the icon is done; one shown is the work; one off the bar waits")
    func suggestions() {
        let plan = makePlan(shown: [item("Shown", app: "shown.app", x: 1100)],
                            hidden: [item("Done", app: "done.app", x: 900)])
        let content = MenuBarSuggestionsContent.make(
            suggestions: ["done.app", "shown.app", "gone.app"], plan: plan) { $0.replacingOccurrences(of: ".app", with: "") }
        #expect(content.rows.map(\.id) == ["shown.app", "gone.app"])
        #expect(content.rows.map(\.state) == [.shown, .absent])
        #expect(content.lead == "2 apps were hidden by your old list. Nothing hides them now.")
    }

    @Test("an app with one item on each side is still the work to do")
    func splitSuggestion() {
        let plan = makePlan(shown: [item("a2", app: "a.app", x: 1100)],
                            hidden: [item("a1", app: "a.app", x: 900)])
        let content = MenuBarSuggestionsContent.make(suggestions: ["a.app"], plan: plan) { $0 }
        #expect(content.rows.map(\.state) == [.shown])
    }

    @Test("every suggestion done leaves nothing to show")
    func allDone() {
        let plan = makePlan(hidden: [item("h", app: "h.app", x: 900)])
        #expect(MenuBarSuggestionsContent.make(suggestions: ["h.app"], plan: plan) { $0 }.rows.isEmpty)
        #expect(MenuBarSuggestionsContent.make(suggestions: [], plan: plan) { $0 }.rows.isEmpty)
    }

    @Test("the words say what to do, and one app reads in the singular")
    func words() {
        #expect(MenuBarPositionCopy.hint == "Hold ⌘ and drag an app left of the JR-Bar icon to hide it")
        #expect(MenuBarPositionCopy.suggestionsLead(count: 1) == "1 app was hidden by your old list. Nothing hides it now.")
        #expect(MenuBarPositionCopy.suggestionLine(name: "Typeless", state: .shown)
                == "Typeless is shown. Hold ⌘ and drag it left of the icon to hide it.")
        #expect(MenuBarPositionCopy.suggestionLine(name: "Typeless", state: .absent)
                == "Typeless isn't on the bar right now.")
    }
}
