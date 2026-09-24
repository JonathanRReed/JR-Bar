import Foundation
import Testing
@testable import JRBarApp
@testable import JRBarCore

/// The panel's usage section: when its sparklines are asked for, and
/// what each row says. The daemon is staged; nothing reaches a socket.
@Suite("Panel usage")
@MainActor
struct PanelUsageTests {
    @MainActor
    final class Log {
        var calls: [String] = []
    }

    private func liveCore(asks: [CoreAsk] = []) -> CoreModel {
        let core = CoreModel()
        core.handle(.connected)
        core.apply(.state(CoreState(
            sessions: [CoreSession(id: "claude:a", provider: "claude", mode: "working")], asks: asks,
            usage: CoreUsage(providers: [CoreProviderUsage(id: "claude", windows: [
                CoreUsageWindow(name: "5h", usedPct: 40),
            ])]))))
        return core
    }

    private func makeStore(_ core: CoreModel, asked: Log) -> PanelStore {
        let store = PanelStore(core: core, draftsDefaults: UserDefaults(suiteName: "jrbar.tests.\(UUID())")!,
                               screenBarShown: false)
        store.sparklineWait = 0.05
        store.fetchUsageHistory = { provider, _ in
            asked.calls.append(provider)
            throw CoreClientError.notConnected
        }
        return store
    }

    /// Polls until `until` holds. The deadline is generous because a full
    /// parallel run can keep the main actor busy for seconds at a time;
    /// a passing wait returns as soon as the condition does.
    private func settle(within seconds: TimeInterval = 30, _ until: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !until(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("the sparklines are asked for a beat after the panel opens, not on the way to showing it")
    func sparklinesWaitABeat() async {
        let asked = Log()
        let store = makeStore(liveCore(), asked: asked)
        store.panelDidOpen()
        #expect(asked.calls.isEmpty, "nothing queues ahead of the panel's first clicks")
        await settle { !asked.calls.isEmpty }
        #expect(asked.calls == ["claude"])
        store.panelDidClose()
    }

    @Test("a panel closed within the beat asks for nothing")
    func closedBeforeTheBeat() async throws {
        let asked = Log()
        let store = makeStore(liveCore(), asked: asked)
        store.panelDidOpen()
        store.panelDidClose()
        try await Task.sleep(for: .milliseconds(200))
        #expect(asked.calls.isEmpty)
    }

    @Test("no sparklines while an ask is open: every usage_history waits in line ahead of its answer")
    func noSparklinesWithAnAsk() async throws {
        let asked = Log()
        let ask = CoreAsk(session: "claude:a", kind: "permission", summary: "Run", answerable: true)
        let store = makeStore(liveCore(asks: [ask]), asked: asked)
        store.panelDidOpen()
        try await Task.sleep(for: .milliseconds(200))
        #expect(asked.calls.isEmpty)
        store.refreshSparklines(force: true)
        try await Task.sleep(for: .milliseconds(50))
        #expect(asked.calls.isEmpty, "the ready event waits for the ask too")
        store.panelDidClose()
        #expect(PanelStore.wantsSparklines(live: true, asksOpen: false))
        #expect(!PanelStore.wantsSparklines(live: true, asksOpen: true))
        #expect(!PanelStore.wantsSparklines(live: false, asksOpen: false))
    }

    // MARK: What each row says

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func provider(_ id: String, _ pct: Double?, state: String? = nil, fidelity: String? = nil,
                          resetsIn: Double? = 3 * 3600, forecast: CoreUsageForecast? = nil,
                          incident: String? = nil, action: String? = nil) -> CoreProviderUsage {
        let reset = resetsIn.map { now.timeIntervalSince1970 + $0 }
        return CoreProviderUsage(id: id, windows: [CoreUsageWindow(key: "5h", name: "5h", usedPct: pct, resetsAt: reset)],
                                 fidelity: fidelity, state: state, forecast: forecast, action: action, incident: incident)
    }

    private func resetLine(_ usage: CoreProviderUsage, noRoom: Bool = false) -> String {
        let windows = PanelStore.windows(of: usage)
        return PanelStore.usageResetLine(for: usage, primary: windows.primary, secondary: windows.secondary,
                                         noRoomForOneMore: noRoom, now: now)
    }

    private func tag(_ usage: CoreProviderUsage, heldIdle: Bool = false) -> PanelStore.UsageTag? {
        PanelStore.usageTag(for: usage, primary: PanelStore.windows(of: usage).primary, heldIdle: heldIdle, now: now)
    }

    @Test("a row's tag says one thing: Stale, Used up or Runs out in X, and nothing on track")
    func oneTagEach() {
        #expect(tag(provider("claude", 40)) == nil, "on track says nothing")
        #expect(tag(provider("claude", 40, state: "stale")) == .stale)
        #expect(tag(provider("claude", 100, state: "stale")) == .stale, "an old 100 % is old first")
        #expect(tag(provider("claude", 100)) == .usedUp)
        #expect(tag(provider("claude", 60, forecast: CoreUsageForecast(pace: "exhausted"))) == .usedUp)
        let soon = CoreUsageForecast(exhaustsAt: now.timeIntervalSince1970 + 2 * 3600 + 5 * 60, pace: "ahead")
        #expect(tag(provider("claude", 70, forecast: soon)) == .runsOut("in 2h 05m"))
        #expect(PanelStore.UsageTag.runsOut("in 2h 05m").text == "Runs out in 2h 05m")
        #expect(tag(provider("claude", 70, forecast: soon), heldIdle: true) == nil, "a held-idle slope is history")
        let late = CoreUsageForecast(exhaustsAt: now.timeIntervalSince1970 + 5 * 3600, pace: "behind")
        #expect(tag(provider("claude", 70, forecast: late)) == nil, "a window that resets first is on track")
        #expect(tag(provider("claude", 40, incident: "Elevated errors")) == .incident("Elevated errors"))
    }

    @Test("past its reset a window says it is waiting for a new reading, and no pace says 'resets first'")
    func resetWords() {
        #expect(PanelStore.countdown(to: now.timeIntervalSince1970 - 5, now: now) == "reset — waiting for a new reading")
        #expect(PanelStore.countdown(to: now.timeIntervalSince1970 + 90 * 60, now: now) == "resets in 1h 30m")
        #expect(PanelStore.paceHint("behind") == nil)
        #expect(PanelStore.paceHint("under") == nil)
        #expect(PanelStore.paceHint("ahead") == "runs out early")
    }

    @Test("a stale source leads with its fix and never says it is waiting for a reading")
    func staleLeadsWithTheFix() {
        let broken = provider("claude", 19, state: "stale", resetsIn: -37 * 60, action: "Reconnect Claude")
        #expect(resetLine(broken) == "Reconnect Claude")
        #expect(!resetLine(broken, noRoom: true).contains("no room"), "an old burn answers nothing")
        let weekly = CoreUsageWindow(key: "7d", name: "7d", usedPct: 12, resetsAt: now.timeIntervalSince1970 + 3 * 86_400)
        var both = broken
        both.windows.append(weekly)
        #expect(resetLine(both) == "Reconnect Claude · 7d resets in 3d 0h", "a reset still ahead is still true")
        let grok = provider("grok", 31, state: "stale", resetsIn: -3600, action: "Run grok login")
        #expect(resetLine(grok) == "Run grok login")

        // Without a fix to offer, the old wording stands; live rows are unchanged.
        #expect(resetLine(provider("claude", 19, state: "stale", resetsIn: -60)) == "5h reset — waiting for a new reading")
        #expect(resetLine(provider("claude", 40, action: "Retry")) == "5h resets in 3h 00m")
        #expect(resetLine(provider("claude", 40), noRoom: true) == "5h resets in 3h 00m · no room for +1")
        #expect(resetLine(provider("grok", nil, state: "needs_sign_in", resetsIn: nil, action: "Run grok login")) == "Run grok login")
    }

    @Test("the Stale tag's help names the fix when the daemon has one")
    func staleHelpNamesTheFix() {
        #expect(PanelStore.staleHelp(action: "Reconnect Claude")
                == "This reading is old — the last refresh did not land. Reconnect Claude to get a new one.")
        #expect(PanelStore.staleHelp(action: nil) == "This reading is old — the last refresh did not land")
        #expect(PanelStore.staleHelp(action: " ") == "This reading is old — the last refresh did not land")
    }

    @Test("0 %, windowless, not-found and disabled providers fold into one quiet row")
    func quietProvidersFold() {
        #expect(!PanelStore.foldsIntoQuietRow(provider("claude", 40)))
        #expect(!PanelStore.foldsIntoQuietRow(provider("claude", nil)), "no reading is not a zero")
        #expect(PanelStore.foldsIntoQuietRow(provider("gemini", 0)))
        #expect(PanelStore.foldsIntoQuietRow(provider("gemini", 0.3)), "rounds to 0 %")
        #expect(PanelStore.foldsIntoQuietRow(CoreProviderUsage(id: "grok", state: "needs_sign_in")))
        #expect(PanelStore.foldsIntoQuietRow(provider("copilot", 12, state: "disabled")))
        #expect(PanelStore.foldsIntoQuietRow(provider("cursor", 12, state: "source_not_found")))

        let quiet = [provider("gemini", 0), provider("zai", 0), CoreProviderUsage(id: "cursor", state: "source_not_found"),
                     provider("copilot", 12, state: "disabled")]
        #expect(PanelStore.quietSummary(quiet) == "2 at 0% · 1 not found · 1 off")
        #expect(PanelStore.quietSummary([CoreProviderUsage(id: "grok", state: "needs_sign_in")]) == "signed out")
        #expect(PanelStore.quietSummary([]) == "")
    }

    @Test("the quiet providers take one row between them in the panel's layout")
    func quietRowCountsOnce() {
        let core = CoreModel()
        core.handle(.connected)
        core.apply(.state(CoreState(usage: CoreUsage(providers: [
            CoreProviderUsage(id: "claude", windows: [CoreUsageWindow(name: "5h", usedPct: 40)]),
            CoreProviderUsage(id: "gemini", windows: [CoreUsageWindow(name: "Daily", usedPct: 0)]),
            CoreProviderUsage(id: "grok", state: "needs_sign_in"),
            CoreProviderUsage(id: "cursor", state: "source_not_found"),
        ]))))
        let store = makeStore(core, asked: Log())
        #expect(store.usage.map(\.id) == ["claude"])
        #expect(store.quietUsage.map(\.id) == ["gemini", "grok", "cursor"])
        #expect(store.layoutContent.usageProviders == 2)
    }
}
