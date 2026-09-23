import AppKit
import Foundation
import Observation
import Testing
@testable import JRBarApp
@testable import JRBarCore

/// The palette's rows past the menu bar: what each source says, which
/// verbs it offers where, and that each verb lands on the owning
/// store's path. Nothing here opens a window or touches the system.
@Suite("Palette sources")
@MainActor
struct PaletteSourcesTests {
    @MainActor
    final class Log {
        var calls: [String] = []
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func agentVerbs(_ log: Log) -> AgentPaletteVerbs {
        AgentPaletteVerbs(
            open: { log.calls.append("open:\($0.id)") },
            approve: { log.calls.append("approve:\($0.request ?? "")") },
            deny: { log.calls.append("deny:\($0.request ?? "")") },
            snooze: { log.calls.append("snooze:\($0.id):\($1)") },
            copyPath: { log.calls.append("copy:\($0.id)") },
            reveal: { log.calls.append("reveal:\($0.id)") },
            dismiss: { log.calls.append("dismiss:\($0.id)") },
            clear: { log.calls.append("clear:\($0.id)") })
    }

    private func session(_ id: String, mode: String = "working", lifecycle: String? = nil,
                         ask: CoreAsk? = nil, remote: Bool = false, stale: Bool = false) -> SessionRow {
        SessionRow(session: CoreSession(id: id, provider: "claude", label: id, cwd: "/Users/me/src/\(id)",
                                        mode: mode, lifecycle: lifecycle,
                                        since: now.timeIntervalSince1970 - 300, stale: stale,
                                        ask: ask, remote: remote),
                   pinnedAsk: nil)
    }

    // MARK: Agents

    @Test("an answerable ask: Return opens, ⌘↩ approves, ⌘D denies — through the panel's verbs")
    func askAnswerable() {
        let log = Log()
        let ask = CoreAsk(session: "claude:s1", summary: "Run npm test", answerable: true, request: "req-1")
        let item = AgentPaletteRows.askItem(row: session("claude:s1", mode: "waiting", ask: ask),
                                            ask: ask, now: now, verbs: agentVerbs(log))
        #expect(item.urgent)
        #expect(item.section == .needsYou)
        #expect(item.subtitle == "Run npm test")
        #expect(item.primary?.title == "Open Session")
        #expect(item.action(for: .secondary)?.title == "Approve")
        #expect(item.action(for: .command("d"))?.title == "Deny")
        #expect(item.actions.first { $0.id == "deny" }?.isDestructive == true)
        _ = item.action(for: .secondary)?.run()
        _ = item.action(for: .command("d"))?.run()
        _ = item.primary?.run()
        #expect(log.calls == ["approve:req-1", "deny:req-1", "open:claude:s1"])
    }

    @Test("no Approve or Deny where the daemon says an answer cannot land, and the row says why")
    func askNotAnswerable() {
        let log = Log()
        let ghostty = CoreAsk(session: "claude:s1", summary: "Edit file", answerable: false)
        let blocked = AgentPaletteRows.askItem(row: session("claude:s1", mode: "waiting", ask: ghostty),
                                               ask: ghostty, now: now, verbs: agentVerbs(log))
        #expect(!blocked.actions.contains { $0.id == "approve" || $0.id == "deny" })
        #expect(blocked.accessibilityNote == "Answer it in the session's own window")
        let text = CoreAsk(session: "claude:s2", summary: "Which branch?", answerable: true, replyable: true)
        let typed = AgentPaletteRows.askItem(row: session("claude:s2", mode: "waiting", ask: text),
                                             ask: text, now: now, verbs: agentVerbs(log))
        #expect(!typed.actions.contains { $0.id == "approve" })
        let peer = CoreAsk(session: "remote:studio:claude:s3", summary: "Run", answerable: true)
        let remote = AgentPaletteRows.askItem(
            row: session("remote:studio:claude:s3", mode: "waiting", ask: peer, remote: true),
            ask: peer, now: now, verbs: agentVerbs(log))
        #expect(!remote.actions.contains { $0.id == "approve" || $0.id == "snooze" })
    }

    @Test("an ask that wants words gets Reply… on ⌘↩: its field starts from the panel's draft and sends through the panel")
    func askReply() {
        let log = Log()
        var verbs = agentVerbs(log)
        verbs.reply = { log.calls.append("reply:\($0.request ?? ""):\($1)") }
        verbs.replyDraft = { _ in "use the" }
        verbs.setReplyDraft = { log.calls.append("draft:\($1)") }
        let ask = CoreAsk(session: "claude:s2", summary: "Which branch?", answerable: true, replyable: true,
                          request: "req-2")
        let item = AgentPaletteRows.askItem(row: session("claude:s2", mode: "waiting", ask: ask),
                                            ask: ask, now: now, verbs: verbs)
        #expect(item.primary?.title == "Open Session", "Return still only opens")
        let reply = item.action(for: .secondary)
        #expect(reply?.title == "Reply…")
        #expect(!item.actions.contains { $0.id == "approve" || $0.id == "deny" }, "words, not a verdict")
        #expect(reply?.input?.prompt == "Reply to claude:s2…")
        #expect(reply?.input?.submitTitle == "Send Reply")
        #expect(reply?.input?.initial() == "use the")
        #expect(reply?.run() == nil)
        #expect(log.calls.isEmpty, "picking Reply… sends nothing by itself")
        reply?.input?.onChange?("use the main branch")
        #expect(reply?.input?.submit("use the main branch") == nil, "the panel's toast is the answer")
        #expect(log.calls == ["draft:use the main branch", "reply:req-2:use the main branch"])
        #expect(item.accessibilityNote == nil)
        #expect(PaletteRanking.rank([item], query: "reply s2", usage: PaletteUsage(), now: now)
            .first?.primary?.title == "Reply…")
        // Where the words cannot land, no field opens.
        let blocked = CoreAsk(session: "claude:s3", summary: "Which?", answerable: false, replyable: true)
        let noText = AgentPaletteRows.askItem(row: session("claude:s3", mode: "waiting", ask: blocked),
                                              ask: blocked, now: now, verbs: verbs)
        #expect(!noText.actions.contains { $0.id == "reply" })
        #expect(noText.accessibilityNote == "Answer it in the session's own window")
        let peer = CoreAsk(session: "remote:studio:claude:s4", summary: "Which?", answerable: true, replyable: true)
        let remote = AgentPaletteRows.askItem(
            row: session("remote:studio:claude:s4", mode: "waiting", ask: peer, remote: true),
            ask: peer, now: now, verbs: verbs)
        #expect(!remote.actions.contains { $0.id == "reply" })
        let orphan = CoreAsk(session: nil, summary: "Which?", answerable: true, replyable: true)
        let lost = AgentPaletteRows.askItem(row: session("claude:s5", mode: "waiting", ask: orphan),
                                            ask: orphan, now: now, verbs: verbs)
        #expect(!lost.actions.contains { $0.id == "reply" }, "no session left to type into")
    }

    @Test("a typed “approve” runs Approve, and a lone letter never does")
    func askVerbSearch() {
        let log = Log()
        let ask = CoreAsk(session: "claude:fix-ci", summary: "Run tests", answerable: true, request: "r")
        let item = AgentPaletteRows.askItem(row: session("claude:fix-ci", mode: "waiting", ask: ask),
                                            ask: ask, now: now, verbs: agentVerbs(log))
        let typed = PaletteRanking.rank([item], query: "approve fix", usage: PaletteUsage(), now: now)
        #expect(typed.first?.primary?.title == "Approve")
        #expect(typed.first?.action(for: .secondary)?.title == "Approve", "Approve keeps its own ⌘↩")
        let letter = PaletteRanking.rank([item], query: "a", usage: PaletteUsage(), now: now)
        #expect(letter.first?.primary?.title != "Approve")
    }

    @Test("a session row: state tag, path verbs, snooze, and Clear only where the panel clears")
    func sessionRow() {
        let log = Log()
        let working = AgentPaletteRows.sessionItem(row: session("claude:w"), now: now, verbs: agentVerbs(log))
        #expect(working.section == .sessions)
        #expect(working.tags.first == PaletteTag(text: "Working", tone: .accent))
        #expect(working.actions.map(\.id) == ["open", "copyPath", "reveal", "snooze", "snoozeMorning", "dismiss"])
        #expect(working.action(for: PaletteShortcut(.delete, .command))?.id == "dismiss")
        let done = AgentPaletteRows.sessionItem(row: session("claude:d", mode: "completed", lifecycle: "completed"),
                                                now: now, verbs: agentVerbs(log))
        #expect(done.tags.first == PaletteTag(text: "Done", tone: .positive))
        #expect(done.action(for: PaletteShortcut(.delete, .command))?.id == "clear")
        #expect(!done.actions.contains { $0.id == "dismiss" })
        _ = done.action(for: PaletteShortcut(.delete, .command))?.run()
        _ = done.action(for: .commandShift("c"))?.run()
        #expect(log.calls == ["clear:claude:d", "copy:claude:d"])
    }

    @Test("roster verbs appear only when they would do something; a dead daemon gets one honest row")
    func agentCommands() {
        let log = Log()
        let verbs = AgentPaletteRows.CommandVerbs(
            restart: { log.calls.append("restart") }, openPanel: { log.calls.append("panel") },
            clearFinished: { log.calls.append("clear") }, undoClear: { log.calls.append("undo") })
        let quiet = AgentPaletteRows.commandItems(
            .init(live: true, connection: "", canRestart: true, completed: 0, undoable: nil), verbs: verbs)
        #expect(quiet.isEmpty)
        let busy = AgentPaletteRows.commandItems(
            .init(live: true, connection: "", canRestart: true, completed: 3, undoable: 2), verbs: verbs)
        #expect(busy.map(\.id) == ["agents.clearFinished", "agents.undoClear"])
        #expect(busy[0].subtitle == "3 done, ended or stale")
        #expect(busy[1].subtitle == "Puts back the 2 sessions just cleared")
        _ = busy[0].primary?.run()
        _ = busy[1].primary?.run()
        let offline = AgentPaletteRows.commandItems(
            .init(live: false, connection: "Monitor not connected: refused", canRestart: true,
                  completed: 3, undoable: nil), verbs: verbs)
        #expect(offline.map(\.id) == ["agents.offline"])
        #expect(offline[0].subtitle == "Monitor not connected: refused")
        #expect(offline[0].actions.map(\.id) == ["restart", "panel"])
        _ = offline[0].primary?.run()
        let unsupervised = AgentPaletteRows.commandItems(
            .init(live: false, connection: "", canRestart: false, completed: 0, undoable: nil), verbs: verbs)
        #expect(unsupervised[0].actions.map(\.id) == ["panel"], "no restart the app cannot make")
        #expect(log.calls == ["clear", "undo", "restart"])
    }

    // MARK: Quiet

    @Test("quiet presets run the remembered mode on Return, every other mode one ⌘K away")
    func quietRows() {
        let log = Log()
        let verbs = QuietPaletteVerbs(quiet: { log.calls.append("\($0):\($1)") },
                                      end: { log.calls.append("end") })
        let items = QuietPaletteRows.items(mode: "dim", quietLabel: nil, quietIsOurs: false, now: now, verbs: verbs)
        #expect(items.map(\.id) == ["quiet.30m", "quiet.1h", "quiet.4h", "quiet.morning"])
        let hour = items[1]
        #expect(hour.title == "Quiet for 1 Hour")
        #expect(hour.subtitle == "Dim — stills the lights")
        #expect(hour.primary?.title == "Dim for 1 Hour")
        #expect(hour.actions.count == PanelStore.quietModes.count)
        _ = hour.primary?.run()
        _ = hour.actions.first { $0.id == "pause" }?.run()
        #expect(log.calls == ["dim:3600", "pause:3600"])
        #expect(items[3].title.hasPrefix("Quiet Until"))
    }

    @Test("End Quiet appears only for a quiet this app set")
    func quietEnd() {
        let verbs = QuietPaletteVerbs(quiet: { _, _ in }, end: {})
        let ours = QuietPaletteRows.items(mode: "pause", quietLabel: "Paused 52m", quietIsOurs: true,
                                          now: now, verbs: verbs)
        #expect(ours.first?.id == "quiet.end")
        #expect(ours.first?.subtitle == "Paused 52m")
        let focus = QuietPaletteRows.items(mode: "pause", quietLabel: "Paused", quietIsOurs: false,
                                           now: now, verbs: verbs)
        #expect(!focus.contains { $0.id == "quiet.end" }, "a Focus's quiet is not ours to end")
    }

    // MARK: Lights

    @Test("scenes mark the live one; brightness is a menu of steps; the Screen Bar says its state")
    func lightsRows() {
        let log = Log()
        let verbs = LightsPaletteVerbs(setScene: { log.calls.append("scene:\($0)") },
                                       setBrightness: { log.calls.append("b:\($0)") },
                                       setScreenBar: { log.calls.append("bar:\($0)") })
        let items = LightsPaletteRows.items(activeScene: "focus", brightness: 0.6, screenBarShown: true,
                                            verbs: verbs)
        let focus = items.first { $0.id == "scene.focus" }
        #expect(focus?.tags == [PaletteTag(text: "Current", tone: .accent)])
        #expect(items.first { $0.id == "scene.calm" }?.tags.isEmpty == true)
        #expect(items.first { $0.id == "scene.night" }?.primary?.run() == "Scene: Night")
        let brightness = items.first { $0.id == "lights.brightness" }
        #expect(brightness?.opensActions == true)
        #expect(brightness?.subtitle == "Now 60%")
        #expect(brightness?.actions.map(\.title) == ["10%", "25%", "50%", "75%", "100%"])
        #expect(brightness?.actions[2].run() == "Brightness 50%")
        let bar = items.first { $0.id == "lights.screenBar" }
        #expect(bar?.primary?.title == "Hide Screen Bar")
        _ = bar?.primary?.run()
        #expect(log.calls == ["scene:night", "b:0.5", "bar:false"])
        // No strip or Dot attached: no brightness row to lie with.
        let bare = LightsPaletteRows.items(activeScene: "calm", brightness: nil, screenBarShown: false,
                                           verbs: verbs)
        #expect(!bare.contains { $0.id == "lights.brightness" })
    }

    // MARK: Control Center

    @Test("toggles show the read-back state; verbs say what they will do; restarts are named")
    func controlCenterRows() {
        let log = Log()
        let items = ControlCenterPaletteRows.items(
            isOn: [.darkMode: true, .keepAwake: false],
            applying: [.hiddenFiles]) { log.calls.append($0.rawValue) }
        #expect(items.count == SystemToggle.allCases.count)
        let dark = items.first { $0.id == "system.darkMode" }
        #expect(dark?.tags == [PaletteTag(text: "On", tone: .positive)])
        #expect(dark?.primary?.title == "Turn Off")
        #expect(dark?.primary?.run() == "Turning Dark Mode off")
        let awake = items.first { $0.id == "system.keepAwake" }
        #expect(awake?.primary?.run() == "Keep Awake on")
        #expect(items.first { $0.id == "system.hiddenFiles" }?.tags == [PaletteTag(text: "Applying…")])
        let dock = items.first { $0.id == "system.dockAutoHide" }
        #expect(dock?.subtitle == "Restarts Dock")
        #expect(dock?.primary?.title == "Toggle", "no read-back yet: no claim")
        let lock = items.first { $0.id == "system.lock" }
        #expect(lock?.tags.isEmpty == true, "a verb has no state")
        #expect(lock?.primary?.run() == nil)
        #expect(log.calls == ["darkMode", "keepAwake", "lock"])
        #expect(PaletteRanking.rank(items, query: "caffeinate", usage: PaletteUsage(), now: now).first?.id
                == "system.keepAwake")
    }

    // MARK: Usage

    @Test("usage rows lead with the headline window's percent and tone it by headroom")
    func usageRows() {
        let window = CoreUsageWindow(key: "five-hour", name: "5h", usedPct: 92,
                                     resetsAt: now.timeIntervalSince1970 + 3600)
        let provider = CoreProviderUsage(id: "claude", windows: [window])
        let log = Log()
        let items = UsagePaletteRows.items(usage: [provider], now: now) { log.calls.append($0) }
        #expect(items.first?.title == "Claude Usage")
        #expect(items.first?.tags.first == PaletteTag(text: "92%", tone: .alert))
        #expect(items.first?.subtitle?.contains("resets in 1h") == true)
        _ = items.first?.primary?.run()
        #expect(log.calls == ["claude"])
    }

    // MARK: Aquarium

    @Test("Feed the Tank shows only with a fish to feed; the tank's switch reads its state")
    func aquariumRows() {
        let log = Log()
        let verbs = AquariumPaletteVerbs(feed: { log.calls.append("feed"); return "Fed 3 fish" },
                                         setOpen: { log.calls.append("open:\($0)") })
        let fed = AquariumPaletteRows.items(fishCount: 3, isOn: false, verbs: verbs)
        #expect(fed.first?.title == "Feed the Tank")
        #expect(fed.first?.subtitle == "A pellet for each of 3 fish")
        #expect(fed.first?.primary?.run() == "Fed 3 fish")
        #expect(fed.last?.primary?.title == "Open the Tank")
        _ = fed.last?.primary?.run()
        #expect(log.calls == ["feed", "open:true"])
        let empty = AquariumPaletteRows.items(fishCount: 0, isOn: true, verbs: verbs)
        #expect(empty.map(\.id) == ["aquarium.window"])
        #expect(empty.first?.primary?.title == "Close the Tank")
    }

    // MARK: Archive

    @Test("archive hits read as one quiet line, and a search row carries the query into the window")
    func archiveRows() {
        let log = Log()
        let record = ArchiveRecord(id: "rec1", name: "session.jsonl", sourcePath: "/tmp/session.jsonl",
                                   byteCount: 10, importedAt: now, sourceModifiedAt: nil,
                                   provider: "codex", sessionID: "abc", title: "Fix the flaky build")
        let hit = ArchiveSearchResult(record: record, snippets: ["the «flaky»   test\nfailed twice"])
        let verbs = ArchivePaletteVerbs(
            openRecord: { log.calls.append("open:\($0.id):\($1)") },
            search: { log.calls.append("search:\($0)") },
            sessionFor: { $0.sessionID == "abc" ? "codex:session:abc" : nil },
            openSession: { log.calls.append("session:\($0)") })
        let items = ArchivePaletteRows.items(query: " flaky ", hits: [hit], verbs: verbs)
        #expect(items.map(\.id) == ["archive.rec1", "archive.search"])
        #expect(items[0].title == "Fix the flaky build")
        #expect(items[0].subtitle == "the flaky test failed twice")
        #expect(items[0].section == .archive)
        #expect(items[0].actions.map(\.id) == ["open", "session", "reveal", "copyPath"])
        _ = items[0].primary?.run()
        _ = items[0].actions[1].run()
        _ = items[1].primary?.run()
        #expect(log.calls == ["open:rec1:flaky", "session:codex:session:abc", "search:flaky"])
        #expect(ArchivePaletteRows.items(query: "fl", hits: [hit], verbs: verbs).isEmpty,
                "too short to search")
    }

    // MARK: The frontmost app's menus

    @Test("a key equivalent reads the way the menu draws it")
    func menuShortcutText() {
        #expect(AppMenuReader.shortcutText(char: "s", modifiers: 0, glyph: nil) == "⌘S")
        #expect(AppMenuReader.shortcutText(char: "S", modifiers: 1, glyph: nil) == "⇧⌘S")
        #expect(AppMenuReader.shortcutText(char: "f", modifiers: 4 | 2, glyph: nil) == "⌃⌥⌘F")
        #expect(AppMenuReader.shortcutText(char: "q", modifiers: 8 | 4, glyph: nil) == "⌃Q", "no-command bit")
        #expect(AppMenuReader.shortcutText(char: nil, modifiers: 0, glyph: 0x17) == "⌘⌫")
        #expect(AppMenuReader.shortcutText(char: nil, modifiers: 0, glyph: 0x999) == nil)
        #expect(AppMenuReader.shortcutText(char: nil, modifiers: nil, glyph: nil) == nil)
    }

    /// The pressed paths, for a menu source's verbs.
    final class PressLog: @unchecked Sendable {
        private let lock = NSLock()
        private var _pressed: [[Int]] = []
        var pressed: [[Int]] { lock.lock(); defer { lock.unlock() }; return _pressed }
        func add(_ path: [Int]) { lock.lock(); _pressed.append(path); lock.unlock() }
    }

    @Test("menu items rank by title, then by path; a pick presses its own path")
    func menuItems() {
        let entries = [
            AppMenuEntry(indexPath: [1, 0], parents: ["File"], title: "New Window", shortcut: "⌘N"),
            AppMenuEntry(indexPath: [1, 4, 2], parents: ["File", "Export"], title: "PDF…", shortcut: nil),
            AppMenuEntry(indexPath: [2, 3], parents: ["Edit"], title: "Paste and Match Style",
                         shortcut: "⌥⇧⌘V"),
        ]
        let log = PressLog()
        let app = AppMenuPaletteSource.MenuApp(pid: 42, name: "Pages", bundleID: "com.apple.iWork.Pages")
        let hits = AppMenuPaletteSource.items(for: "export pdf", entries: entries, app: app) { _, path in
            log.add(path)
        }
        #expect(hits.map(\.title) == ["PDF…"])
        #expect(hits.first?.subtitle == "File › Export")
        #expect(hits.first?.section.title == "Pages Menus")
        #expect(hits.first?.kind == "Menu Item")
        _ = hits.first?.primary?.run()
        #expect(log.pressed == [[1, 4, 2]])
        let paste = AppMenuPaletteSource.items(for: "paste", entries: entries, app: app) { _, _ in }
        #expect(paste.first?.tags == [PaletteTag(text: "⌥⇧⌘V")])
    }

    /// The reads a menu source made.
    actor ReadCount {
        var count = 0
        func add() { count += 1 }
    }

    @Test("the menu source reads once per open, only once a query is long enough, and never JR-Bar's own")
    func menuSourceReads() async {
        let reads = ReadCount()
        let source = AppMenuPaletteSource()
        source.trusted = { true }
        source.frontmost = { .init(pid: 4242, name: "Pages", bundleID: "com.apple.iWork.Pages") }
        source.read = { _ in
            await reads.add()
            return [AppMenuEntry(indexPath: [1, 0], parents: ["File"], title: "Save", shortcut: "⌘S")]
        }
        source.prepare()
        #expect(await source.results(for: "s").isEmpty, "one letter is too short")
        #expect(await source.results(for: "sa").map(\.title) == ["Save"])
        #expect(await source.results(for: "sav").map(\.title) == ["Save"])
        #expect(await reads.count == 1, "the read is shared by the open's queries")
        source.prepare()
        _ = await source.results(for: "save")
        #expect(await reads.count == 2, "a new open reads afresh")
        source.frontmost = { .init(pid: ProcessInfo.processInfo.processIdentifier, name: "JR-Bar", bundleID: nil) }
        source.prepare()
        #expect(await source.results(for: "save").isEmpty, "JR-Bar's own menus are not listed")
        source.trusted = { false }
        source.frontmost = { .init(pid: 4242, name: "Pages", bundleID: "com.apple.iWork.Pages") }
        source.prepare()
        #expect(await source.results(for: "save").isEmpty, "no Accessibility, no read")
    }

    @Test("slower sources' hits group under their own headings after the ranked results")
    func modelGroupsSearchResults() {
        let model = PaletteModel()
        model.load(items: [PaletteItem(id: "a", title: "Save Scene", icon: .symbol("circle", .gray),
                                       kind: "Scene", section: .lights, actions: [])],
                   usage: PaletteUsage(), now: now)
        model.query = "sav"
        let menu = PaletteSection(id: "appMenu", title: "Pages Menus", order: 95)
        model.setSearchResults([
            PaletteItem(id: "menu.1", title: "Save", icon: .symbol("circle", .gray), kind: "Menu Item",
                        section: menu, actions: []),
            PaletteItem(id: "archive.1", title: "saved notes", icon: .symbol("circle", .gray),
                        kind: "Archive", section: .archive, actions: []),
            PaletteItem(id: "menu.2", title: "Save As…", icon: .symbol("circle", .gray), kind: "Menu Item",
                        section: menu, actions: []),
        ], for: "sav")
        #expect(model.sections.map(\.section.id) == ["results", "appMenu", "archive"])
        #expect(model.sections[1].items.map(\.id) == ["menu.1", "menu.2"])
    }

    // MARK: Windows and Settings

    @Test("every window and Settings page is a row; the archive only while the hoarder is on")
    func windowRows() {
        let log = Log()
        func verbs(archive: Bool) -> PaletteWindowVerbs {
            var openArchive: (@MainActor () -> Void)?
            if archive { openArchive = { log.calls.append("archive") } }
            return PaletteWindowVerbs(
                overview: { log.calls.append("overview") }, usageCenter: {}, history: {}, effects: {},
                deck: {}, replay: {}, archive: openArchive,
                panel: {}, checkForUpdates: {}, settings: { log.calls.append("settings:\($0.rawValue)") })
        }
        let with = WindowPaletteRows.items(verbs: verbs(archive: true))
        #expect(with.contains { $0.id == "open.archive" })
        #expect(!WindowPaletteRows.items(verbs: verbs(archive: false)).contains { $0.id == "open.archive" })
        _ = with.first { $0.id == "open.overview" }?.primary?.run()
        let pages = WindowPaletteRows.settingsItems { log.calls.append("settings:\($0.rawValue)") }
        #expect(pages.count == SettingsStore.Page.allCases.count)
        let hit = PaletteRanking.rank(pages, query: "screen bar", usage: PaletteUsage(), now: now).first
        #expect(hit?.id == "settings.devices")
        _ = hit?.primary?.run()
        #expect(log.calls == ["overview", "settings:devices"])
    }

    // MARK: Live rows

    /// An observable fact a source reads — the stand-in for the
    /// daemon's state or a toggle's read-back.
    @MainActor
    @Observable
    final class Fact {
        var asks = 0
    }

    @Test("rows re-gather while the palette is up when something a source read changes")
    func liveRegather() async {
        let fact = Fact()
        let controller = PaletteController()
        controller.presentsWindow = false
        let prepared = Log()
        controller.sources = {
            [PaletteClosureSource(prepare: { prepared.calls.append("prepare") }, build: {
                (0..<fact.asks).map { i in
                    PaletteItem(id: "ask.\(i)", title: "ask \(i)", icon: .symbol("circle", .gray),
                                kind: "Ask", section: .needsYou, actions: [], urgent: true)
                }
            })]
        }
        controller.open()
        defer { controller.close() }
        #expect(prepared.calls == ["prepare"])
        #expect(controller.model.rows.isEmpty)
        fact.asks = 2
        for _ in 0..<200 where controller.model.rows.count != 2 { await Task.yield() }
        #expect(controller.model.rows.map(\.id) == ["ask.0", "ask.1"])
        #expect(prepared.calls == ["prepare"], "a re-gather never re-prepares")
    }
}
