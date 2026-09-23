import Darwin
import Foundation
import Testing
@testable import JRBarApp
@testable import JRBarCore

/// Asks answered from every surface: the palette's ask rows, the panel's
/// guards and its Open fallback, the Rail's pill, History's Resume, the
/// Overview's New Session Here, the hook doctor's line, and "quiet while
/// watching" taking the daemon's tab-level word. Nothing here opens a
/// window, plays a sound or reaches a daemon.
@Suite("Ask surfaces")
@MainActor
struct AskSurfacesTests {
    @MainActor
    final class Log {
        var calls: [String] = []
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let single = CoreAskChoice(question: "Which database?", options: ["Postgres", "SQLite"])
    static let multi = CoreAskChoice(question: "Which checks?", header: "Checks", options: ["Lint", "Tests"], multi: true)

    private func row(_ id: String, ask: CoreAsk?, remote: Bool = false, mode: String = "waiting") -> SessionRow {
        SessionRow(session: CoreSession(id: id, provider: "claude", label: id, cwd: "/Users/me/src/\(id)",
                                        mode: mode, since: now.timeIntervalSince1970 - 60, ask: ask,
                                        remote: remote),
                   pinnedAsk: nil)
    }

    private func verbs(_ log: Log, picks: AskChoicePicks = AskChoicePicks()) -> AgentPaletteVerbs {
        var verbs = AgentPaletteVerbs(
            open: { log.calls.append("open:\($0.id)") },
            approve: { log.calls.append("approve:\($0.request ?? "")") },
            deny: { log.calls.append("deny:\($0.request ?? "")") },
            snooze: { _, _ in }, copyPath: { _ in }, reveal: { _ in }, dismiss: { _ in }, clear: { _ in })
        verbs.alwaysAllow = { log.calls.append("always:\($0.request ?? "")") }
        verbs.pick = { label, choice, _ in log.calls.append("pick:\(choice.question):\(label)") }
        verbs.picks = { _ in picks }
        verbs.sendPicks = { log.calls.append("send:\($0.request ?? "")") }
        return verbs
    }

    private func held(always: Bool = false, choices: [CoreAskChoice] = [], answerable: Bool = true,
                      preview: String? = nil, risk: String? = nil) -> CoreAsk {
        CoreAsk(session: "claude:s1", summary: "Bash", answerable: answerable, request: "r1",
                decision: CoreAskDecision(holdUntil: 2e9, always: always, choices: choices),
                preview: preview, risk: risk)
    }

    /// Polls until `done`, counting turns as well as seconds: the whole
    /// suite shares one main actor, and a loaded machine can stall it
    /// for longer than any clock budget — once it is free again the
    /// hops queued behind the stall still get their turns before this
    /// gives up. Each hop lands in a blink when nothing is in the way.
    static func waitFor(_ done: () -> Bool) async {
        let deadline = Date().addingTimeInterval(30)
        var turns = 0
        while !done(), turns < 300 || Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
            turns += 1
        }
    }

    // MARK: Palette

    @Test("Always Allow is its own verb in the action panel, on no chord, beside Approve and Deny")
    func paletteAlways() {
        let log = Log()
        let ask = held(always: true)
        let item = AgentPaletteRows.askItem(row: row("claude:s1", ask: ask), ask: ask, now: now, verbs: verbs(log))
        let always = item.actions.first { $0.id == "always" }
        #expect(always?.title == "Always Allow")
        #expect(always.map { item.shortcut(for: $0) } == .some(nil), "remembering a rule is never a keystroke")
        #expect(item.action(for: .secondary)?.id == "approve")
        _ = always?.run()
        #expect(log.calls == ["always:r1"])
        let once = held(always: false)
        #expect(!AgentPaletteRows.askItem(row: row("claude:s1", ask: once), ask: once, now: now, verbs: verbs(log))
            .actions.contains { $0.id == "always" })
    }

    @Test("a held question lists its options by name: no Approve, Deny on ⌘D, and ⌘↩ lands on no option")
    func paletteQuestion() {
        let log = Log()
        let ask = held(choices: [Self.single], answerable: false)
        let item = AgentPaletteRows.askItem(row: row("claude:s1", ask: ask), ask: ask, now: now, verbs: verbs(log))
        #expect(!item.actions.contains { $0.id == "approve" })
        #expect(item.action(for: .command("d"))?.id == "deny")
        #expect(item.action(for: .secondary) == nil, "an answer is always picked by name")
        #expect(item.actions.filter { $0.id.hasPrefix("answer.") }.map(\.title)
                == ["Answer “Postgres”", "Answer “SQLite”"])
        #expect(item.accessibilityNote == nil, "a question answers here whatever hosts it")
        _ = item.actions.first { $0.id == "answer.1" }?.run()
        #expect(log.calls == ["pick:Which database?:SQLite"])
    }

    @Test("several parts pick with the palette up, and Send Answers appears once each has one")
    func paletteMultiPart() {
        let log = Log()
        let ask = held(choices: [Self.single, Self.multi])
        let open = AgentPaletteRows.askItem(row: row("claude:s1", ask: ask), ask: ask, now: now, verbs: verbs(log))
        let picks = open.actions.filter { $0.id.hasPrefix("pick.") }
        #expect(picks.count == 4)
        let pickingKeepsOpen = picks.allSatisfy { $0.keepsOpen }
        #expect(pickingKeepsOpen, "a pick runs with the palette up")
        #expect(!open.actions.contains { $0.id == "sendAnswers" })
        var chosen = AskChoicePicks()
        chosen.toggle("SQLite", in: Self.single)
        chosen.toggle("Tests", in: Self.multi)
        let ready = AgentPaletteRows.askItem(row: row("claude:s1", ask: ask), ask: ask, now: now,
                                             verbs: verbs(log, picks: chosen))
        #expect(ready.actions.first { $0.id == "pick.1.1" }?.title == "Unpick “Tests” · Checks")
        let send = ready.actions.first { $0.id == "sendAnswers" }
        #expect(send?.keepsOpen == false)
        _ = send?.run()
        #expect(log.calls == ["send:r1"])
    }

    @Test("the row says what would run, is found by it, and marks a destructive command")
    func paletteRisk() {
        let log = Log()
        let ask = held(preview: "rm -rf build", risk: "destructive")
        let item = AgentPaletteRows.askItem(row: row("claude:s1", ask: ask), ask: ask, now: now, verbs: verbs(log))
        #expect(item.subtitle == "Bash — rm -rf build")
        #expect(item.tags.contains(PaletteTag(text: "Destructive", tone: .alert)))
        #expect(item.accessibilityNote == AskRiskMark.help)
        #expect(PaletteRanking.rank([item], query: "rm -rf", usage: PaletteUsage(), now: now).count == 1)
    }

    @Test("a typed destructive verb finds its row but never becomes Return")
    func paletteDenyNeverPromoted() {
        let log = Log()
        let ask = CoreAsk(session: "claude:fix-ci", summary: "Run tests", answerable: true, request: "r")
        let item = AgentPaletteRows.askItem(row: row("claude:fix-ci", ask: ask), ask: ask, now: now, verbs: verbs(log))
        let typed = PaletteRanking.rank([item], query: "deny fix", usage: PaletteUsage(), now: now)
        #expect(typed.first?.id == item.id, "the row still matches through Deny")
        #expect(typed.first?.primary?.id == "open", "Return stays the safe verb")
        #expect(typed.first?.action(for: .command("d"))?.id == "deny", "Deny keeps its own chord")
        // Any destructive verb, not just Deny.
        let clear = PaletteItem(id: "x", title: "fix-ci", icon: .symbol("circle", .gray), kind: "Session",
                                section: .sessions, actions: [
                                    PaletteAction(id: "open", title: "Open", symbol: "circle") { nil },
                                    PaletteAction(id: "clear", title: "Clear", symbol: "circle",
                                                  isDestructive: true) { nil },
                                ])
        #expect(PaletteRanking.promoting("clear", in: clear).primary?.id == "open")
    }

    @Test("typing \"allow fix\" finds the row through Always Allow but Return stays Open")
    func paletteAlwaysNeverPromoted() {
        let log = Log()
        let ask = held(always: true)
        let item = AgentPaletteRows.askItem(row: row("fix-ci", ask: ask), ask: ask, now: now, verbs: verbs(log))
        for query in ["allow fix", "always fix", "al fix"] {
            #expect(PaletteRanking.match(item, query: query)?.verbID == "always",
                    "\(query) reaches the row only through Always Allow")
            let typed = PaletteRanking.rank([item], query: query, usage: PaletteUsage(), now: now)
            #expect(typed.first?.id == item.id, "\(query) still lists the row")
            #expect(typed.first?.primary?.id == "open", "\(query): Return stays the safe verb")
            #expect(typed.first?.action(for: .primary)?.id != "always")
            #expect(typed.first?.action(for: .secondary)?.id == "approve", "⌘↩ keeps Approve, once")
        }
        #expect(log.calls.isEmpty)
    }

    @Test("two menu items with the same path and title get ids of their own, stable across queries")
    func menuIDs() {
        let app = AppMenuPaletteSource.MenuApp(pid: 1, name: "Safari", bundleID: "com.apple.Safari")
        let entries = [
            AppMenuEntry(indexPath: [5, 0], parents: ["Window"], title: "Untitled", shortcut: nil),
            AppMenuEntry(indexPath: [5, 1], parents: ["Window"], title: "Untitled", shortcut: nil),
            AppMenuEntry(indexPath: [1, 0], parents: ["File"], title: "Untitled", shortcut: nil),
        ]
        let ids = AppMenuPaletteSource.rowIDs(for: entries, app: app)
        #expect(Set(ids).count == 3)
        #expect(ids[0] == "menu.com.apple.Safari.Window/Untitled")
        #expect(ids[1] == "menu.com.apple.Safari.Window/Untitled#2")
        let rows = AppMenuPaletteSource.items(for: "untitled", entries: entries, app: app, press: { _, _ in })
        #expect(Set(rows.map(\.id)).count == rows.count)
        #expect(Set(rows.map(\.id)) == Set(ids))
    }

    @Test("slower sources land in source order as each answers; searching holds until the last")
    func searchAnswers() {
        func item(_ id: String) -> PaletteItem {
            PaletteItem(id: id, title: id, icon: .symbol("circle", .gray), kind: "T", section: .archive,
                        actions: [])
        }
        var answers = PaletteSearchAnswers(count: 3)
        answers.record([item("c")], at: 2)
        #expect(answers.items.map(\.id) == ["c"])
        #expect(!answers.isComplete)
        answers.record([item("a")], at: 0)
        answers.record([], at: 1)
        answers.record([item("z")], at: 9)
        #expect(answers.items.map(\.id) == ["a", "c"])
        #expect(answers.isComplete)
        let model = PaletteModel()
        model.load(items: [], usage: PaletteUsage())
        model.query = "abc"
        model.setSearchResults([item("c")], for: "abc", finished: false)
        #expect(model.searching)
        #expect(model.searchResults.map(\.id) == ["c"])
        model.setSearchResults([item("a"), item("c")], for: "abc")
        #expect(!model.searching)
    }

    @Test("one slow source never holds another's hits back")
    func slowSourceDoesNotBlock() async {
        let controller = PaletteController()
        controller.presentsWindow = false
        let hit = PaletteItem(id: "fast.hit", title: "fast", icon: .symbol("circle", .gray), kind: "T",
                              section: .archive, actions: [])
        // The slow read outlasts the test; closing the palette cancels it.
        let slow = PaletteClosureSource(build: { [] }, search: { _ in
            try? await Task.sleep(for: .seconds(60))
            return []
        })
        let fast = PaletteClosureSource(build: { [] }, search: { _ in [hit] })
        controller.sources = { [slow, fast] }
        controller.open()
        defer { controller.close() }
        controller.model.query = "fas"
        controller.queryChanged()
        await Self.waitFor { !controller.model.searchResults.isEmpty }
        #expect(controller.model.searchResults.map(\.id) == ["fast.hit"], "the fast source's hit is listed")
        #expect(controller.model.searching, "the slow one is still reading")
    }

    // MARK: A verb's own toast

    @Test("a verb's ticket hears the toasts it raised — now or from its task — and no other")
    func ticketHearsOnlyItsVerb() async {
        let store = PanelStore(core: CoreModel(), draftsDefaults: UserDefaults(suiteName: "jrbar.tests.\(UUID())")!,
                               screenBarShown: false)
        let ticket = PaletteVerbTicket()
        PaletteVerbScope.$ticket.withValue(ticket) {
            store.show(toast: "now")
            _ = Task { @MainActor in store.show(toast: "later") }
        }
        store.show(toast: "unrelated")
        await Self.waitFor { ticket.lines.count >= 2 }
        #expect(ticket.lines == ["now", "later"])
    }

    @Test("a verb run from a key monitor — no task around it — still passes its ticket to the tasks it starts")
    func ticketOutsideATask() async {
        let store = PanelStore(core: CoreModel(), draftsDefaults: UserDefaults(suiteName: "jrbar.tests.\(UUID())")!,
                               screenBarShown: false)
        let ticket = PaletteVerbTicket()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    PaletteVerbScope.$ticket.withValue(ticket) {
                        _ = Task { @MainActor in
                            store.show(toast: "from the task")
                            done.resume()
                        }
                    }
                }
            }
        }
        #expect(ticket.lines == ["from the task"])
    }

    @Test("a verb that raises no toast lets its ticket go as soon as it has run")
    func silentVerbFreesItsTicket() {
        let controller = PaletteController()
        controller.presentsWindow = false
        controller.toastFeed = { nil }
        var ran = false
        weak var seen: PaletteVerbTicket?
        let action = PaletteAction(id: "go", title: "Go", symbol: "circle") {
            ran = PaletteVerbScope.ticket != nil
            seen = PaletteVerbScope.ticket
            return nil
        }
        let item = PaletteItem(id: "x", title: "x", icon: .symbol("circle", .gray), kind: "T",
                               section: .archive, actions: [action])
        controller.run(action, of: item)
        #expect(ran, "the verb ran under a ticket")
        #expect(seen == nil, "nothing holds a silent verb's ticket once it has run")
    }

    // MARK: Panel

    @Test("a refused open tries the window locator only for a live local row the daemon could not find")
    func openFallbackGate() {
        let notFound = CoreReplyError(code: "not_found", message: "can't find its window")
        let live = row("claude:w", ask: nil, mode: "working")
        #expect(PanelStore.raisesWindowInstead(notFound, row: live))
        #expect(!PanelStore.raisesWindowInstead(CoreReplyError(code: "unsupported"), row: live))
        let ended = SessionRow(session: CoreSession(id: "claude:e", provider: "claude", mode: "completed",
                                                    lifecycle: "completed"), pinnedAsk: nil)
        #expect(!PanelStore.raisesWindowInstead(notFound, row: ended))
        #expect(!PanelStore.raisesWindowInstead(notFound, row: row("remote:studio:claude:x", ask: nil,
                                                                   remote: true, mode: "working")))
    }

    @Test("⌘↩ on a held question sends nothing and says to pick an option")
    func panelApproveOnQuestion() {
        let store = PanelStore(core: CoreModel(), draftsDefaults: UserDefaults(suiteName: "jrbar.tests.\(UUID())")!,
                               screenBarShown: false)
        store.approve(held(choices: [Self.single]))
        #expect(store.toast == "Pick one of its options")
        #expect(!store.isAnswerPending(held(choices: [Self.single])))
        store.alwaysAllow(held(always: false))
        #expect(store.toast == "This one has no rule to remember — approve it once instead")
    }

    @Test("the notch card's Open falls back to the window locator only for a running session")
    func notchCardOpenFallback() async {
        let presenter = NotchCardPresenter(model: makeTestCardModel())
        let log = Log()
        presenter.sessionRows = {
            [NotchIslandRow(id: "claude:run", label: "run", provider: "claude", activity: .working),
             NotchIslandRow(id: "claude:done", label: "done", provider: "claude", activity: .done)]
        }
        presenter.openSessionNow = { id in
            log.calls.append("open:\(id)")
            return CoreReply(id: "1", ok: false, error: CoreReplyError(code: "not_found"))
        }
        presenter.raiseSessionWindow = { id in
            log.calls.append("raise:\(id)")
            return true
        }
        presenter.open("claude:run")
        presenter.open("claude:done")
        presenter.open("remote:studio:claude:x")
        await Self.waitFor { log.calls.count >= 3 }
        #expect(log.calls.sorted() == ["open:claude:done", "open:claude:run", "raise:claude:run"])
    }

    // MARK: Rail

    @Test("the Rail's ask pill holds across the gap and while pointed at, and a plain label never does")
    func railPillHold() {
        #expect(DeckRailPillHold.cell(hovered: 3, pillCell: 1, pillHovered: true, interactive: true, inGrace: false) == 3)
        #expect(DeckRailPillHold.cell(hovered: nil, pillCell: 1, pillHovered: false, interactive: true, inGrace: true) == 1)
        #expect(DeckRailPillHold.cell(hovered: nil, pillCell: 1, pillHovered: true, interactive: true, inGrace: false) == 1)
        #expect(DeckRailPillHold.cell(hovered: nil, pillCell: 1, pillHovered: false, interactive: true, inGrace: false) == nil)
        #expect(DeckRailPillHold.cell(hovered: nil, pillCell: 1, pillHovered: true, interactive: false, inGrace: true) == nil)
    }

    @Test("an asking key's pill carries its live ask; a peer's or an unanswerable one draws no verbs")
    func railPillAsk() {
        let core = CoreModel()
        let ask = CoreAsk(session: "claude:session:r", kind: "permission", summary: "Run", answerable: true,
                          decision: CoreAskDecision(always: true))
        core.apply(.state(CoreState(
            sessions: [CoreSession(id: "claude:session:r", provider: "claude", mode: "waiting")], asks: [ask])))
        let store = DeckStore(core: core)
        let asking = DeckSlot(index: 0, session: "claude:session:r", state: .inputRequired)
        #expect(store.ask(for: asking)?.canAlwaysAllow == true)
        #expect(store.ask(for: DeckSlot(index: 1, session: "claude:session:r", state: .active)) == nil)
        #expect(DeckStore.pillAnswers(store.ask(for: asking)))
        #expect(!DeckStore.pillAnswers(CoreAsk(session: "claude:x", summary: "Run", answerable: false)))
        #expect(!DeckStore.pillAnswers(CoreAsk(session: "remote:studio:claude:x", summary: "Run", answerable: true)))
        #expect(!DeckStore.pillAnswers(nil))
    }

    // MARK: History and Overview

    @Test("Resume is offered on an ended local row of an agent that can resume, never on a live or peer one")
    func historyResume() {
        let core = CoreModel()
        core.apply(.state(CoreState(sessions: [CoreSession(id: "claude:live", provider: "claude", mode: "working")],
                                    asks: [])))
        let store = HistoryStore(core: core)
        #expect(store.canResume(CoreHistoryRow(at: 1, kind: "completed", provider: "claude", session: "claude:done")))
        #expect(store.canResume(CoreHistoryRow(at: 1, kind: "ended", session: "codex:session:z")),
                "the provider read off the agent id")
        #expect(!store.canResume(CoreHistoryRow(at: 1, kind: "started", provider: "claude", session: "claude:live")),
                "a running session opens instead")
        #expect(!store.canResume(CoreHistoryRow(at: 1, kind: "ended", provider: "gemini", session: "gemini:x")))
        #expect(!store.canResume(CoreHistoryRow(at: 1, kind: "ended", provider: "claude",
                                                session: "remote:studio:claude:x")))
        #expect(!store.canResume(CoreHistoryRow(at: 1, kind: "quota_crossed", provider: "claude")))
        #expect(HistoryStore.resumedText(.object(["raised": .string("new_tab"), "app": .string("Ghostty")]),
                                         title: "fix-ci") == "Resumed fix-ci in a new Ghostty tab")
        #expect(HistoryStore.resumedText(.object(["raised": .string("tab"), "app": .string("Terminal")]),
                                         title: "fix-ci") == "fix-ci was still running — raised it in Terminal")
    }

    @Test("New Session Here is for a local row with a folder, of an agent whose CLI the daemon starts")
    func overviewNewSession() {
        let store = OverviewStore(core: CoreModel())
        func entry(_ provider: String, cwd: String? = "/Users/me/src/app", remote: Bool = false) -> CoreRosterEntry {
            CoreRosterEntry(session: CoreSession(id: "\(provider):x", provider: provider, cwd: cwd, remote: remote))
        }
        #expect(store.canStartHere(entry("claude")))
        #expect(store.canStartHere(entry("codex")))
        #expect(!store.canStartHere(entry("gemini")))
        #expect(!store.canStartHere(entry("claude", cwd: nil)))
        #expect(!store.canStartHere(entry("claude", remote: true)))
        #expect(OverviewStore.startedText(.object(["raised": .string("new_tab"), "app": .string("Ghostty")]),
                                          provider: "claude", cwd: "/Users/me/src/app")
                == "Started Claude in a new Ghostty tab at src/app")
        #expect(OverviewStore.startedText(nil, provider: "codex", cwd: "/tmp/x").hasPrefix("Started Codex at"))
    }

    @Test("the Overview's status line names the route an answer took, as the panel's toast does")
    func overviewAnswerLine() {
        let hook = CoreReply(id: "1", ok: true, result: .object(["mechanism": .string("permission_hook"),
                                                                 "decision": .string("approve")]))
        #expect(OverviewStore.answeredText(hook, approve: true, replied: false)
                == "Approved · sent through the agent's permission hook")
        let typed = CoreReply(id: "2", ok: true, result: .object(["mechanism": .string("synthetic_text")]))
        #expect(OverviewStore.answeredText(typed, approve: true, replied: true) == "Reply sent · typed into the terminal")
        #expect(OverviewStore.answeredText(CoreReply(id: "3", ok: true), approve: false, replied: false) == "Denied")
    }

    // MARK: Hook doctor

    @Test("the hook doctor's report reads per provider, and a missing permission hook asks for Repair")
    func hooksDoctor() {
        let report: JSONValue = .object(["providers": .array([
            .object(["provider": .string("claude"), "installed": .bool(true), "hook_events": .number(12),
                     "registered": .array([.string("shim")]), "would_install": .string("shim"),
                     "decide": .string("missing"), "last_event_at": .number(now.timeIntervalSince1970 - 240),
                     "pending_lines": .number(3)]),
            .object(["provider": .string("codex"), "installed": .bool(true), "hook_events": .number(1),
                     "registered": .array([.string("shim")]), "decide": .string("installed"),
                     "last_event_at": .null]),
            .object(["provider": .string("pi"), "installed": .bool(true), "hook_events": .number(4),
                     "registered": .array([.string("legacy")]), "would_install": .string("shim")]),
            .object(["provider": .string("grok"), "installed": .bool(false)]),
            .object(["label": .string("no id")]),
        ])])
        let entries = HooksDoctor.entries(from: report)
        #expect(entries.count == 4)
        let claude = entries["claude"]!
        #expect(HooksDoctor.repairReason(claude)?.hasPrefix("Answering from JR-Bar isn't hooked up") == true)
        #expect(HooksDoctor.line(claude, now: now) == "12 events hooked · last event 4m ago · 3 queued")
        let codex = entries["codex"]!
        #expect(HooksDoctor.repairReason(codex) == nil)
        #expect(HooksDoctor.line(codex, now: now) == "1 event hooked · no event yet · answers from JR-Bar")
        #expect(HooksDoctor.repairReason(entries["pi"]!)?.hasPrefix("Runs an older hook command") == true)
        #expect(HooksDoctor.line(entries["grok"]!, now: now) == nil, "the row already says Not installed")
        #expect(HooksDoctor.repairReason(entries["grok"]!) == nil, "Install, not Repair")
    }

    // MARK: Quiet while watching

    @Test("the daemon's word decides when it has one; nil keeps the app's own rule")
    func watchingRule() {
        #expect(AskingPane.watching(local: false, inFront: true))
        #expect(!AskingPane.watching(local: true, inFront: false))
        #expect(AskingPane.watching(local: true, inFront: nil))
        #expect(!AskingPane.watching(local: false, inFront: nil))
        #expect(AskingPane.inFront(from: CoreReply(id: "1", ok: true, result: .object(["in_front": .bool(true)]))) == true)
        #expect(AskingPane.inFront(from: CoreReply(id: "1", ok: true, result: .object(["in_front": .bool(false)]))) == false)
        #expect(AskingPane.inFront(from: CoreReply(id: "1", ok: true, result: .object(["in_front": .null]))) == nil)
        #expect(AskingPane.inFront(from: CoreReply(id: "1", ok: false)) == nil)
        #expect(AskingPane.inFront(from: nil) == nil)
        let verdict = AskingPane.Verdict(session: "s", inFront: false, frontmostPID: 7, at: now)
        #expect(verdict.speaks(for: "s", frontmostPID: 7, now: now.addingTimeInterval(1)))
        #expect(!verdict.speaks(for: "s", frontmostPID: 8, now: now), "another app came forward")
        #expect(!verdict.speaks(for: "t", frontmostPID: 7, now: now))
        #expect(!verdict.speaks(for: "s", frontmostPID: 7, now: now.addingTimeInterval(AskingPane.verdictLife)))
    }

    private func watchedCoordinator(inFront: Bool?, frontmostIsHost: Bool) -> EventCoordinator {
        let core = CoreModel()
        let session = "claude:session:w"
        core.apply(.state(CoreState(
            sessions: [CoreSession(id: session, provider: "claude", mode: "waiting", pid: Int(getpid()),
                                   terminal: CoreTerminal(app: "Tests", bundleId: "dev.jr.tests"))],
            asks: [CoreAsk(session: session, summary: "Run")])))
        let coordinator = EventCoordinator(core: core, hudAnchor: { nil })
        let parent = AskingPane.parentPID(getpid())
        coordinator.frontmostApp = { frontmostIsHost ? ("dev.jr.tests", parent) : ("com.apple.Safari", 4242) }
        coordinator.sessionInFront = { _ in inFront }
        return coordinator
    }

    private func settle(_ coordinator: EventCoordinator, until: () -> Bool) async {
        await Self.waitFor(until)
    }

    @Test("the terminal app is in front but the daemon proves another tab: the stage's pulse comes back")
    func otherTabKeepsNoise() async {
        let coordinator = watchedCoordinator(inFront: false, frontmostIsHost: true)
        coordinator.handle(CoreEvent(id: "e1", kind: "escalation_stage", session: "claude:session:w", stage: 2))
        #expect(!coordinator.isPulsing, "the app's rule quiets it at first")
        await settle(coordinator) { coordinator.isPulsing }
        #expect(coordinator.isPulsing, "the owner is in another tab — the pulse speaks up")
        #expect(coordinator.inFrontVerdict?.inFront == false)
    }

    @Test("proof the session's own tab is in front quiets the stage; no word keeps the app's rule")
    func ownTabQuiets() async {
        let proven = watchedCoordinator(inFront: true, frontmostIsHost: false)
        proven.handle(CoreEvent(id: "e1", kind: "escalation_stage", session: "claude:session:w", stage: 2))
        #expect(proven.isPulsing)
        await settle(proven) { !proven.isPulsing }
        #expect(!proven.isPulsing)
        let unknown = watchedCoordinator(inFront: nil, frontmostIsHost: true)
        unknown.handle(CoreEvent(id: "e2", kind: "escalation_stage", session: "claude:session:w", stage: 2))
        await settle(unknown) { unknown.inFrontVerdict != nil }
        #expect(unknown.inFrontVerdict?.inFront == nil)
        #expect(!unknown.isPulsing, "cannot be told: the app's rule stands")
    }
}
