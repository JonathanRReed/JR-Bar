import Foundation
import SwiftUI
import Testing
@testable import JRBarApp
@testable import JRBarCore

@MainActor
@Suite("Quiet command acknowledgements", .serialized, .timeLimit(.minutes(2)))
struct QuietAcknowledgementTests {
    @Test("a refused Quiet or End never announces success", arguments: [false, true])
    func refusalIsVisible(_ ending: Bool) async throws {
        try await withPanel { fixture, store in
            let action = ending ? store.endQuiet() : store.quietFor(seconds: 1800)
            try await fixture.pending(1)
            #expect(store.toast == nil, "No success is shown while the daemon is deciding")
            try await fixture.release(error: "refused")
            _ = await action.value
            #expect(store.toast == "Quiet failed: Synthetic refused")
        }
    }

    @Test("Deep Work cannot start while Quiet is unacknowledged or refused")
    func deepWorkWaitsForAcceptance() async throws {
        try await withPanel { fixture, store in
            let router = AppCommandRouter()
            router.schedule = { _, _ in }
            router.quiet = { mode, seconds, onApplied in
                let result = await store.requestQuiet(mode: mode ?? store.quietMode, seconds: seconds,
                                                      feedback: false, onApplied: onApplied).value
                if case .refused(let message) = result { return message }
                return nil
            }
            let action = Task { await router.perform(.deepWork(seconds: 1500)) }
            try await fixture.pending(1)
            #expect(!router.isInDeepWork)
            try await fixture.release(error: "refused")
            _ = await action.value
            #expect(!router.isInDeepWork)
        }
    }

    @Test("accepted feedback uses the daemon's mode and deadline")
    func acceptedReceiptOwnsFeedback() async throws {
        try await withPanel { fixture, store in
            var applied = 0
            store.onManualQuietApplied = { _ in applied += 1; #expect(store.isQuietChanging) }
            let action = store.requestQuiet(mode: "pause", seconds: 1800)
            #expect(store.isQuietChanging)
            try await fixture.pending(1)
            #expect(applied == 0 && store.toast == nil)
            let until = Date().addingTimeInterval(3600)
            try await fixture.release(result: ["until": .number(until.timeIntervalSince1970), "mode": .string("dim")])
            let result = await action.value
            #expect(result == .applied("Dimmed until \(PanelStore.clockTime(until))"))
            #expect(store.toast == "Dimmed until \(PanelStore.clockTime(until))")
            #expect(applied == 1 && !store.isQuietChanging)
        }
    }

    @Test("a second request is refused without releasing the first admission")
    func duplicateAdmission() async throws {
        try await withPanel { fixture, store in
            let action = store.quietFor(seconds: 1800)
            try await fixture.pending(1)
            let refused = await store.endQuiet().value
            #expect(refused == .refused("Quiet is already changing. Try again when it finishes."))
            #expect(store.isQuietChanging)
            try await fixture.pending(1)
            try await fixture.release(result: accepted())
            _ = await action.value
            #expect(!store.isQuietChanging)
        }
    }

    @Test("transport failure releases admission and preserves manual acceptance")
    func disconnectReportsFailure() async throws {
        try await withPanel { fixture, store in
            var applied = 0
            store.onManualQuietApplied = { _ in applied += 1 }
            let action = store.quietFor(seconds: 1800)
            try await fixture.pending(1)
            fixture.core.stop()
            #expect(await action.value == .refused("Quiet failed: \(MonitorWords.sentence)"))
            #expect(!store.isQuietChanging && applied == 0)
        }
    }

    @Test("invalid positive receipts do not trigger accepted callbacks", arguments: [JSONValue.null, .bool(true), .string("later")])
    func invalidReceiptIsRefused(_ until: JSONValue) async throws {
        try await withPanel { fixture, store in
            var applied = 0
            let action = store.requestQuiet(mode: "pause", seconds: 1800, onApplied: { _ in applied += 1 })
            try await fixture.pending(1)
            try await fixture.release(result: ["until": until, "mode": .string("pause")])
            #expect(await action.value == .refused("Quiet failed: the monitor returned an incomplete result."))
            #expect(applied == 0 && !store.isQuietChanging)
        }
    }

    @Test("ending the manual override does not claim an automatic schedule ended")
    func cancellationKeepsSchedule() async throws {
        try await withPanel { fixture, store in
            let data = Data(#"{"focus":{"mode":"dark","source":"schedule"}}"#.utf8)
            fixture.core.apply(.state(try JSONDecoder().decode(CoreState.self, from: data)))
            let action = store.endQuiet()
            try await fixture.pending(1)
            try await fixture.release(result: ["until": .null])
            #expect(await action.value == .applied("Temporary quiet override ended."))
            #expect(store.quiet?.mode == "dark" && store.quiet?.source == "schedule")
        }
    }

    @Test("an accepted callback completes while admission is still held")
    func acceptedBookkeepingIsAtomic() async throws {
        try await withPanel { fixture, store in
            var nested: Task<PanelStore.QuietResult, Never>?
            var callbacks = 0
            let action = store.requestQuiet(mode: "pause", seconds: 1800, onApplied: { _ in
                callbacks += 1
                #expect(store.isQuietChanging)
                nested = store.endQuiet()
            })
            try await fixture.pending(1)
            try await fixture.release(result: accepted())
            _ = await action.value
            let refused = await nested?.value
            #expect(refused == .refused("Quiet is already changing. Try again when it finishes."))
            #expect(callbacks == 1 && !store.isQuietChanging)
        }
    }

    @Test("the palette ticket hears only the eventual refusal")
    func paletteTicketWaitsForReceipt() async throws {
        try await withPanel { fixture, store in
            let ticket = PaletteVerbTicket()
            let action = PaletteVerbScope.$ticket.withValue(ticket) { store.quietFor(seconds: 1800) }
            try await fixture.pending(1)
            #expect(ticket.lines.isEmpty)
            try await fixture.release(error: "refused")
            _ = await action.value
            #expect(ticket.lines == ["Quiet failed: Synthetic refused"])
        }
    }

    @Test("refused replacement and End keep the accepted Deep Work stretch")
    func deepWorkKeepsAcceptedStretch() async throws {
        try await withPanel { fixture, store in
            let router = wiredRouter(store)
            let start = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
            router.now = { start }
            var scheduled: [(TimeInterval, DispatchWorkItem)] = []
            router.schedule = { scheduled.append(($0, $1)) }
            let begin = Task { await router.perform(.deepWork(seconds: 1500)) }
            try await fixture.pending(1)
            let until = start.addingTimeInterval(1200)
            try await fixture.release(result: ["until": .number(until.timeIntervalSince1970), "mode": .string("asks_only")])
            #expect(await begin.value == .done)
            #expect(router.isInDeepWork && scheduled.count == 1)
            #expect(scheduled[0].0 == 1200)
            for command in [AppCommand.deepWork(seconds: 600), .endQuiet] {
                let request = Task { await router.perform(command) }
                try await fixture.pending(1)
                try await fixture.release(error: "refused")
                #expect(await request.value == .refused("Quiet failed: Synthetic refused"))
                #expect(router.isInDeepWork && scheduled.count == 1)
            }
            let manual = store.quietFor(seconds: 600)
            try await fixture.pending(1)
            try await fixture.release(result: accepted())
            _ = await manual.value
            #expect(!router.isInDeepWork && scheduled[0].1.isCancelled)
        }
    }

    @Test("a panel End closes accepted Deep Work only after acknowledgement")
    func manualEndWaitsForReceipt() async throws {
        try await withPanel { fixture, store in
            let router = wiredRouter(store)
            var summaries: [String] = []
            router.onDeepWorkSummary = { summaries.append($0) }
            let begin = Task { await router.perform(.deepWork(seconds: 1500)) }
            try await fixture.pending(1)
            try await fixture.release(result: accepted(mode: "asks_only"))
            _ = await begin.value
            let end = store.endQuiet()
            try await fixture.pending(1)
            #expect(router.isInDeepWork && summaries.isEmpty)
            try await fixture.release(result: ["until": .null])
            _ = await end.value
            #expect(!router.isInDeepWork && summaries.count == 1)
        }
    }

    @Test("What's New waits for the router's actual refusal")
    func whatsNewWaitsForReceipt() async throws {
        try await withPanel { fixture, store in
            let router = wiredRouter(store)
            let controller = WhatsNewWindowController()
            controller.run = { await router.perform($0) }
            let action = Task { await controller.tryIt(.deepWork(seconds: 1500)) }
            try await fixture.pending(1)
            #expect(!router.isInDeepWork)
            try await fixture.release(error: "refused")
            #expect(await action.value == "Quiet failed: Synthetic refused")
            #expect(!router.isInDeepWork)
        }
    }

    @Test("changing Quiet leaves lighting and usage palette controls available")
    func quietAdmissionDoesNotHideOtherControls() async throws {
        try await withPanel { fixture, store in
            let window = CoreUsageWindow(key: "five-hour", name: "5h", usedPct: 25)
            let provider = CoreProviderUsage(id: "claude", windows: [window])
            fixture.core.apply(.state(CoreState(usage: CoreUsage(providers: [provider]))))
            let windows = PaletteWiring.Windows(overview: {}, usageCenter: { _ in }, history: {}, effects: {},
                deck: {}, replay: {}, panel: {}, checkForUpdates: {}, settings: { _ in })
            let lights = PaletteWiring.lights(panel: store, effects: EffectStudioStore(core: fixture.core))
            let usage = PaletteWiring.usage(panel: store, windows: windows)
            let quiet = PaletteWiring.quiet(panel: store)
            let lightIDs = lights.items().map(\.id)
            let usageIDs = usage.items().map(\.id)
            try #require(!lightIDs.isEmpty && !usageIDs.isEmpty)
            let action = store.quietFor(seconds: 1800)
            try await fixture.pending(1)
            #expect(quiet.items().isEmpty)
            #expect(lights.items().map(\.id) == lightIDs)
            #expect(usage.items().map(\.id) == usageIDs)
            try await fixture.release(error: "refused")
            _ = await action.value
        }
    }

    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func acknowledgementRenderProof() async throws {
        try await withPanel { fixture, store in
            store.animationsArmed = false
            let action = store.quietFor(seconds: 1800)
            try await fixture.pending(1)
            try WindowsRenderProofTests.write("quiet-pending", size: WindowsRenderProofTests.panelSize(store), plate: .glass) {
                WindowsRenderProofTests.panel(store)
            }
            try await fixture.release(error: "refused")
            _ = await action.value
            try WindowsRenderProofTests.write("quiet-refused", size: WindowsRenderProofTests.panelSize(store), plate: .glass) {
                WindowsRenderProofTests.panel(store)
            }
            let entry = WhatsNewEntry(id: "synthetic", symbol: "moon", title: "Synthetic command",
                                      detail: "Open a utility.", tryIt: .window(.usage), opens: "Opens Usage")
            try WindowsRenderProofTests.write("whats-new-pending-row", size: CGSize(width: 440, height: 100), plate: .glass) {
                WhatsNewView(entries: [entry], tryIt: { _ in nil }, onDone: {}).padding(16)
            }
        }
    }

    private func accepted(mode: String = "pause") -> [String: JSONValue] {
        ["until": .number(Date().addingTimeInterval(1800).timeIntervalSince1970), "mode": .string(mode)]
    }

    private func wiredRouter(_ store: PanelStore) -> AppCommandRouter {
        let router = AppCommandRouter()
        router.schedule = { _, _ in }
        router.onDeepWorkSummary = { _ in }
        router.quiet = { mode, seconds, onApplied in
            let result = await store.requestQuiet(mode: mode ?? store.quietMode, seconds: seconds,
                                                  feedback: false, onApplied: onApplied).value
            if case .refused(let message) = result { return message }
            return nil
        }
        router.endQuiet = { onApplied in
            let result = await store.requestQuiet(mode: store.quietMode, seconds: 0,
                                                  feedback: false, onApplied: onApplied).value
            if case .refused(let message) = result { return message }
            return nil
        }
        store.onManualQuietApplied = { [weak router] seconds in router?.manualQuietApplied(seconds: seconds) }
        return router
    }

    private func withPanel(_ body: (CoreCommandReplyFixture, PanelStore) async throws -> Void) async throws {
        let fixture = try CoreCommandReplyFixture()
        let suite = ScratchDefaults.suiteName("quiet-ack")
        defer { ScratchDefaults.remove(suite) }
        do {
            try await fixture.start()
            let panel = PanelStore(core: fixture.core, draftsDefaults: ScratchDefaults.open(suite), screenBarShown: false)
            try await body(fixture, panel)
            await fixture.stop()
        } catch {
            await fixture.stop()
            throw error
        }
    }
}
