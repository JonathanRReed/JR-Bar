import AppKit
import Carbon
import Foundation
import Testing
@testable import JRBarApp
@testable import JRBarCore

/// The ⌘⇧K palette's pure halves: the home list and the query ranking
/// (frecency, verb phrases, the scattered-letter floor), the model's
/// selection and action-panel rules, the key map, and the controller's
/// key routing against a recording row — no window is ever opened.
@Suite("Palette")
@MainActor
struct PaletteTests {
    /// Records which verbs ran.
    @MainActor
    final class Log {
        var ran: [String] = []
    }

    private func row(_ id: String, _ title: String, section: PaletteSection = .menuBar,
                     subtitle: String? = nil, keywords: [String] = [], urgent: Bool = false,
                     verbs: [String] = ["Open"], log: Log? = nil,
                     shortcuts: [String: PaletteShortcut] = [:], opensActions: Bool = false) -> PaletteItem {
        PaletteItem(
            id: id, title: title, subtitle: subtitle, keywords: keywords,
            icon: .symbol("circle", .gray), kind: "Test", section: section,
            actions: verbs.map { verb in
                PaletteAction(id: verb.lowercased(), title: verb, symbol: "circle",
                              shortcut: shortcuts[verb]) { [weak log] in
                    log?.ran.append("\(id):\(verb)")
                    return nil
                }
            },
            urgent: urgent, opensActions: opensActions)
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: Home list

    @Test("home: asks first, then Suggestions from frecency, then sections in their order")
    func homeOrder() {
        let items = [
            row("m1", "Mail", section: .menuBar),
            row("q1", "Quiet for 1 Hour", section: .quiet),
            row("s1", "fix-ci", section: .sessions),
            row("a1", "fix-ci needs you", section: .needsYou, urgent: true),
            row("m2", "Slack", section: .menuBar),
        ]
        var usage = PaletteUsage()
        usage.record("q1", at: now)
        usage.record("q1", at: now)
        usage.record("m2", at: now)
        usage.record("gone", at: now)           // not on offer: skipped, not a hole
        usage.record("a1", at: now)             // urgent rows stay under Needs You
        let sections = PaletteRanking.home(items, usage: usage, now: now)
        #expect(sections.map(\.section) == [.needsYou, .suggestions, .sessions, .menuBar])
        #expect(sections[0].items.map(\.id) == ["a1"])
        #expect(sections[1].items.map(\.id) == ["q1", "m2"], "strongest first")
        #expect(sections[3].items.map(\.id) == ["m1"], "a suggested row is listed once")
        #expect(!sections.contains { $0.section == .quiet }, "its only row moved to Suggestions")
    }

    @Test("home without history has no Suggestions section")
    func homeNoHistory() {
        let sections = PaletteRanking.home([row("m1", "Mail")], usage: PaletteUsage(), now: now)
        #expect(sections.map(\.section) == [.menuBar])
    }

    // MARK: Query ranking

    @Test("a title beats a subtitle, and bare scattered letters never match")
    func queryRanking() {
        let items = [
            row("sub", "Quiet for 1 Hour", subtitle: "Dark mode for the lights"),
            row("title", "Dark Mode"),
            row("scatter", "Dock Auto-Hide", subtitle: "Restarts the Dock"),
        ]
        let hits = PaletteRanking.rank(items, query: "dark", usage: PaletteUsage(), now: now)
        #expect(hits.map(\.id) == ["title", "sub"])
    }

    @Test("a keyword finds a row its title never names")
    func keywordMatch() {
        let items = [row("awake", "Keep Awake", keywords: ["caffeinate", "amphetamine"])]
        #expect(PaletteRanking.rank(items, query: "caff", usage: PaletteUsage(), now: now).count == 1)
    }

    @Test("frecency breaks a near-tie toward what you use, but never beats a clearly better match")
    func frecencyBoost() {
        let items = [row("a", "Slack"), row("b", "Slate")]
        var usage = PaletteUsage()
        for _ in 0..<5 { usage.record("b", at: now) }
        #expect(PaletteRanking.rank(items, query: "sla", usage: PaletteUsage(), now: now).first?.id == "a")
        #expect(PaletteRanking.rank(items, query: "sla", usage: usage, now: now).first?.id == "b")
        // "slack" matches Slate not at all — habit cannot invent a match.
        #expect(PaletteRanking.rank(items, query: "slack", usage: usage, now: now).map(\.id) == ["a"])
        #expect(PaletteRanking.boost(0) == 0)
        #expect(PaletteRanking.boost(1000) == PaletteRanking.frecencyCeiling)
    }

    @Test("an open ask wins a tie")
    func urgencyTie() {
        let items = [row("plain", "fix-ci"), row("ask", "fix-ci", urgent: true)]
        #expect(PaletteRanking.rank(items, query: "fix", usage: PaletteUsage(), now: now).first?.id == "ask")
    }

    @Test("a typed verb moves that verb to Return; the verb alone never does")
    func verbPromotion() {
        let item = row("s", "fix-ci", verbs: ["Open", "Approve", "Deny"])
        let deny = PaletteRanking.rank([item], query: "deny fix", usage: PaletteUsage(), now: now)
        #expect(deny.first?.primary?.title == "Deny")
        #expect(deny.first?.secondary?.title == "Open")
        // "d" alone is the start of Deny — it must not make Return deny.
        let bare = PaletteRanking.match(item, query: "d")
        #expect(bare?.verbID == nil)
        // A menu-only row runs a typed verb straight away.
        let menu = row("b", "Brightness", verbs: ["25%", "50%"], opensActions: true)
        let typed = PaletteRanking.promoting("50%", in: menu)
        #expect(typed.opensActions == false)
        #expect(typed.primary?.title == "50%")
    }

    @Test("the action panel filters its verbs by the same matcher")
    func actionFilter() {
        let item = row("x", "Mail", verbs: ["Open", "Hide", "Always Hide", "Show"])
        #expect(PaletteRanking.filterActions(item.actions, query: "").map(\.title)
                == ["Open", "Hide", "Always Hide", "Show"])
        #expect(PaletteRanking.filterActions(item.actions, query: "hid").map(\.title)
                == ["Hide", "Always Hide"])
    }

    // MARK: Shortcuts

    @Test("the first two verbs answer ↩ and ⌘↩; a verb's own chord wins")
    func rowShortcuts() {
        let item = row("x", "Mail", verbs: ["Open", "Hide", "Always Hide"],
                       shortcuts: ["Always Hide": .commandShift("h")])
        #expect(item.shortcut(for: item.actions[0]) == .primary)
        #expect(item.shortcut(for: item.actions[1]) == .secondary)
        #expect(item.shortcut(for: item.actions[2])?.display == "⇧⌘H")
        #expect(item.action(for: .commandShift("H"))?.title == "Always Hide", "the letter is case-free")
        #expect(PaletteShortcut.secondary.spoken == "Command Return")
        let menu = row("b", "Brightness", verbs: ["25%"], opensActions: true)
        #expect(menu.primary == nil)
        #expect(menu.shortcut(for: menu.actions[0]) == nil)
    }

    // MARK: Model

    @Test("the model resets the selection on a new query and walks with wrap")
    func modelSelection() {
        let model = PaletteModel()
        model.load(items: [row("a", "Alpha"), row("b", "Beta"), row("c", "Gamma")],
                   usage: PaletteUsage(), now: now)
        #expect(model.selectedID == "a")
        model.move(-1)
        #expect(model.selectedID == "c", "↑ from the top wraps")
        model.move(1)
        #expect(model.selectedID == "a")
        model.page(8)
        #expect(model.selectedID == "c", "paging clamps")
        model.query = "bet"
        #expect(model.rows.map(\.id) == ["b"])
        #expect(model.sections.map(\.section) == [.results])
        #expect(model.selectedID == "b")
        model.query = "zzz"
        #expect(model.rows.isEmpty)
        #expect(model.selectedID == nil)
    }

    @Test("a slower source's hits land under Archive, only for the query that asked")
    func modelSearchResults() {
        let model = PaletteModel()
        model.load(items: [row("a", "Alpha"), row("b", "Alphabet")], usage: PaletteUsage(), now: now)
        model.query = "alp"
        model.move(1)
        #expect(model.selectedID == "b")
        model.setSearchResults([row("archive.1", "alpine notes", section: .archive)], for: "alp")
        #expect(model.sections.map(\.section) == [.results, .archive])
        #expect(model.selectedID == "b", "a hit landing mid-arrow keeps the highlight")
        // An answer for an older query is dropped.
        model.setSearchResults([row("archive.2", "old", section: .archive)], for: "al")
        #expect(!model.rows.contains { $0.id == "archive.2" })
        // Typing on clears hits that no longer belong to the words.
        model.query = "alph"
        #expect(!model.rows.contains { $0.id == "archive.1" })
    }

    @Test("⌘K opens the selected row's panel; its filter and selection are its own")
    func modelActionPanel() {
        let model = PaletteModel()
        model.load(items: [row("m", "Mail", verbs: ["Open", "Hide", "Always Hide"])],
                   usage: PaletteUsage(), now: now)
        #expect(model.openActions())
        #expect(model.actionsOpen)
        model.moveAction(-1)
        #expect(model.selectedAction?.title == "Always Hide", "wraps")
        model.actionQuery = "hide"
        #expect(model.actionSelection == 0, "a new filter starts at the top")
        #expect(model.visibleActions.map(\.title) == ["Hide", "Always Hide"])
        model.query = "m"
        #expect(!model.actionsOpen, "typing in the main field folds the panel")
        let empty = PaletteModel()
        empty.load(items: [], usage: PaletteUsage(), now: now)
        #expect(!empty.openActions())
    }

    // MARK: Keys

    @Test("the key map: arrows, Emacs arrows, Return, ⎋, chords, and editing chords left alone")
    func keyMap() {
        func cmd(_ code: Int, _ chars: String?, _ flags: NSEvent.ModifierFlags = []) -> PaletteKeyCommand {
            PaletteKeys.command(keyCode: UInt16(code), characters: chars, modifiers: flags)
        }
        #expect(cmd(kVK_UpArrow, nil, [.numericPad, .function]) == .up)
        #expect(cmd(kVK_DownArrow, nil) == .down)
        #expect(cmd(kVK_ANSI_P, "p", .control) == .up)
        #expect(cmd(kVK_ANSI_N, "n", .control) == .down)
        #expect(cmd(kVK_Return, "\r") == .submit)
        #expect(cmd(kVK_ANSI_KeypadEnter, "\u{3}") == .submit)
        #expect(cmd(kVK_Return, "\r", .command) == .chord(.secondary))
        #expect(cmd(kVK_Escape, "\u{1b}") == .cancel)
        #expect(cmd(kVK_ANSI_K, "k", .command) == .chord(.actionPanel))
        #expect(cmd(kVK_ANSI_H, "H", [.command, .shift]) == .chord(.commandShift("h")))
        #expect(cmd(kVK_Delete, "\u{7f}", .command) == .chord(PaletteShortcut(.delete, .command)))
        #expect(cmd(kVK_Delete, "\u{7f}") == .passThrough, "plain ⌫ edits the query")
        #expect(cmd(kVK_ANSI_A, "a") == .passThrough)
        #expect(cmd(kVK_ANSI_A, "A", .shift) == .passThrough)
        #expect(cmd(kVK_ANSI_C, "c", .command) == .passThrough, "⌘C copies")
        #expect(cmd(kVK_ANSI_V, "v", .command) == .passThrough)
        #expect(cmd(kVK_LeftArrow, "\u{F702}", .command) == .passThrough, "⌘← moves the caret")
        #expect(cmd(kVK_UpArrow, "\u{F700}", .shift) == .passThrough)
    }

    // MARK: Controller key routing

    @Test("Return runs the first verb and records the row; ⌘↩ the second; a chord its own")
    func controllerRouting() {
        let log = Log()
        let controller = PaletteController()
        let recorded = Log()
        controller.recordUse = { recorded.ran.append($0) }
        controller.model.load(items: [
            row("m", "Mail", verbs: ["Open", "Hide", "Always Hide"], log: log,
                shortcuts: ["Always Hide": .commandShift("h")]),
            row("s", "Slack", log: log),
        ], usage: PaletteUsage(), now: now)
        #expect(controller.handle(.submit))
        #expect(controller.handle(.chord(.secondary)))
        #expect(controller.handle(.chord(.commandShift("h"))))
        #expect(!controller.handle(.chord(.command("j"))), "an unclaimed chord reaches the field")
        #expect(controller.handle(.down))
        #expect(controller.handle(.submit))
        #expect(log.ran == ["m:Open", "m:Hide", "m:Always Hide", "s:Open"])
        #expect(recorded.ran == ["m", "m", "m", "s"])
    }

    @Test("⌘K opens the panel, arrows walk it, Return runs its pick, ⎋ backs out")
    func controllerActionPanel() {
        let log = Log()
        let controller = PaletteController()
        controller.model.load(items: [row("m", "Mail", verbs: ["Open", "Hide", "Always Hide"], log: log)],
                              usage: PaletteUsage(), now: now)
        controller.handle(.chord(.actionPanel))
        #expect(controller.model.actionsOpen)
        controller.handle(.down)
        controller.handle(.down)
        controller.handle(.submit)
        #expect(log.ran == ["m:Always Hide"])
        controller.handle(.chord(.actionPanel))
        #expect(controller.model.actionsOpen)
        controller.handle(.cancel)
        #expect(!controller.model.actionsOpen, "⎋ closes the panel, not the palette")
    }

    @Test("a menu-only row opens its panel on Return instead of guessing a verb")
    func controllerMenuRow() {
        let log = Log()
        let controller = PaletteController()
        controller.model.load(items: [row("b", "Brightness", verbs: ["25%", "50%"], log: log,
                                          opensActions: true)],
                              usage: PaletteUsage(), now: now)
        controller.handle(.submit)
        #expect(controller.model.actionsOpen)
        #expect(log.ran.isEmpty)
    }

    @Test("⎋ clears the query first, and only then folds")
    func controllerEscape() {
        let controller = PaletteController()
        controller.model.load(items: [row("a", "Alpha")], usage: PaletteUsage(), now: now)
        controller.model.query = "al"
        controller.handle(.cancel)
        #expect(controller.model.query.isEmpty)
        #expect(controller.handle(.cancel), "the second ⎋ is still the palette's")
    }
}
