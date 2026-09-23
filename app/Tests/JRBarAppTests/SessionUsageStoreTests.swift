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

    @Test("reading comes back soon; a missing transcript backs off, doubling to the cap")
    func backoff() {
        let store = SessionUsageStore(core: CoreModel())
        func due(_ id: String, after seconds: TimeInterval) -> Bool {
            SessionUsageStore.due([id], fetchedAt: store.fetchedAt, inFlight: [], now: Self.now.addingTimeInterval(seconds)) == [id]
        }
        store.apply(SessionUsageDocument(gaps: ["claude:r": "reading"]), asked: ["claude:r"], now: Self.now)
        #expect(!due("claude:r", after: 2))
        #expect(due("claude:r", after: 3))
        #expect(store.gap(for: "claude:r") == "reading")

        store.apply(SessionUsageDocument(gaps: ["claude:m": "transcript_not_found"]), asked: ["claude:m"], now: Self.now)
        #expect(!due("claude:m", after: 59))
        #expect(due("claude:m", after: 60))
        store.apply(SessionUsageDocument(gaps: ["claude:m": "transcript_not_found"]), asked: ["claude:m"], now: Self.now)
        #expect(!due("claude:m", after: 119))
        #expect(due("claude:m", after: 120))

        store.apply(SessionUsageDocument(gaps: ["grok:g": "unsupported_provider"]), asked: ["grok:g"], now: Self.now)
        #expect(!due("grok:g", after: 599))
        #expect(due("grok:g", after: 600))

        // An answer resets the backoff: the next miss starts at a minute again.
        store.apply(SessionUsageDocument(sessions: ["claude:m": SessionUsage(model: "claude-opus-4-5")]), asked: ["claude:m"], now: Self.now)
        store.apply(SessionUsageDocument(gaps: ["claude:m": "transcript_not_found"]), asked: ["claude:m"], now: Self.now)
        #expect(due("claude:m", after: 60))
    }

    @Test("the backoff stamps: cadence for the unknown, the cap for what cannot change")
    func stamps() {
        let freshFor = SessionUsageStore.freshFor
        #expect(SessionUsageStore.stamp(gap: nil, repeats: 0, now: Self.now) == Self.now)
        #expect(SessionUsageStore.stamp(gap: "transcript_unreadable", repeats: 3, now: Self.now) == Self.now)
        #expect(SessionUsageStore.stamp(gap: "not_found", repeats: 9, now: Self.now)
                == Self.now.addingTimeInterval(SessionUsageStore.settledBackoffCap - freshFor))
        #expect(SessionUsageStore.stamp(gap: "remote", repeats: 1, now: Self.now)
                == Self.now.addingTimeInterval(SessionUsageStore.settledBackoffCap - freshFor))
    }

    @Test("forgetting goes by the last ask: longest unasked first, never an id on the wire")
    func forgettable() {
        let asked = ["a": Self.now.addingTimeInterval(-300), "b": Self.now.addingTimeInterval(-10),
                     "c": Self.now.addingTimeInterval(-600), "d": Self.now.addingTimeInterval(-5)]
        let known: Set = ["a", "b", "c", "d", "e"]   // e was never asked about
        #expect(SessionUsageStore.forgettable(known: known, askedAt: asked, keeping: [], limit: 5).isEmpty)
        #expect(SessionUsageStore.forgettable(known: known, askedAt: asked, keeping: [], limit: 3) == ["e", "c"])
        #expect(SessionUsageStore.forgettable(known: known, askedAt: asked, keeping: ["e"], limit: 3) == ["c", "a"],
                "an answer on its way is kept")
    }

    @Test("the store holds every per-session map to its limit, however many sessions pass through")
    func bounded() {
        let store = SessionUsageStore(core: CoreModel())
        let limit = SessionUsageStore.rememberLimit
        let read = (0..<(limit + 40)).map { "claude:bounded-read-\($0)" }
        store.apply(SessionUsageDocument(sessions: Dictionary(uniqueKeysWithValues: read.map {
            ($0, SessionUsage(model: "claude-opus-4-5"))
        })), asked: read, now: Self.now)
        #expect(store.usage.count == limit)

        // The backoff's maps too: a missing transcript leaves a gap, a
        // stamp and a repeat count, all held to the same limit.
        let missing = (0..<(limit + 40)).map { "claude:bounded-gap-\($0)" }
        store.apply(SessionUsageDocument(gaps: Dictionary(uniqueKeysWithValues: missing.map {
            ($0, "transcript_not_found")
        })), asked: missing, now: Self.now)
        let known = Set(store.usage.keys).union(store.gaps.keys).union(store.fetchedAt.keys)
            .union(store.settledGaps.keys)
        #expect(known.count == limit)
    }

    @Test("a working set past the limit stays while a surface names it, and goes once none does")
    func workingSetKept() {
        let store = SessionUsageStore(core: CoreModel())
        let limit = SessionUsageStore.rememberLimit
        // ⌘A over a long roster: more rows selected than the store keeps.
        let shown = (0..<(limit + 100)).map { "claude:shown-\($0)" }
        let batches = store.plan(ids: shown, now: Self.now)
        #expect(batches.allSatisfy { $0.count <= SessionUsageStore.batchLimit })
        #expect(batches.flatMap { $0 } == shown)
        for batch in batches {
            store.apply(SessionUsageDocument(sessions: Dictionary(uniqueKeysWithValues: batch.map {
                ($0, SessionUsage(model: "claude-opus-4-5"))
            })), asked: batch, now: Self.now)
            store.landed(batch)
        }
        #expect(store.usage.count == limit + 100, "every row a surface shows keeps its reading")
        // The next tick names the same rows: nothing was forgotten, so
        // nothing goes back on the wire before `freshFor`.
        #expect(store.plan(ids: shown, now: Self.now.addingTimeInterval(1)).isEmpty)

        // The surface moves on. Past `wantedFor` the old rows are the
        // bound's again, and a new ask trims them to the limit.
        let later = Self.now.addingTimeInterval(1 + SessionUsageStore.wantedFor)
        let next = store.plan(ids: ["claude:next-a", "claude:next-b"], now: later)
        #expect(next == [["claude:next-a", "claude:next-b"]])
        #expect(store.fetchedAt.count == limit)
        #expect(store.fetchedAt["claude:next-a"] != nil, "the rows asked about now are kept")
    }

    @Test("the sort index forgets the rows no store has passed in longest; a sort's read is not a pass")
    func indexBounded() {
        let index = SessionUsageIndex(limit: 3)
        for (id, cost) in [("a", 1.0), ("b", 2.0), ("c", 3.0)] {
            index.update([id: SessionUsage(model: "claude-opus-4-5", estimatedCostUSD: cost)])
        }
        #expect(index.cost(for: "a") == 1)
        index.update(["d": SessionUsage(model: "claude-opus-4-5", estimatedCostUSD: 4)])
        #expect(index.count == 3)
        #expect(index.cost(for: "a") == nil, "read by a sort, not passed in again — it ages out")
        index.update(["b": SessionUsage(model: "claude-opus-4-5", estimatedCostUSD: 2)])
        index.update(["e": SessionUsage(model: "claude-opus-4-5", estimatedCostUSD: 5)])
        #expect(index.cost(for: "b") == 2, "passed in again, kept")
        #expect(index.cost(for: "c") == nil)
        #expect(index.model(for: "e") == "Opus 4.5")
        #expect(SessionUsageIndex.limit == 2 * SessionUsageStore.rememberLimit)
    }

    @Test("burners wait for every transcript before they rank")
    func burnersReading() {
        #expect(UsageCenterStore.burnersStillReading(["claude:a": "reading"]))
        #expect(!UsageCenterStore.burnersStillReading(["claude:a": "transcript_not_found"]))
        #expect(!UsageCenterStore.burnersStillReading([:]))
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

    @Test("type to find: every word must appear in what the row shows or knows")
    func find() {
        var row = SessionRow(session: CoreSession(id: "claude:a", provider: "claude", label: "auth refactor",
                                                  cwd: "/Users/j/Downloads/JR-Bar", mode: "working", tool: "Bash"),
                             pinnedAsk: nil)
        row.usage = SessionUsage(model: "claude-opus-4-5")
        #expect(row.matches("auth"))
        #expect(row.matches("OPUS jr-bar"))
        #expect(row.matches("claude bash"))
        #expect(!row.matches("auth codex"))
        #expect(!row.matches("   "))
    }

    @Test("the find field takes printable keys, and a space only inside a query")
    func findCharacters() {
        #expect(PanelStore.isFindCharacter("a", query: ""))
        #expect(PanelStore.isFindCharacter("-", query: ""))
        #expect(!PanelStore.isFindCharacter(" ", query: ""))
        #expect(PanelStore.isFindCharacter(" ", query: "auth"))
        #expect(!PanelStore.isFindCharacter("\r", query: ""))
        #expect(!PanelStore.isFindCharacter("\u{F700}", query: ""))
        #expect(!PanelStore.isFindCharacter("ab", query: ""))
    }

    @Test("the find query narrows, backspaces and clears; closing the panel forgets it")
    func findLifecycle() {
        let store = PanelStore(core: CoreModel(), draftsDefaults: UserDefaults(suiteName: "jrbar.test.find.\(UUID().uuidString)")!,
                               screenBarShown: false)
        store.appendFind("o")
        store.appendFind("p")
        #expect(store.findQuery == "op")
        #expect(store.deleteFindCharacter())
        #expect(store.findQuery == "o")
        #expect(store.clearFind())
        #expect(!store.clearFind())
        #expect(!store.deleteFindCharacter())
        store.appendFind("x")
        store.panelDidClose()
        #expect(store.findQuery.isEmpty)
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
