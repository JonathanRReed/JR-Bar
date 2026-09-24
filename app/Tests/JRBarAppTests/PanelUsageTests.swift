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

    private func settle(within seconds: TimeInterval = 5, _ until: () -> Bool) async {
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
}
