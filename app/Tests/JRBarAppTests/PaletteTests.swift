import AppKit
import Carbon
import Foundation
import SwiftUI
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

    @Test("favorites sit under Needs You in pin order, listed once, and win a query tie")
    func homeFavorites() {
        let items = [
            row("m1", "Mail"), row("q1", "Quiet for 1 Hour", section: .quiet),
            row("s1", "Slack"), row("a1", "fix-ci", section: .needsYou, urgent: true),
        ]
        var usage = PaletteUsage()
        usage.toggleFavorite("s1")
        usage.toggleFavorite("gone")
        usage.toggleFavorite("q1")
        usage.record("q1", at: now)
        let sections = PaletteRanking.home(items, usage: usage, now: now)
        #expect(sections.map(\.section) == [.needsYou, .favorites, .menuBar])
        #expect(sections[1].items.map(\.id) == ["s1", "q1"], "pin order, not frecency")
        #expect(sections[2].items.map(\.id) == ["m1"])
        let tie = [row("a", "Slack"), row("b", "Slack")]
        var pinned = PaletteUsage()
        pinned.toggleFavorite("b")
        #expect(PaletteRanking.rank(tie, query: "sl", usage: pinned, now: now).first?.id == "b")
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

    // MARK: Folded ranking — parity with the unfolded matcher

    /// The matcher as it read before folding: every field lowercased and
    /// copied per call. The folded one must score exactly the same.
    private static func unfoldedScore(_ query: String, _ candidate: String) -> Int? {
        let qs = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !qs.isEmpty else { return 0 }
        let cs = Array(candidate.lowercased())
        var qi = 0
        var total = 0
        var lastMatch = -2
        var streak = 0
        for (i, ch) in cs.enumerated() where qi < qs.count {
            guard ch == qs[qi] else { continue }
            var pts = 2
            if i == lastMatch + 1 {
                streak += 1
                pts += 4 * streak
            } else {
                streak = 0
            }
            if i == 0 || [" ", "·", "-", "/", ":"].contains(cs[i - 1]) {
                pts += 8
            }
            if qi == 0 && i == 0 { pts += 10 }
            total += pts
            lastMatch = i
            qi += 1
        }
        guard qi == qs.count else { return nil }
        return total - cs.count / 4
    }

    private static func unfoldedMatch(_ item: PaletteItem, query: String) -> PaletteRanking.Match? {
        let floor = 3 * query.filter { !$0.isWhitespace }.count
        var best: PaletteRanking.Match?
        func consider(_ value: Int?, verb: String? = nil) {
            guard let value, value >= floor else { return }
            if value > (best?.score ?? .min) { best = PaletteRanking.Match(score: value, verbID: verb) }
        }
        consider(unfoldedScore(query, item.title))
        for action in item.actions where unfoldedScore(query, action.title) == nil {
            consider(unfoldedScore(query, "\(action.title) \(item.title)").map { $0 - 1 }, verb: action.id)
        }
        for keyword in item.keywords { consider(unfoldedScore(query, keyword).map { $0 * 4 / 5 }) }
        if let subtitle = item.subtitle { consider(unfoldedScore(query, subtitle).map { $0 / 2 }) }
        consider(unfoldedScore(query, item.kind).map { $0 / 2 })
        return best
    }

    /// A seeded generator, so a failing row can be replayed.
    private struct SplitMix: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    @Test("folded ranking scores every random row exactly as the unfolded matcher did")
    func foldedParity() {
        // Plain letters and digits, the word breaks, capitals, accents
        // precomposed and combining, a German ß, emoji with a skin tone
        // and a flag — every kind of character a menu title carries.
        let alphabet: [String] = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLM0123456789").map(String.init)
            + [" ", " ", "·", "-", "/", ":", "é", "e\u{301}", "É", "ü", "ß", "İ", "👍🏽", "🇸🇪", "Å", "\u{212B}"]
        var rng = SplitMix(state: 0x5EED)
        func text(_ range: ClosedRange<Int>) -> String {
            (0..<Int.random(in: range, using: &rng)).map { _ in alphabet.randomElement(using: &rng)! }.joined()
        }
        var rows: [PaletteItem] = []
        for index in 0..<300 {
            let verbs = (0..<Int.random(in: 0...3, using: &rng)).map { _ in text(2...8) }
            let keywords = (0..<Int.random(in: 0...3, using: &rng)).map { _ in text(3...10) }
            let subtitle = Bool.random(using: &rng) ? text(4...24) : nil
            rows.append(row("r\(index)", text(1...20), subtitle: subtitle, keywords: keywords, verbs: verbs))
        }
        var matched = 0
        for _ in 0..<200 {
            let query = text(1...5)
            let folded = PaletteRanking.FoldedQuery(query)
            for item in rows {
                let old = Self.unfoldedMatch(item, query: query)
                #expect(PaletteRanking.match(PaletteRanking.FoldedItem(item), query: folded) == old,
                        "row \(item.id), query \(query)")
                if old != nil { matched += 1 }
            }
            #expect(MenuBarCommands.score(query, rows[0].title) == Self.unfoldedScore(query, rows[0].title))
        }
        #expect(matched > 100, "the sample reaches the scoring, not only misses")
        let ranked = PaletteRanking.arrange(rows, folded: rows.map(PaletteRanking.FoldedItem.init),
                                            query: "ab", usage: PaletteUsage(), now: now)
        #expect(ranked.flatMap(\.items).map(\.id)
                == PaletteRanking.arrange(rows, query: "ab", usage: PaletteUsage(), now: now)
                    .flatMap(\.items).map(\.id))
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
        #expect(controller.handle(.chord(.command("h"))),
                "an unclaimed ⌘ chord stays in the palette — ⌘H must not hide JR-Bar's windows")
        #expect(!controller.handle(.chord(PaletteShortcut(.character("a"), .control))),
                "⌃A is the field's: line start")
        #expect(!controller.handle(.chord(.command(","))), "⌘, goes on to Settings")
        #expect(!controller.handle(.chord(.command("o"))), "⌘O goes on to JR-Bar's own Overview")
        #expect(controller.handle(.down))
        #expect(controller.handle(.submit))
        #expect(log.ran == ["m:Open", "m:Hide", "m:Always Hide", "s:Open"])
        #expect(recorded.ran == ["m", "m", "m", "s"])
    }

    @Test("a slower source's hit runs but is never recorded — its id carries another app's words")
    func controllerSearchHitUnrecorded() {
        let log = Log()
        let controller = PaletteController()
        let recorded = Log()
        controller.recordUse = { recorded.ran.append($0) }
        controller.model.load(items: [row("open.history", "History", log: log)],
                              usage: PaletteUsage(), now: now)
        controller.model.query = "hist"
        let menu = PaletteSection(id: "appMenu", title: "Safari", order: 95)
        let page = "menu.com.apple.Safari.History/A Private Page Title"
        controller.model.setSearchResults([row(page, "A Private Page Title", section: menu, log: log),
                                           row("archive.7", "history notes", section: .archive, log: log)],
                                          for: "hist")
        controller.run(rowID: page, actionID: "open")
        controller.run(rowID: "archive.7", actionID: "open")
        #expect(log.ran == ["\(page):Open", "archive.7:Open"], "the hits still run")
        #expect(recorded.ran.isEmpty, "no ranking reads them, so nothing is written")
        controller.run(rowID: "open.history", actionID: "open")
        #expect(recorded.ran == ["open.history"], "a gathered row is still a habit")
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

    /// A frecency table a test can pin into.
    @MainActor
    final class Table {
        var usage = PaletteUsage()
    }

    @Test("⌘⇧P pins a row to Favorites with the palette still up, and unpins it")
    func controllerFavorites() {
        let table = Table()
        let log = Log()
        let controller = PaletteController()
        controller.presentsWindow = false
        controller.usage = { table.usage }
        controller.toggleFavorite = { table.usage.toggleFavorite($0) }
        controller.recordUse = { log.ran.append("use:\($0)") }
        controller.sources = {
            [PaletteClosureSource(build: {
                [PaletteItem(id: "scene.focus", title: "Focus Scene", icon: .symbol("circle", .gray),
                             kind: "Scene", section: .lights,
                             actions: [PaletteAction(id: "switch", title: "Switch Scene", symbol: "circle") {
                                 log.ran.append("switch")
                                 return nil
                             }]),
                 PaletteItem(id: "session.x", title: "fix-ci", icon: .symbol("circle", .gray),
                             kind: "Session", section: .sessions, actions: [])]
            })]
        }
        controller.open()
        defer { controller.close() }
        let scene = controller.model.rows.first { $0.id == "scene.focus" }
        #expect(scene?.actions.last?.title == "Add to Favorites")
        #expect(controller.model.rows.first { $0.id == "session.x" }?.actions.isEmpty == true,
                "a session comes and goes — no pin")
        controller.model.select(id: "scene.focus")
        #expect(controller.handle(.chord(PaletteController.favoriteChord)))
        #expect(controller.isOpen, "pinning keeps the palette up")
        #expect(table.usage.favorites == ["scene.focus"])
        #expect(controller.model.sections.first?.section == .favorites)
        #expect(controller.model.selectedID == "scene.focus", "the highlight follows the row")
        #expect(controller.model.selected?.actions.last?.title == "Remove from Favorites")
        #expect(log.ran.isEmpty, "a pin is not a run")
        controller.handle(.chord(PaletteController.favoriteChord))
        #expect(table.usage.favorites.isEmpty)
        #expect(controller.model.sections.first?.section != .favorites)
    }

    /// A row whose second verb takes words, logging each stage.
    private func replyRow(_ log: Log, draft: String = "") -> PaletteItem {
        PaletteItem(
            id: "ask.x", title: "fix-ci", subtitle: "Which branch?", icon: .symbol("circle", .gray),
            kind: "Ask", section: .needsYou,
            actions: [
                PaletteAction(id: "open", title: "Open Session", symbol: "circle") {
                    log.ran.append("open")
                    return nil
                },
                PaletteAction(id: "reply", title: "Reply…", symbol: "circle", shortcut: .secondary,
                              input: PaletteInput(
                                prompt: "Reply to fix-ci…", submitTitle: "Send Reply",
                                initial: { draft },
                                onChange: { log.ran.append("draft:\($0)") },
                                submit: { log.ran.append("send:\($0)"); return nil })),
            ],
            urgent: true)
    }

    @Test("a verb that takes words opens its field: typing keeps a draft, ⎋ backs out, Return sends and folds")
    func controllerInput() {
        let log = Log()
        let recorded = Log()
        let controller = PaletteController()
        controller.presentsWindow = false
        controller.recordUse = { recorded.ran.append($0) }
        controller.sources = { [PaletteClosureSource(build: { [self.replyRow(log, draft: "ma")] })] }
        controller.open()
        defer { controller.close() }
        controller.model.query = "fix"
        #expect(controller.handle(.chord(.secondary)))
        #expect(controller.isOpen, "the field opens in the palette")
        #expect(controller.model.inputActive)
        #expect(controller.model.inputText == "ma", "the draft comes back")
        #expect(controller.model.inputItem?.id == "ask.x")
        #expect(controller.model.query == "fix", "the query waits for ⎋")
        #expect(log.ran.isEmpty && recorded.ran.isEmpty, "opening the field runs nothing")
        // The list holds still and ⌘K has nothing to add.
        #expect(controller.handle(.down))
        #expect(controller.handle(.chord(.actionPanel)))
        #expect(!controller.model.actionsOpen)
        #expect(!controller.handle(.passThrough), "letters are the field's")
        controller.model.inputText = "main"
        controller.inputChanged()
        #expect(log.ran == ["draft:main"])
        // ⎋ backs out to the list, the query as it was.
        controller.handle(.cancel)
        #expect(!controller.model.inputActive)
        #expect(controller.isOpen)
        #expect(controller.model.query == "fix")
        // Blank words send nothing; real ones send once, and fold.
        controller.handle(.chord(.secondary))
        controller.model.inputText = "   "
        controller.handle(.submit)
        #expect(controller.isOpen)
        #expect(!log.ran.contains { $0.hasPrefix("send:") })
        controller.model.inputText = "  main please "
        controller.handle(.submit)
        #expect(!controller.isOpen)
        #expect(!controller.model.inputActive)
        #expect(log.ran.last == "send:main please")
        #expect(recorded.ran == ["ask.x"], "the send is the row's use")
    }

    @Test("words the verb refuses keep the field open and send nothing")
    func controllerInputRefused() {
        let log = Log()
        let controller = PaletteController()
        controller.presentsWindow = false
        controller.sources = {
            [PaletteClosureSource(build: {
                [PaletteItem(id: "menubar.profile.save", title: "Save Layout as Profile…",
                             icon: .symbol("circle", .gray), kind: "Profile", section: .automation,
                             actions: [PaletteAction(id: "save", title: "Save as Profile…", symbol: "circle",
                                                     input: PaletteInput(
                                                        prompt: "Name this layout…", submitTitle: "Save Profile",
                                                        accepts: { $0.lowercased() != "none" },
                                                        submit: { log.ran.append("save:\($0)"); return nil }))])]
            })]
        }
        controller.open()
        defer { controller.close() }
        controller.handle(.submit)
        #expect(controller.model.inputActive, "Return on the row opens its field")
        controller.model.inputText = "None"
        controller.handle(.submit)
        #expect(controller.isOpen && controller.model.inputActive)
        #expect(log.ran.isEmpty)
        controller.model.inputText = "Travel"
        controller.handle(.submit)
        #expect(!controller.isOpen)
        #expect(log.ran == ["save:Travel"])
    }

    @Test("the field closes when its row goes away — an ask answered in its own window")
    func controllerInputRowGone() async {
        let fact = PaletteSourcesTests.Fact()
        fact.asks = 1
        let log = Log()
        let controller = PaletteController()
        controller.presentsWindow = false
        controller.sources = {
            [PaletteClosureSource(build: { fact.asks > 0 ? [self.replyRow(log)] : [] })]
        }
        controller.open()
        defer { controller.close() }
        controller.model.select(id: "ask.x")
        controller.handle(.chord(.secondary))
        #expect(controller.model.inputActive)
        // A click on the context row is not a button while the field is open.
        controller.activate(rowID: "ask.x")
        #expect(log.ran.isEmpty)
        fact.asks = 0
        for _ in 0..<200 where controller.model.inputActive { await Task.yield() }
        #expect(!controller.model.inputActive)
        controller.handle(.submit)
        #expect(!log.ran.contains { $0.hasPrefix("send:") })
    }

    @Test("Reset Ranking drops a row's habit with the palette still up; a row with none has no such verb")
    func controllerResetRanking() {
        let table = Table()
        table.usage.record("scene.focus", at: Date())
        let controller = PaletteController()
        controller.presentsWindow = false
        controller.usage = { table.usage }
        controller.forgetUse = { table.usage.forget($0) }
        controller.sources = {
            [PaletteClosureSource(build: {
                ["scene.focus", "scene.calm"].map { id in
                    PaletteItem(id: id, title: id, icon: .symbol("circle", .gray), kind: "Scene",
                                section: .lights,
                                actions: [PaletteAction(id: "switch", title: "Switch", symbol: "circle") { nil }])
                }
            })]
        }
        controller.open()
        defer { controller.close() }
        #expect(controller.model.sections.first?.section == .suggestions)
        #expect(controller.model.rows.first { $0.id == "scene.calm" }?.actions.map(\.id) == ["switch"])
        controller.run(rowID: "scene.focus", actionID: "palette.resetRanking")
        #expect(controller.isOpen, "a reset keeps the palette up")
        #expect(table.usage.score(for: "scene.focus") == 0)
        #expect(!controller.model.sections.contains { $0.section == .suggestions })
        #expect(controller.model.rows.first { $0.id == "scene.focus" }?.actions.map(\.id) == ["switch"])
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

    // MARK: The panel

    @Test("the panel joins every Space without also asking to move to the active one")
    func panelBehavior() {
        let behavior = PalettePanel.behavior
        #expect(!(behavior.contains(.canJoinAllSpaces) && behavior.contains(.moveToActiveSpace)),
                "AppKit throws on the pair, and the palette never opens")
        #expect(behavior.contains(.fullScreenAuxiliary), "it opens over a full-screen app too")
        let panel = PalettePanel(content: EmptyView())
        #expect(panel.collectionBehavior == behavior)
        #expect(!panel.isVisible, "building the panel puts nothing on screen")
        panel.close()
    }

    @Test("headless, the session counts as open once its rows are in")
    func headlessOpen() {
        let controller = PaletteController()
        controller.presentsWindow = false
        controller.sources = { [PaletteClosureSource(build: { [self.row("a", "Alpha")] })] }
        controller.open()
        #expect(controller.isOpen)
        #expect(controller.model.rows.map(\.id) == ["a"])
        controller.close()
        #expect(!controller.isOpen)
    }
}
