import Carbon
import Foundation
import JRBarCore
import Testing
@testable import JRBarApp

/// The `jrbar://` vocabulary and the router behind links and shortcuts:
/// every link parses whole or not at all, and a command that cannot run
/// is refused out loud.
@Suite struct AppCommandTests {
    private func parse(_ text: String) -> AppCommand? {
        URL(string: text).flatMap(AppCommand.parse)
    }

    @Test func thePanelAndSettingsLinks() {
        #expect(parse("jrbar://panel") == .panel(toggle: false))
        #expect(parse("jrbar://panel/toggle") == .panel(toggle: true))
        #expect(parse("jrbar:///panel/toggle") == .panel(toggle: true))
        #expect(parse("jrbar://settings") == .settings(page: nil))
        #expect(parse("jrbar://settings/Shortcuts") == .settings(page: "shortcuts"))
        #expect(parse("jrbar://settings/nowhere") == nil)
        #expect(parse("jrbar://overview") == .window(.overview))
        #expect(parse("jrbar://open/control-center") == .window(.controlCenter))
    }

    @Test func everyWindowOpensByItsLinkName() {
        for window in AppCommand.AppWindow.allCases {
            #expect(parse("jrbar://open/\(window.rawValue)") == .window(window))
            #expect(parse("jrbar://window/\(window.rawValue)") == .window(window))
            #expect(parse("jrbar://\(window.rawValue)") == .window(window), "the bare verb list keeps up")
        }
        for alias in AppCommand.AppWindow.aliases.keys {
            let aliased = AppCommand.AppWindow.aliases[alias]
            #expect(parse("jrbar://window/\(alias)") == aliased.map(AppCommand.window), "an older name keeps working")
            #expect(parse("jrbar://\(alias)") == aliased.map(AppCommand.window))
        }
        #expect(parse("jrbar://window/creator-micro") == .window(.controlCenter))
        #expect(parse("jrbar://open/Control-Center") == .window(.controlCenter))
        #expect(AppCommand.window(.controlCenter).link.absoluteString == "jrbar://window/creator-micro",
                "a new link names the window by the pad")
        #expect(parse("jrbar://window/whats-new") == .window(.whatsNew))
        #expect(parse("jrbar://window/Whats-New") == .window(.whatsNew))
        #expect(parse("jrbar://window/nowhere") == nil)
        #expect(parse("jrbar://window") == nil)
    }

    @Test func theGraphAndTheTankHaveLinksOfTheirOwn() {
        #expect(AppCommand.overviewGraph.link.absoluteString == "jrbar://overview/graph")
        #expect(AppCommand.aquarium.link.absoluteString == "jrbar://aquarium")
        #expect(parse("jrbar://overview/graph") == .overviewGraph)
        #expect(parse("jrbar://Overview/Graph") == .overviewGraph)
        #expect(parse("jrbar:///overview/graph") == .overviewGraph)
        #expect(parse("jrbar://aquarium") == .aquarium)
        #expect(parse("jrbar://Aquarium") == .aquarium)
        // The tank only opens: no link closes it or flips it.
        #expect(parse("jrbar://aquarium/close") == nil)
        #expect(parse("jrbar://aquarium/toggle") == nil)
        // The Overview's own links still open it where it was.
        #expect(parse("jrbar://overview") == .window(.overview))
        #expect(parse("jrbar://open/overview") == .window(.overview))
        #expect(parse("jrbar://window/overview") == .window(.overview))
        #expect(AppCommand.window(.overview).link.absoluteString == "jrbar://window/overview")
    }

    @Test func everySettingsPageALinkMayNameExists() {
        // The pure parser keeps its own list so it needs no main-actor
        // type; this keeps it honest against the real pages.
        let pages = Set(SettingsStore.Page.allCases.map(\.rawValue))
        #expect(SettingsPageName.known == pages)
    }

    @Test func toggleLinksNameChipsTheWayAPersonWould() {
        #expect(parse("jrbar://toggle/dark") == .toggle(.darkMode, on: nil))
        #expect(parse("jrbar://toggle/darkMode?on=1") == .toggle(.darkMode, on: true))
        #expect(parse("jrbar://toggle/DOCK?on=off") == .toggle(.dockAutoHide, on: false))
        #expect(parse("jrbar://toggle/mic") == .toggle(.micMute, on: nil))
        #expect(parse("jrbar://toggle/eject") == .toggle(.eject, on: nil))
        #expect(parse("jrbar://toggle/keep-awake") == .toggle(.keepAwake, on: nil))
        #expect(parse("jrbar://toggle/warp") == nil)
        #expect(parse("jrbar://toggle/dark?on=maybe") == nil)
    }

    @Test func awakeTakesADurationOrOff() {
        #expect(parse("jrbar://awake") == .keepAwake(seconds: nil))
        #expect(parse("jrbar://awake?for=2h") == .keepAwake(seconds: 7200))
        #expect(parse("jrbar://awake?for=1h30m") == .keepAwake(seconds: 5400))
        #expect(parse("jrbar://awake?for=off") == .keepAwake(seconds: 0))
        #expect(parse("jrbar://awake?for=2x") == nil)
        #expect(parse("jrbar://awake?for=3d") == nil, "longer than a day is refused")
    }

    @Test func untilAClockTimeCountsToItsNextOccurrence() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Chicago"))
        // 2026-09-23 22:15 in Chicago.
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 23, hour: 22, minute: 15)))
        func at(_ link: String) -> AppCommand? { AppCommand.parse(URL(string: link)!, now: now, calendar: calendar) }
        // 8 AM is tomorrow: 9 h 45 min away.
        #expect(at("jrbar://awake?until=8am") == .keepAwake(seconds: 35_100))
        #expect(at("jrbar://awake?until=08:00") == .keepAwake(seconds: 35_100))
        #expect(at("jrbar://awake?until=8:00%20AM") == .keepAwake(seconds: 35_100))
        // 11:30 PM is later tonight.
        #expect(at("jrbar://quiet?mode=dim&until=11:30pm") == .quiet(mode: "dim", seconds: 4500))
        #expect(at("jrbar://quiet?until=23:30") == .quiet(mode: nil, seconds: 4500))
        // 12 AM is midnight, 12 PM is noon.
        #expect(at("jrbar://awake?until=12am") == .keepAwake(seconds: 6300))
        #expect(at("jrbar://awake?until=12pm") == .keepAwake(seconds: 49_500))
    }

    @Test func aClockTimeThatIsNotOneIsRefused() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        func at(_ link: String) -> AppCommand? { AppCommand.parse(URL(string: link)!, now: now) }
        #expect(at("jrbar://awake?until=8") == nil, "a bare number is a duration's grammar, not a clock's")
        #expect(at("jrbar://awake?until=25:00") == nil)
        #expect(at("jrbar://awake?until=13pm") == nil)
        #expect(at("jrbar://awake?until=8:75") == nil)
        #expect(at("jrbar://awake?until=soon") == nil)
        #expect(at("jrbar://awake?until=8am&for=2h") == nil, "two lengths are one too many")
        #expect(at("jrbar://quiet?until=") == nil)
    }

    @Test func quietTakesAModeAndALength() {
        #expect(parse("jrbar://quiet") == .quiet(mode: nil, seconds: 3600))
        #expect(parse("jrbar://quiet?mode=dim&for=30m") == .quiet(mode: "dim", seconds: 1800))
        #expect(parse("jrbar://quiet?mode=asks-only&for=1h") == .quiet(mode: "asks_only", seconds: 3600))
        #expect(parse("jrbar://quiet?mode=dnd") == .quiet(mode: "pause", seconds: 3600))
        #expect(parse("jrbar://quiet/end") == .endQuiet)
        #expect(parse("jrbar://quiet?for=0") == .endQuiet)
        #expect(parse("jrbar://quiet?mode=loud") == nil)
    }

    @Test func theRestOfTheVocabulary() {
        #expect(parse("jrbar://screenbar") == .screenBar(on: nil))
        #expect(parse("jrbar://screenbar/off") == .screenBar(on: false))
        #expect(parse("jrbar://confetti") == .confetti())
        #expect(parse("jrbar://menubar/reveal") == .menuBar(.reveal))
        #expect(parse("jrbar://menubar/command-bar") == .menuBar(.commandBar))
        #expect(parse("jrbar://ask") == .revealAsk)
        #expect(parse("jrbar://shelf") == .shelf)
        #expect(parse("jrbar://session?id=claude%3Asession%3Aabc") == .openSession("claude:session:abc"))
    }

    @Test func everyCommandsLinkReadsBackAsItself() {
        var commands: [AppCommand] = [
            .panel(toggle: false), .panel(toggle: true),
            .settings(page: nil), .settings(page: "notifications"),
            .toggle(.darkMode, on: nil), .toggle(.keepAwake, on: true), .toggle(.mute, on: false),
            .keepAwake(seconds: nil), .keepAwake(seconds: 0), .keepAwake(seconds: 5400),
            .quiet(mode: nil, seconds: 3600), .quiet(mode: "asks_only", seconds: 900), .endQuiet,
            .deepWork(seconds: 1500),
            .screenBar(on: nil), .screenBar(on: true), .screenBar(on: false),
            .confetti(), .confetti(tint: .provider("codex")), .confetti(tint: .session("claude:session:abc")),
            .openSession("claude:session:abc"), .revealAsk, .shelf,
            .overviewGraph, .aquarium,
        ]
        commands += AppCommand.AppWindow.allCases.map(AppCommand.window)
        commands += AppCommand.MenuBarVerb.allCases.map(AppCommand.menuBar)
        for command in commands {
            #expect(AppCommand.parse(command.link) == command, "\(command.link.absoluteString)")
        }
    }

    @Test func aSessionLinkCarriesItsIDInTheQuery() {
        #expect(AppCommand.openSession("claude:session:abc").link.absoluteString
                == "jrbar://session?id=claude:session:abc")
        // Whatever an id holds arrives whole: nothing in it reads as the
        // link's own structure.
        for id in ["codex:session:a b", "odd&id=1+2#x/y?z", "café:session:ü", "remote:studio-mac:claude:session:9"] {
            let link = AppCommand.openSession(id).link
            #expect(link.absoluteString.hasPrefix("jrbar://session?id="))
            #expect(AppCommand.parse(link) == .openSession(id), "\(link.absoluteString)")
        }
    }

    @Test func aConfettiLinkNamesWhoseColoursItWears() {
        #expect(parse("jrbar://confetti?provider=Codex") == .confetti(tint: .provider("codex")))
        #expect(parse("jrbar://confetti?session=claude%3Asession%3Aabc") == .confetti(tint: .session("claude:session:abc")))
        #expect(parse("jrbar://confetti?session=0199-abc") == .confetti(tint: .session("0199-abc")))
        // One target, like `jrbar confetti`; a malformed one is refused whole.
        #expect(parse("jrbar://confetti?provider=codex&session=abc") == nil)
        #expect(parse("jrbar://confetti?provider=not%20one") == nil)
        #expect(parse("jrbar://confetti?provider=") == nil)
        #expect(parse("jrbar://confetti?session=") == nil)
        #expect(parse("jrbar://confetti/codex") == nil)
    }

    @Test func aBurstWearsTheNamedProviderThenTheSessionsThenTheFocused() {
        let sessions = [
            CoreSession(id: "claude:session:abc", provider: "claude"),
            CoreSession(id: "claude:agent:w1", provider: "claude", kind: "worker", parent: "claude:session:abc"),
            CoreSession(id: "codex:session:xyz", provider: "codex"),
        ]
        let lookup: (String) -> String? = { AppCommand.provider(ofSession: $0, in: sessions) }
        #expect(AppCommand.provider(ofSession: "codex:session:xyz", in: sessions) == "codex")
        // A hook's own session id names its main row.
        #expect(AppCommand.provider(ofSession: "abc", in: sessions) == "claude")
        #expect(AppCommand.provider(ofSession: "ghost", in: sessions) == nil)
        #expect(AppCommand.confettiProvider(.provider("gemini"), focused: "codex:session:xyz", providerOf: lookup) == "gemini")
        #expect(AppCommand.confettiProvider(.session("abc"), focused: "codex:session:xyz", providerOf: lookup) == "claude")
        #expect(AppCommand.confettiProvider(.focused, focused: "codex:session:xyz", providerOf: lookup) == "codex")
        // Nothing focused, or a session nobody watches: the Toys tint.
        #expect(AppCommand.confettiProvider(.focused, focused: nil, providerOf: lookup) == nil)
        #expect(AppCommand.confettiProvider(.session("ghost"), focused: "codex:session:xyz", providerOf: lookup) == nil)
    }

    @MainActor
    @Test func theRouterHandsTheTintToTheBurst() {
        let router = AppCommandRouter()
        var tints: [AppCommand.ConfettiTint] = []
        router.fireConfetti = { tints.append($0) }
        #expect(router.open(URL(string: "jrbar://confetti?provider=codex")!) == .done)
        #expect(router.perform(.confetti()) == .done)
        #expect(tints == [.provider("codex"), .focused])
    }

    @Test func noLinkAnswersAnAskOrRewritesTheMenuBar() {
        // Approve and Deny stay where the ask is on screen; Hide all and
        // Show all rewrite the curated map. Neither is a link.
        #expect(parse("jrbar://ask/approve") == nil)
        #expect(parse("jrbar://answer?decision=approve") == nil)
        #expect(parse("jrbar://menubar/hide-all") == nil)
        #expect(parse("jrbar://menubar/show-all") == nil)
        #expect(parse("https://example.com/panel") == nil)
    }

    @Test func durationsRefuseTyposRatherThanReadZero() {
        #expect(AppCommand.duration("90") == 90)
        #expect(AppCommand.duration("90s") == 90)
        #expect(AppCommand.duration("15m") == 900)
        #expect(AppCommand.duration("1d") == 86_400)
        #expect(AppCommand.duration("") == nil)
        #expect(AppCommand.duration("m") == nil)
        #expect(AppCommand.duration("5 m") == 300)
        #expect(AppCommand.duration("-5") == nil)
        #expect(AppCommand.duration("99999999999999999999h") == nil)
    }

    // MARK: The router

    @MainActor
    @Test func anUnwiredOrRefusingCommandIsSaidOutLoud() {
        let router = AppCommandRouter()
        var said: [String] = []
        router.onRefused = { said.append($0) }
        #expect(router.perform(.confetti()) != .done)
        router.revealAsk = { "No agent is waiting on you." }
        #expect(router.perform(.revealAsk) == .refused("No agent is waiting on you."))
        var opened: [Bool] = []
        router.showPanel = { opened.append($0) }
        #expect(router.perform(.panel(toggle: true)) == .done)
        #expect(opened == [true])
        #expect(router.open(URL(string: "jrbar://nonsense")!) != .done)
        #expect(said.count == 3)
    }

    @MainActor
    @Test func theGraphAndTheTankLinksReachTheirOwnHands() {
        let router = AppCommandRouter()
        var said: [String] = []
        router.onRefused = { said.append($0) }
        // Unwired, each is refused out loud like any other surface.
        #expect(router.perform(.overviewGraph) == .refused("JR-Bar is still starting."))
        #expect(router.perform(.aquarium) == .refused("JR-Bar is still starting."))
        var hands: [String] = []
        router.openWindow = { hands.append("window:\($0.rawValue)") }
        router.openOverviewGraph = { hands.append("graph") }
        router.openAquarium = {
            hands.append("aquarium")
            return nil
        }
        #expect(router.open(URL(string: "jrbar://overview/graph")!) == .done)
        #expect(router.open(URL(string: "jrbar://overview")!) == .done)
        #expect(router.open(URL(string: "jrbar://aquarium")!) == .done)
        #expect(router.open(URL(string: "jrbar://aquarium")!) == .done, "a second open is the same open")
        #expect(hands == ["graph", "window:overview", "aquarium", "aquarium"])
        // The tank's own refusal is said the same way.
        router.openAquarium = { "JR-Bar is still starting." }
        #expect(router.perform(.aquarium) == .refused("JR-Bar is still starting."))
        #expect(said.count == 3)
    }

    // MARK: Deep work

    @Test func deepWorkLinks() {
        #expect(parse("jrbar://deepwork") == .deepWork(seconds: 1500))
        #expect(parse("jrbar://deep-work?for=50m") == .deepWork(seconds: 3000))
        #expect(parse("jrbar://deepwork/end") == .endQuiet)
        #expect(parse("jrbar://deepwork?for=30s") == nil, "shorter than a minute is not a stretch")
        #expect(parse("jrbar://deepwork?for=2d") == nil)
        #expect(parse("jrbar://deepwork/later") == nil)
        #expect(AppShortcutCatalog.action(id: "action.deepWork")?.command == .deepWork(seconds: 1500))
    }

    @Test func theSummaryCountsOnlyWhatChangedDuringTheStretch() {
        let before = DeepWork.snapshot([
            CoreSession(id: "a", provider: "claude", mode: "working", lifecycle: "active"),
            CoreSession(id: "b", provider: "codex", mode: "completed", lifecycle: "completed"),
            CoreSession(id: "c", provider: "claude", mode: "working", lifecycle: "active"),
        ])
        let after = [
            CoreSession(id: "a", provider: "claude", mode: "completed", lifecycle: "completed"),
            CoreSession(id: "b", provider: "codex", mode: "completed", lifecycle: "completed"),
            CoreSession(id: "c", provider: "claude", mode: "blocked_error", lifecycle: "failed"),
            CoreSession(id: "d", provider: "codex", mode: "waiting_for_input", lifecycle: "active"),
            CoreSession(id: "e", provider: "claude", mode: "completed", lifecycle: "completed"),
        ]
        #expect(DeepWork.summary(before: before, after: after, elapsedSeconds: 1500, early: false)
                == "Deep work over (25 min): 2 sessions finished, 1 failed and 1 needs you.")
        #expect(DeepWork.summary(before: before, after: Array(after.prefix(2)), elapsedSeconds: 610, early: true)
                == "Deep work ended after 10 min: 1 session finished.")
        #expect(DeepWork.summary(before: before, after: [], elapsedSeconds: 20, early: true)
                == "Deep work ended after 1 min: the agents had nothing new.")
    }

    @MainActor
    @Test func theRouterHoldsAsksOnlyQuietAndSaysWhatHappened() {
        let router = AppCommandRouter()
        var clock = Date(timeIntervalSince1970: 1_000)
        router.now = { clock }
        var scheduled: [(TimeInterval, DispatchWorkItem)] = []
        router.schedule = { scheduled.append(($0, $1)) }
        var quiets: [(String?, Int)] = []
        router.quiet = { quiets.append(($0, $1)); return nil }
        router.endQuiet = { nil }
        var sessions = [CoreSession(id: "a", provider: "claude", mode: "working", lifecycle: "active")]
        router.sessionsNow = { sessions }
        var lines: [String] = []
        router.onDeepWorkSummary = { lines.append($0) }

        #expect(router.perform(.deepWork(seconds: 1500)) == .done)
        #expect(quiets.count == 1 && quiets[0].0 == "asks_only" && quiets[0].1 == 1500)
        #expect(router.isInDeepWork)
        #expect(scheduled.first?.0 == 1500)
        sessions = [CoreSession(id: "a", provider: "claude", mode: "completed", lifecycle: "completed")]
        clock = clock.addingTimeInterval(1500)
        scheduled.first?.1.perform()
        #expect(lines == ["Deep work over (25 min): 1 session finished."])
        #expect(!router.isInDeepWork)

        // Ending quiet by hand closes the stretch early, with its line.
        router.perform(.deepWork(seconds: 1500))
        clock = clock.addingTimeInterval(300)
        router.perform(.endQuiet)
        #expect(lines.last == "Deep work ended after 5 min: the agents had nothing new.")
        #expect(scheduled.last?.1.isCancelled == true)

        // Another quiet takes over without a word.
        router.perform(.deepWork(seconds: 1500))
        router.perform(.quiet(mode: "dim", seconds: 600))
        #expect(!router.isInDeepWork)
        #expect(lines.count == 2)
    }

    @MainActor
    @Test func aRefusedQuietStartsNoStretch() {
        let router = AppCommandRouter()
        router.quiet = { _, _ in "The monitor is not connected — quiet needs it." }
        router.onRefused = { _ in }
        #expect(router.perform(.deepWork(seconds: 1500)) == .refused("The monitor is not connected — quiet needs it."))
        #expect(!router.isInDeepWork)
    }

    // MARK: App shortcuts

    @Test func theRetiredRevealKeyIsReadFromTheDaemonsSettings() {
        let shortcuts: JSONValue = .object([
            "reveal_current_ask": .object([
                "key_code": .number(Double(kVK_ANSI_R)),
                "key_label": .string("R"),
                "modifiers": .array([.string("control"), .string("option"), .string("command")]),
            ]),
        ])
        #expect(AppShortcutCatalog.legacyRevealAskChord(from: shortcuts)
                == HotkeyChord(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(controlKey | optionKey | cmdKey)))
        #expect(AppShortcutCatalog.legacyRevealAskChord(from: nil) == nil)
        let bad: JSONValue = .object(["reveal_current_ask": .object([
            "key_code": .number(15), "modifiers": .array([.string("hyper")]),
        ])])
        #expect(AppShortcutCatalog.legacyRevealAskChord(from: bad) == nil)
    }

    @MainActor
    @Test func theLegacyKeyIsAdoptedOnceAndNeverOverAChoice() throws {
        let suite = "AppCommandTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let hotkeys = AppHotkeys()
        hotkeys.defaults = defaults
        hotkeys.center = HotkeyCenter(registrar: HotkeyCenterTests.Recorder())
        let shortcuts: JSONValue = .object([
            "reveal_current_ask": .object([
                "key_code": .number(Double(kVK_ANSI_R)),
                "modifiers": .array([.string("control"), .string("option")]),
            ]),
        ])
        hotkeys.adoptLegacy(shortcuts: shortcuts)
        let expected = HotkeyChord(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(controlKey | optionKey))
        #expect(hotkeys.chord(for: AppShortcutCatalog.revealAskID) == expected)
        #expect(hotkeys.center.status(of: AppShortcutCatalog.revealAskID) == .active(expected))

        // A person who cleared the row keeps it cleared.
        let other = AppHotkeys()
        other.defaults = defaults
        other.center = HotkeyCenter(registrar: HotkeyCenterTests.Recorder())
        other.setChord(nil, for: AppShortcutCatalog.revealAskID)
        other.adoptLegacy(shortcuts: shortcuts)
        #expect(other.chord(for: AppShortcutCatalog.revealAskID) == nil)
    }

    @Test func everyChipHasAnActionAndEveryIDIsUnique() {
        let ids = AppShortcutCatalog.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        for toggle in SystemToggle.allCases {
            #expect(AppShortcutCatalog.action(id: AppShortcutCatalog.toggleID(toggle))?.command
                    == .toggle(toggle, on: nil))
        }
    }
}
