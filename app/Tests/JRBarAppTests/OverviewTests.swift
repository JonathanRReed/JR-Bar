import AppKit
import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// The Overview's selection model: presets, search, saved-filter
/// definitions, strip counts, and the keyboard walk — all over the
/// daemon's roster rows, none of it inventing a second projection.
@MainActor
@Suite struct OverviewTests {

    private static func entry(
        _ id: String,
        provider: String = "codex",
        kind: String = "main",
        label: String? = nil,
        cwd: String? = nil,
        mode: String? = "working",
        lifecycle: String? = "active",
        remote: Bool = false,
        ask: CoreAsk? = nil,
        pinned: Bool = false,
        visibility: String? = "live",
        outcome: String? = "none",
        review: String? = "pending",
        freshness: String? = "live",
        tool: String? = nil,
        message: String? = nil,
        workers: Int = 0
    ) -> CoreRosterEntry {
        CoreRosterEntry(
            session: CoreSession(
                id: id, provider: provider, kind: kind, label: label, cwd: cwd,
                mode: mode, lifecycle: lifecycle, ask: ask, workers: workers,
                remote: remote, tool: tool, message: message
            ),
            schema: 1, pinned: pinned, visibility: visibility,
            axes: (outcome == nil && review == nil && freshness == nil) ? nil
                : CoreSessionAxes(outcome: outcome, review: review, freshness: freshness)
        )
    }

    private static func store(with rows: [CoreRosterEntry]) -> OverviewStore {
        let store = OverviewStore(core: CoreModel())
        store.roster = rows
        return store
    }

    // MARK: Presets

    @Test func needsMeKeepsAskedAndPinnedRows() {
        let asked = Self.entry("a", ask: CoreAsk(session: "a", kind: "question", summary: "?"))
        let pinnedDone = Self.entry("b", mode: "completed", lifecycle: "completed",
                                    pinned: true, visibility: "hidden",
                                    outcome: "succeeded", review: "unreviewed", freshness: "delayed")
        let quiet = Self.entry("c")
        let store = Self.store(with: [asked, pinnedDone, quiet])
        store.filter = OverviewFilter(preset: .needsMe)
        #expect(store.rows.map(\.id) == ["a", "b"])
    }

    @Test func workingPresetUsesTheCanonicalStateWord() {
        let store = Self.store(with: [
            Self.entry("w", mode: "tool_running"),
            Self.entry("idle", mode: "idle_ready"),
            Self.entry("done", mode: "completed", lifecycle: "completed",
                       outcome: "succeeded", review: "unreviewed"),
        ])
        store.filter = OverviewFilter(preset: .working)
        #expect(store.rows.map(\.id) == ["w"])
    }

    @Test func unreviewedIsAnAxisNotAStateWord() {
        // A completed-but-failed run that nobody acknowledged still counts
        // as unreviewed: the axis is separate from outcome.
        let store = Self.store(with: [
            Self.entry("bad", mode: "completed", lifecycle: "failed",
                       outcome: "failed", review: "unreviewed", freshness: "live"),
            Self.entry("ok", mode: "completed", lifecycle: "completed",
                       outcome: "succeeded", review: "reviewed", freshness: "live"),
        ])
        store.filter = OverviewFilter(preset: .unreviewed)
        #expect(store.rows.map(\.id) == ["bad"])
    }

    @Test func thisProjectMatchesTheCwdTailNotASavedId() {
        let store = Self.store(with: [
            Self.entry("here", cwd: "/Users/x/Code/JR-Bar"),
            Self.entry("there", cwd: "/Users/x/Code/other"),
            Self.entry("nested", cwd: "/Users/x/work/JR-Bar"),
        ])
        // "JR-Bar" disambiguates by the parent component: the filter is
        // the two-component label, never a stored session id.
        store.filter = OverviewFilter(preset: .thisProject, project: "Code/JR-Bar")
        #expect(store.rows.map(\.id) == ["here"])
        store.filter = OverviewFilter(preset: .thisProject, project: "work/JR-Bar")
        #expect(store.rows.map(\.id) == ["nested"])
    }

    @Test func thisMacDropsRemoteRows() {
        let store = Self.store(with: [
            Self.entry("local"), Self.entry("away", remote: true),
        ])
        store.filter = OverviewFilter(preset: .thisMac)
        #expect(store.rows.map(\.id) == ["local"])
    }

    @Test func hiddenRowsStayInTheAllScope() {
        // T13: a session the panel's aging would hide is still a record.
        let store = Self.store(with: [
            Self.entry("shown", visibility: "live"),
            Self.entry("aged", mode: "ended_unconfirmed", lifecycle: "ended",
                       visibility: "hidden", outcome: "unreported",
                       review: "unreviewed", freshness: "delayed"),
        ])
        store.filter = OverviewFilter(preset: .all)
        #expect(store.rows.map(\.id) == ["shown", "aged"])
    }

    // MARK: Search

    @Test func searchCoversTitlesProjectsToolsAndMessages() {
        let row = Self.entry("s1", label: "Fix the flap", cwd: "/x/Code/JR-Bar",
                             tool: "Read", message: "rebased the branch")
        #expect(OverviewStore.matchesSearch(row, "flap"))
        #expect(OverviewStore.matchesSearch(row, "jr-bar"))
        #expect(OverviewStore.matchesSearch(row, "read"))
        #expect(OverviewStore.matchesSearch(row, "rebased"))
        #expect(!OverviewStore.matchesSearch(row, "submarine"))
    }

    @Test func searchComposesWithThePreset() {
        let store = Self.store(with: [
            Self.entry("a", label: "alpha", ask: CoreAsk(session: "a", summary: "?")),
            Self.entry("b", label: "beta", ask: CoreAsk(session: "b", summary: "?")),
        ])
        store.filter = OverviewFilter(preset: .needsMe)
        store.search = "beta"
        #expect(store.rows.map(\.id) == ["b"])
    }

    // MARK: Counts

    @Test func stripCountsTrackTheVisibleRows() {
        let store = Self.store(with: [
            Self.entry("live"),
            Self.entry("ask", ask: CoreAsk(session: "ask", summary: "?")),
            Self.entry("fin", lifecycle: "completed", visibility: "hidden",
                       outcome: "succeeded", review: "unreviewed"),
            Self.entry("gone", lifecycle: "ended", visibility: "hidden",
                       outcome: "unreported", review: "reviewed", freshness: "delayed"),
        ])
        store.filter = OverviewFilter(preset: .all)
        let counts = store.stripCounts
        #expect(counts.live == 2)
        #expect(counts.attention == 1)
        #expect(counts.unreviewed == 1)
        #expect(counts.hidden == 2)
    }

    // MARK: Ordering and keyboard

    @Test func attentionSortsFirstByDefault() {
        let store = Self.store(with: [
            Self.entry("plain"),
            Self.entry("ask", ask: CoreAsk(session: "ask", summary: "?")),
        ])
        store.filter = OverviewFilter(preset: .all)
        #expect(store.rows.first?.id == "ask")
    }

    @Test func selectionWalksTheVisibleRowsOnly() {
        let store = Self.store(with: [
            Self.entry("a", ask: CoreAsk(session: "a", summary: "?")),
            Self.entry("b"), Self.entry("c"),
        ])
        store.filter = OverviewFilter(preset: .needsMe)
        store.selectedID = nil
        store.moveSelection(by: 1)
        #expect(store.selectedID == "a")   // only "a" matches needs-me
        store.moveSelection(by: 1)
        #expect(store.selectedID == "a")   // clamps at the end
        store.filter = OverviewFilter(preset: .all)
        store.moveSelection(by: 1)
        #expect(store.selectedID == "b")
        store.moveSelection(by: -1)
        #expect(store.selectedID == "a")
    }

    @Test func columnSortReordersDeterministically() {
        let store = Self.store(with: [
            Self.entry("z", label: "zed"),
            Self.entry("a", label: "alpha"),
            Self.entry("m", label: "mid"),
        ])
        store.filter = OverviewFilter(preset: .all)
        store.sortOrder = [KeyPathComparator(\CoreRosterEntry.labelSortKey)]
        #expect(store.rows.map(\.id) == ["a", "m", "z"])
    }

    // MARK: Saved filters

    @Test func savedFiltersRoundTripAsDefinitions() {
        let defaults = UserDefaults(suiteName: "OverviewTests.\(UUID().uuidString)")!
        let saved = [SavedOverviewFilter(name: "JR-Bar asks",
                                         filter: OverviewFilter(preset: .thisProject, project: "Code/JR-Bar"))]
        OverviewSavedFilters.save(saved, defaults: defaults)
        let loaded = OverviewSavedFilters.load(defaults: defaults)
        #expect(loaded == saved)
        // The saved definition still matches a fresh row — it stored the
        // predicate, not the session ids it happened to see.
        let row = Self.entry("new", cwd: "/Users/x/Code/JR-Bar")
        #expect(loaded[0].filter.matches(row))
    }

    @Test func applyingASavedFilterMarksItActive() {
        let store = Self.store(with: [])
        let saved = SavedOverviewFilter(name: "mine", filter: OverviewFilter(preset: .unreviewed))
        store.apply(saved)
        #expect(store.filter.preset == .unreviewed)
        #expect(store.activeSavedFilter == "mine")
    }
}

/// The "make it incredible" pass: the attention-first default sort,
/// the failed axis, the ask-action gate, remote gating, apply-clears-
/// search, the widened search net, the one-pass memo, waiting-age
/// formatting, gap-preserving page merges, kind chips, and the
/// accessibility strings — all over the same roster rows.
@MainActor
@Suite struct OverviewIncredibleTests {

    private static func entry(
        _ id: String,
        provider: String = "codex",
        kind: String = "main",
        label: String? = nil,
        cwd: String? = nil,
        mode: String? = "working",
        lifecycle: String? = "active",
        remote: Bool = false,
        ask: CoreAsk? = nil,
        pinned: Bool = false,
        visibility: String? = "live",
        outcome: String? = "none",
        review: String? = "pending",
        freshness: String? = "live",
        parent: String? = nil,
        snoozedUntil: Double? = nil
    ) -> CoreRosterEntry {
        CoreRosterEntry(
            session: CoreSession(
                id: id, provider: provider, kind: kind, parent: parent, label: label, cwd: cwd,
                mode: mode, lifecycle: lifecycle, ask: ask, workers: 0,
                snoozedUntil: snoozedUntil, remote: remote
            ),
            schema: 1, pinned: pinned, visibility: visibility,
            axes: (outcome == nil && review == nil && freshness == nil) ? nil
                : CoreSessionAxes(outcome: outcome, review: review, freshness: freshness)
        )
    }

    private static func store(with rows: [CoreRosterEntry]) -> OverviewStore {
        let store = OverviewStore(core: CoreModel())
        store.roster = rows
        return store
    }

    // MARK: Default sort

    @Test func defaultSortIsWaitingThenFailedThenTheRest() {
        let store = Self.store(with: [
            Self.entry("idle", mode: "idle_ready"),
            Self.entry("working", mode: "tool_running"),
            Self.entry("done", mode: "completed", lifecycle: "completed",
                       outcome: "succeeded", review: "unreviewed"),
            Self.entry("failed", mode: "failed", lifecycle: "failed",
                       outcome: "failed", review: "unreviewed"),
            Self.entry("waiting", ask: CoreAsk(session: "waiting", summary: "?")),
            Self.entry("ended", lifecycle: "ended",
                       outcome: "unreported", review: "reviewed", freshness: "delayed"),
        ])
        store.filter = OverviewFilter(preset: .all)
        // sortRankKey default: the ask row first, then failed, working,
        // done, ended, idle — attention first, failures second.
        #expect(store.sortOrder.first.map { $0.keyPath == \CoreRosterEntry.sortRankKey } == true)
        #expect(store.rows.map(\.id) == ["waiting", "failed", "working", "done", "ended", "idle"])
    }

    // MARK: Failed preset + strip count

    @Test func failedPresetMatchesOutcomeAxisNotLifecycle() {
        let store = Self.store(with: [
            Self.entry("dead", outcome: "failed", review: "unreviewed"),
            Self.entry("ok", lifecycle: "completed", outcome: "succeeded", review: "reviewed"),
        ])
        store.filter = OverviewFilter(preset: .failed)
        #expect(store.rows.map(\.id) == ["dead"])
    }

    @Test func stripCountsReportFailedSeparately() {
        let store = Self.store(with: [
            Self.entry("live"),
            Self.entry("bad", mode: "failed", lifecycle: "failed",
                       outcome: "failed", review: "unreviewed"),
            Self.entry("ok", lifecycle: "completed", outcome: "succeeded",
                       review: "unreviewed"),
        ])
        store.filter = OverviewFilter(preset: .all)
        let counts = store.stripCounts
        #expect(counts.failed == 1)
        // Only the "live" row counts as live: failed and succeeded are
        // both terminal outcomes on the daemon's axis.
        #expect(counts.live == 1)
    }

    // MARK: Ask-action matrix

    @Test func askActionMatrixCoversAnswerableReplyableRemote() {
        let store = Self.store(with: [])
        let open = Self.entry("a", ask: CoreAsk(session: "a", summary: "?"))
        #expect(store.askAction(for: open) == .actionable)
        #expect(store.askDisabledReason(for: open) == nil)
        #expect(!store.canReply(open))   // replyable defaults to false

        let replyable = Self.entry("b", ask: CoreAsk(
            session: "b", summary: "?", replyable: true))
        #expect(store.canReply(replyable))

        let typed = Self.entry("c", ask: CoreAsk(
            session: "c", summary: "?", answerable: false, replyable: true))
        #expect(store.askAction(for: typed) == .notAnswerable)
        #expect(store.askDisabledReason(for: typed) != nil)
        #expect(!store.canReply(typed))

        let away = Self.entry("d", remote: true,
                              ask: CoreAsk(session: "d", summary: "?"))
        #expect(store.askAction(for: away) == .remote)
        #expect(store.askDisabledReason(for: away) != nil)
        #expect(!store.canReply(away))

        let none = Self.entry("e")
        #expect(store.askAction(for: none) == .noAsk)
    }

    // MARK: Remote-row gating

    @Test func remoteRowsCannotBeOpened() {
        let store = Self.store(with: [
            Self.entry("local"), Self.entry("away", remote: true),
        ])
        store.filter = OverviewFilter(preset: .all)
        #expect(store.canOpen(store.rows.first { $0.id == "local" }!))
        #expect(!store.canOpen(store.rows.first { $0.id == "away" }!))
        store.selectionChanged(to: ["away"])
        #expect(!store.canOpenSelected)
        store.selectionChanged(to: ["local"])
        #expect(store.canOpenSelected)
    }

    // MARK: Saved-filter apply clears search

    @Test func applyingSavedFilterClearsStaleSearch() {
        let store = Self.store(with: [Self.entry("a", label: "alpha")])
        store.search = "alpha"
        let saved = SavedOverviewFilter(name: "mine", filter: OverviewFilter(preset: .all))
        store.apply(saved)
        #expect(store.search.isEmpty)
        #expect(store.activeSavedFilter == "mine")
        #expect(store.rows.map(\.id) == ["a"])
    }

    // MARK: Search coverage

    @Test func searchCoversAskAxesKindAndParent() {
        let asked = Self.entry("s1", ask: CoreAsk(session: "s1", summary: "allow port 8080"))
        #expect(OverviewStore.matchesSearch(asked, "8080"))

        let failed = Self.entry("s2", outcome: "failed", review: "unreviewed")
        #expect(OverviewStore.matchesSearch(failed, "failed"))
        #expect(OverviewStore.matchesSearch(failed, "unreviewed"))

        let worker = Self.entry("s3", kind: "worker", parent: "main-session-9")
        #expect(OverviewStore.matchesSearch(worker, "worker"))
        #expect(OverviewStore.matchesSearch(worker, "main-session-9"))
    }

    // MARK: Memoization

    @Test func derivedRowsAndCountsComputeOncePerInputSet() {
        let store = Self.store(with: [Self.entry("a"), Self.entry("b")])
        store.filter = OverviewFilter(preset: .all)
        let before = store.derivedComputations
        _ = store.rows
        _ = store.rows
        _ = store.stripCounts
        #expect(store.derivedComputations == before + 1)
        // An input change invalidates once, not per accessor.
        store.search = "a"
        _ = store.rows
        _ = store.stripCounts
        #expect(store.derivedComputations == before + 2)
        // The 1 s clock tick must NOT invalidate: `now` is not an input.
        store.now = Date()
        _ = store.rows
        #expect(store.derivedComputations == before + 2)
    }

    @Test func workerFilterNarrowsRowsToChildren() {
        let store = Self.store(with: [
            Self.entry("parent"),
            Self.entry("w1", kind: "worker", parent: "parent"),
            Self.entry("w2", kind: "worker", parent: "parent"),
        ])
        store.filter = OverviewFilter(preset: .all)
        store.workerFilter = "parent"
        #expect(store.rows.map(\.id).sorted() == ["w1", "w2"])
    }

    // MARK: Waiting age

    @Test func waitingTextFormatsAskAge() {
        let now = Date()
        let asked = Self.entry("a", ask: CoreAsk(
            session: "a", openedAt: now.timeIntervalSince1970 - 23 * 60, summary: "?"))
        #expect(OverviewStore.waitingText(asked, now: now) == "waiting 23m")
        #expect(OverviewStore.waitingText(Self.entry("b"), now: now) == nil)
    }

    @Test func snoozedChipReadsSnoozedUntil() {
        let now = Date()
        let muted = Self.entry("a", snoozedUntil: now.timeIntervalSince1970 + 3600)
        #expect(OverviewStore.isSnoozed(muted, now: now))
        #expect(OverviewStore.snoozeWakeText(muted)?.hasPrefix("Snoozed until") == true)
        let expired = Self.entry("b", snoozedUntil: now.timeIntervalSince1970 - 60)
        #expect(!OverviewStore.isSnoozed(expired, now: now))
    }

    // MARK: Timeline merge keeps gaps

    @Test func mergingPagesKeepsBothGapsLists() {
        let page = CoreTimelinePage(
            events: [CoreTimelineItem(seq: 10, kind: "message")],
            hasMore: true, nextBefore: 10, total: 30, gaps: ["timeline_item_cap:100"])
        let older = CoreTimelinePage(
            events: [CoreTimelineItem(seq: 5, kind: "tool_use")],
            hasMore: true, nextBefore: 5, total: 30,
            gaps: ["transcript_unreadable", "timeline_item_cap:100"])
        let merged = OverviewStore.mergeTimelinePage(
            older: older, into: page, events: older.events + page.events)
        #expect(merged.gaps == ["timeline_item_cap:100", "transcript_unreadable"])
        #expect(merged.nextBefore == 5)
        #expect(merged.hasMore)
        // refreshTimeline derives the older prefix as timeline.count -
        // merged.events.count — the merged page must carry only the
        // NEWEST page's slice or a refresh silently drops loaded history.
        #expect(merged.events.map(\.seq) == page.events.map(\.seq))
    }

    @Test func refreshOlderPrefixMathKeepsLoadedHistory() {
        // The exact invariant refreshTimeline depends on: after a merge,
        // timeline.count - page.events.count == the older prefix length.
        let store = Self.store(with: [])
        store.timelineSessionID = "s"
        store.timeline = [
            CoreTimelineItem(seq: 3, kind: "message"),
            CoreTimelineItem(seq: 4, kind: "message"),
            CoreTimelineItem(seq: 8, kind: "message"),
            CoreTimelineItem(seq: 9, kind: "message"),
        ]
        let newest = CoreTimelinePage(
            events: [CoreTimelineItem(seq: 8, kind: "message"),
                     CoreTimelineItem(seq: 9, kind: "message")],
            hasMore: true, nextBefore: 8, total: 9, gaps: [])
        let older = CoreTimelinePage(
            events: [CoreTimelineItem(seq: 3, kind: "message"),
                     CoreTimelineItem(seq: 4, kind: "message")],
            hasMore: false, nextBefore: nil, total: 9, gaps: [])
        store.timelinePage = OverviewStore.mergeTimelinePage(
            older: older, into: newest, events: store.timeline)
        let olderCount = max(0, store.timeline.count - (store.timelinePage?.events.count ?? 0))
        #expect(olderCount == 2)
        #expect(store.timeline.prefix(olderCount).map(\.seq) == [3, 4])
    }

    // MARK: Kind chips

    @Test func kindFilterCountsAndSlices() {
        let store = Self.store(with: [])
        store.timeline = [
            CoreTimelineItem(seq: 1, kind: "message", role: "user"),
            CoreTimelineItem(seq: 2, kind: "tool_use", name: "Bash"),
            CoreTimelineItem(seq: 3, kind: "tool_result", isError: true),
            CoreTimelineItem(seq: 4, kind: "message", role: "assistant"),
        ]
        let counts = store.timelineKindCounts
        #expect(counts.messages == 2 && counts.tools == 2 && counts.errors == 1)
        store.timelineKind = .errors
        #expect(store.filteredTimeline.map(\.seq) == [3])
        store.timelineKind = .messages
        #expect(store.filteredTimeline.map(\.seq) == [1, 4])
        #expect(store.firstErrorSeq == 3)
        store.timelineKind = .all
        #expect(store.filteredTimeline.count == 4)
    }

    // MARK: Accessibility strings

    @Test func attentionLabelSpeaksWaitingAgeAndFailure() {
        let now = Date()
        let asked = Self.entry("a", ask: CoreAsk(
            session: "a", openedAt: now.timeIntervalSince1970 - 600, summary: "?"))
        #expect(OverviewView.attentionLabel(asked, now: now) == "Waiting on you, waiting 10m")
        let failed = Self.entry("b", outcome: "failed", review: "unreviewed")
        #expect(OverviewView.attentionLabel(failed, now: now) == "Failed")
        let plain = Self.entry("c")
        #expect(OverviewView.attentionLabel(plain, now: now) == "No attention needed")
    }

    @Test func chipLabelIncludesToneAndSubtitle() {
        let link = OverviewLink(
            id: "core", group: .core, symbol: "bolt",
            title: "Core 0.9.8", subtitle: "connected",
            tone: .good, facts: [])
        #expect(OverviewView.chipLabel(link) == "Core: Core 0.9.8, connected, good")
    }

    // MARK: Archive search term

    @Test func archiveSearchTermUsesSessionUuidTail() {
        let entry = Self.entry("claude:session:9f3a-uuid")
        #expect(OverviewStore.archiveSearchTerm(for: entry) == "9f3a-uuid")
    }
}

/// The export preview/write path: the previewed bytes are the saved ones.
@MainActor
@Suite struct OverviewExportTests {
    @Test func saveExportWritesThePreviewedDocument() throws {
        let store = OverviewStore(core: CoreModel())
        store.exportPreview = (
            .object(["t": .string("audit_export"), "counts": .object(["total": .number(3)])]),
            "# audit\n"
        )
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let jsonURL = dir.appending(path: "audit.json")
        try store.saveExport(to: jsonURL, markdown: false)
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: jsonURL)) as? [String: Any]
        #expect(saved?["t"] as? String == "audit_export")

        let mdURL = dir.appending(path: "audit.md")
        try store.saveExport(to: mdURL, markdown: true)
        let savedMD = try String(decoding: Data(contentsOf: mdURL), as: UTF8.self)
        #expect(savedMD == "# audit\n")
    }
}
