import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// The per-session usage store: which ids are worth asking about, what a
/// reply changes, and how a row turns it into the panel's model name and
/// context hairline.
@MainActor
@Suite struct SessionUsageStoreTests {
    static let now = Date(timeIntervalSince1970: 1_788_900_000)

    @Test("an id is due once per window; remote, duplicate and in-flight ids never are")
    func due() {
        let fetched = ["claude:a": Self.now.addingTimeInterval(-5), "claude:b": Self.now.addingTimeInterval(-60)]
        let due = SessionUsageStore.due(
            ["claude:a", "claude:b", "claude:c", "claude:c", "remote:studio:claude:x", "codex:d"],
            fetchedAt: fetched, inFlight: ["codex:d"], now: Self.now)
        #expect(due == ["claude:b", "claude:c"])
    }

    @Test("force re-asks a fresh id but still never a remote one")
    func force() {
        let due = SessionUsageStore.due(
            ["claude:a", "remote:studio:claude:x"],
            fetchedAt: ["claude:a": Self.now], inFlight: [], now: Self.now, force: true)
        #expect(due == ["claude:a"])
    }

    @Test("a reply fills usage, records gaps, and a vanished transcript keeps its last reading")
    func apply() {
        let store = SessionUsageStore(core: CoreModel())
        let usage = SessionUsage(model: "claude-opus-4-5", tokens: SessionUsageTokens(input: 10, output: 5),
                                 estimatedCostUSD: 1.5)
        store.apply(SessionUsageDocument(sessions: ["claude:a": usage], gaps: ["grok:b": "unsupported_provider"]),
                    asked: ["claude:a", "grok:b"])
        #expect(store.usage(for: "claude:a") == usage)
        #expect(store.gap(for: "grok:b") == "unsupported_provider")
        let generation = store.generation

        store.apply(SessionUsageDocument(gaps: ["claude:a": "transcript_not_found"]), asked: ["claude:a"])
        #expect(store.usage(for: "claude:a") == usage)
        #expect(store.gap(for: "claude:a") == "transcript_not_found")
        #expect(store.generation == generation)
        #expect(SessionUsageIndex.shared.cost(for: "claude:a") == 1.5)
        #expect(SessionUsageIndex.shared.model(for: "claude:a") == "Opus 4.5")
    }

    @Test("only a live row draws its context; the tooltip carries the summary")
    func rowContext() {
        let usage = SessionUsage(model: "claude-opus-4-5", tokens: SessionUsageTokens(input: 10, output: 5),
                                 contextTokens: 100_000, contextWindow: 200_000, contextWindowSource: "inferred")
        var working = SessionRow(session: CoreSession(id: "claude:a", provider: "claude", mode: "working", lifecycle: "active"),
                                 pinnedAsk: nil)
        working.usage = usage
        #expect(working.liveContextFraction == 0.5)
        #expect(working.help(now: Self.now)?.contains("Opus 4.5 · 15 tokens") == true)

        var finished = SessionRow(session: CoreSession(id: "claude:b", provider: "claude", mode: "done", lifecycle: "completed"),
                                  pinnedAsk: nil)
        finished.usage = usage
        #expect(finished.activity.isClearable)
        #expect(finished.liveContextFraction == nil)
    }

    @Test("the model breakdown shares follow the card's metric")
    func modelShares() {
        let models = [
            UsageHistoryModel(model: "opus-4-5", tokens: 100, costUsd: 3),
            UsageHistoryModel(model: "haiku-4-5", tokens: 300, costUsd: 1),
        ]
        let byTokens = UsageModelBreakdown.shares(models, metric: .tokens)
        #expect(byTokens.map(\.model.model) == ["haiku-4-5", "opus-4-5"])
        #expect(byTokens[0].share == 0.75)
        let byCost = UsageModelBreakdown.shares(models, metric: .cost)
        #expect(byCost.map(\.model.model) == ["opus-4-5", "haiku-4-5"])
        #expect(byCost[0].share == 0.75)
    }

    @Test("the hairline shares the quota bars' thresholds")
    func hairlineLevels() {
        #expect(ContextHairline.level(0.5) == .calm)
        #expect(ContextHairline.level(0.8) == .warning)
        #expect(ContextHairline.level(0.97) == .critical)
    }
}
