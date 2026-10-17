import Foundation
import Testing
@testable import JRBarCore
@testable import JRBarApp

@Suite("Panel open order")
@MainActor
struct PanelOpenOrderTests {
    @Test("an old open cannot close a reopened panel or replace its feedback", .timeLimit(.minutes(1)))
    func oldOpenAfterReopenIsDropped() async {
        for refusal in [nil, "Could not find the old session"] as [String?] {
            let suite = ScratchDefaults.suiteName("panel-open-order")
            defer { ScratchDefaults.remove(suite) }
            let store = PanelStore(core: CoreModel(), draftsDefaults: ScratchDefaults.open(suite),
                                   screenBarShown: false)
            let gate = OverviewLoadOrderTests.Gate<String?>()
            var finished: CheckedContinuation<Void, Never>?
            store.opener = { _ in
                let result = try? await gate.request()
                finished?.resume()
                return result
            }
            var closes = 0
            store.onClose = { closes += 1 }
            let row = SessionRow(session: CoreSession(id: "claude:session:open", provider: "claude",
                                                      label: "Old session", mode: "working"), pinnedAsk: nil)
            store.panelDidOpen()
            store.open(row)
            await gate.untilRequests(1)
            store.panelDidClose()
            store.panelDidOpen()
            store.toast = "Current panel feedback"
            await withCheckedContinuation { continuation in
                finished = continuation
                gate.answer(1, with: refusal)
            }
            #expect(closes == 0)
            #expect(store.toast == "Current panel feedback")
            store.panelDidClose()
        }
    }
    @Test("a confirmed open closes the current panel", .timeLimit(.minutes(1)))
    func currentOpenCloses() async {
        await withScratchDefaults("panel-current-open") { defaults in
            let store = PanelStore(core: CoreModel(), draftsDefaults: defaults, screenBarShown: false)
            store.opener = { _ in nil }
            let row = SessionRow(session: CoreSession(id: "claude:session:open", provider: "claude",
                                                      label: "Current session", mode: "working"), pinnedAsk: nil)
            store.panelDidOpen()
            await withCheckedContinuation { continuation in
                store.onClose = { continuation.resume() }
                store.open(row)
            }
            store.panelDidClose()
        }
    }

    @Test("a newer open owns feedback and closing within the same panel lifetime", .timeLimit(.minutes(1)))
    func newerOpenOwnsPanel() async {
        for refusal in [nil, "Old refusal"] as [String?] {
            let suite = ScratchDefaults.suiteName("panel-open-request")
            defer { ScratchDefaults.remove(suite) }
            let store = PanelStore(core: CoreModel(), draftsDefaults: ScratchDefaults.open(suite),
                                   screenBarShown: false)
            let gate = OverviewLoadOrderTests.Gate<String?>()
            var finished: CheckedContinuation<Void, Never>?
            store.opener = { _ in
                let result = try? await gate.request()
                finished?.resume()
                return result
            }
            var closes = 0
            store.onClose = { closes += 1 }
            let old = SessionRow(session: CoreSession(id: "claude:old", provider: "claude",
                                                     label: "Old", mode: "working"), pinnedAsk: nil)
            let current = SessionRow(session: CoreSession(id: "claude:current", provider: "claude",
                                                         label: "Current", mode: "working"), pinnedAsk: nil)
            store.panelDidOpen()
            store.open(old)
            await gate.untilRequests(1)
            store.open(current)
            await gate.untilRequests(2)
            store.toast = "Current feedback"
            await withCheckedContinuation { continuation in
                finished = continuation
                gate.answer(1, with: refusal)
            }
            #expect(closes == 0)
            #expect(store.toast == "Current feedback")
            await withCheckedContinuation { continuation in
                finished = continuation
                gate.answer(2, with: nil)
            }
            #expect(closes == 1)
            store.panelDidClose()
        }
    }

    @Test("selecting another row retires the pending open result", .timeLimit(.minutes(1)))
    func changedSelectionKeepsPanel() async {
        let suite = ScratchDefaults.suiteName("panel-open-selection")
        defer { ScratchDefaults.remove(suite) }
        let store = PanelStore(core: CoreModel(), draftsDefaults: ScratchDefaults.open(suite),
                               screenBarShown: false)
        let gate = OverviewLoadOrderTests.Gate<String?>()
        var finished: CheckedContinuation<Void, Never>?
        store.opener = { _ in
            let result = try? await gate.request()
            finished?.resume()
            return result
        }
        var closes = 0
        store.onClose = { closes += 1 }
        store.panelDidOpen()
        store.open(SessionRow(session: CoreSession(id: "claude:old", provider: "claude",
                                                  label: "Old", mode: "working"), pinnedAsk: nil))
        await gate.untilRequests(1)
        store.selectedID = "claude:current"
        await withCheckedContinuation { continuation in
            finished = continuation
            gate.answer(1, with: nil)
        }
        #expect(closes == 0)
        store.panelDidClose()
    }

    @Test("the light explanation opens its session without requiring a selected row", .timeLimit(.minutes(1)))
    func explainedSessionOpensWithoutSelection() async throws {
        let suite = ScratchDefaults.suiteName("panel-explained-open")
        defer { ScratchDefaults.remove(suite) }
        let core = CoreModel()
        core.handle(.connected)
        let surface = CoreLightSurface(program: "#FF3A00 1.6s pulse\nrepeat", ledCount: 8,
                                       motion: "beat", staticFallback: "#FF3A00", why: "needs_you")
        core.apply(.lights(CoreLights(surfaces: ["hardware": surface, "screen_bar": surface])))
        core.apply(.state(CoreState(
            sessions: [CoreSession(id: "claude:explained", provider: "claude", label: "Explained",
                                   mode: "waiting", lifecycle: "active")],
            asks: [CoreAsk(session: "claude:explained", kind: "permission", summary: "Run")])))
        let store = PanelStore(core: core, draftsDefaults: ScratchDefaults.open(suite), screenBarShown: false)
        store.panelDidOpen()
        defer { store.panelDidClose() }
        #expect(store.selectedID == nil)
        let explained = try #require(store.lightExplanation?.session)
        #expect(explained == "claude:explained")
        var opened: [String] = []
        store.opener = { opened.append($0); return nil }
        await withCheckedContinuation { continuation in
            store.onClose = { continuation.resume() }
            store.openExplainedSession()
        }
        #expect(opened == ["claude:explained"])
        #expect(store.selectedID == nil)
    }

}
