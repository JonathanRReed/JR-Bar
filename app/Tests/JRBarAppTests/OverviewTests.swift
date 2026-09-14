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
