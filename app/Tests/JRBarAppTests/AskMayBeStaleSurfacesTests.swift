import JRBarTestSupport
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import JRBarApp
@testable import JRBarCore

/// A long-unanswered ask stays an ask on every surface. Past the daemon's
/// "may be stale" mark each says so with the ask's age in words, and the
/// panel and the Overview offer one Dismiss that sends the agent nothing.
/// Set `JRBAR_RENDER_PROOF=1` to write the pictures into
/// `JRBAR_RENDER_PROOF_DIR` (default /tmp/windows-proof).
@Suite("A stale ask on the surfaces", .serialized, .renderProofAppearance)
@MainActor
struct AskMayBeStaleSurfacesTests {
    private static let t = WindowsRenderProofTests.t
    private static let nineHours = 9.0 * 3600

    private static func ask(session: String, summary: String, ageSeconds: Double, stale: Bool,
                            dismissible: Bool? = nil, preview: String? = nil) -> CoreAsk {
        CoreAsk(session: session, kind: "permission", openedAt: t - ageSeconds, summary: summary,
                answerable: true, request: "r-\(session)", preview: preview,
                lastActivityAt: t - ageSeconds, isStale: stale, isDismissible: dismissible ?? stale)
    }

    private static func session(_ id: String, label: String, ask: CoreAsk) -> CoreSession {
        CoreSession(id: id, provider: "claude", label: label, cwd: "/Users/me/src/site", mode: "waiting_for_input",
                    nextActor: "user", since: ask.openedAt, ask: ask)
    }

    private static func store(asks: [CoreAsk], sessions: [CoreSession]) -> PanelStore {
        let state = CoreState(now: t, aggregate: CoreAggregate(mode: "needs_you", needsYou: asks.count, active: 0),
                              sessions: sessions, asks: asks, devices: [WindowsRenderProofTests.devices[2]],
                              usage: WindowsRenderProofTests.usage(heavy: false))
        return WindowsRenderProofTests.panelStore(state)
    }

    // MARK: the words

    @Test func theRowsTooltipSaysItAndWhatEndsIt() {
        let stale = Self.ask(session: "claude:session:old", summary: "Run the migration", ageSeconds: Self.nineHours, stale: true)
        let store = Self.store(asks: [stale], sessions: [Self.session("claude:session:old", label: "billing", ask: stale)])
        let row = store.rows.first { $0.id == "claude:session:old" }
        let help = row?.help(now: Date(timeIntervalSince1970: Self.t)) ?? ""
        #expect(help.contains("may be stale · asked 9 hours ago"))
        #expect(help.contains("answered, the session ends, or you dismiss it"))
    }

    @Test func aCurrentAsksTooltipAddsNoCaveat() {
        let fresh = Self.ask(session: "claude:session:new", summary: "Run the tests", ageSeconds: 120, stale: false)
        let store = Self.store(asks: [fresh], sessions: [Self.session("claude:session:new", label: "site", ask: fresh)])
        let row = store.rows.first { $0.id == "claude:session:new" }
        let help = row?.help(now: Date(timeIntervalSince1970: Self.t)) ?? ""
        #expect(help.contains("/Users/me/src/site"), "the row still has its tooltip")
        #expect(!help.contains("may be stale"))
    }

    @Test func theOverviewSaysItInTheWordsOfTheOtherSurfaces() {
        let stale = Self.ask(session: "claude:session:old", summary: "x", ageSeconds: 3 * 86_400, stale: true)
        let entry = CoreRosterEntry(session: Self.session("claude:session:old", label: "billing", ask: stale), pinned: true)
        let now = Date(timeIntervalSince1970: Self.t)
        #expect(OverviewStore.waitingText(entry, now: now) == "may be stale · asked 3 days ago")
        let fresh = Self.ask(session: "claude:session:new", summary: "x", ageSeconds: 23 * 60, stale: false)
        let current = CoreRosterEntry(session: Self.session("claude:session:new", label: "site", ask: fresh), pinned: true)
        #expect(OverviewStore.waitingText(current, now: now)?.hasPrefix("waiting ") == true)
    }

    @Test func theIslandsChipSaysItToo() {
        let opened = Self.t - Self.nineHours
        let now = Date(timeIntervalSince1970: Self.t)
        #expect(NotchIslandView.waitedText(since: opened, stale: true, now: now) == "may be stale · 9 hours")
        #expect(NotchIslandView.waitedText(since: opened, stale: false, now: now) == "9h 0m")
    }

    // MARK: the pictures

    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func thePanelWithAStaleAskAFreshOneAndAPeersStaleOne() throws {
        let stale = Self.ask(session: "claude:session:old", summary: "Run the migration against the staging database",
                             ageSeconds: Self.nineHours, stale: true, preview: "make migrate STAGE=staging")
        let fresh = Self.ask(session: "claude:session:new", summary: "Run the tests before the merge?",
                             ageSeconds: 140, stale: false, preview: "npm test")
        let peer = Self.ask(session: "remote:studio:claude:session:far", summary: "Delete the build folder",
                            ageSeconds: 3 * 86_400, stale: true, dismissible: false)
        let sessions = [
            Self.session("claude:session:old", label: "billing ledger", ask: stale),
            Self.session("claude:session:new", label: "docs refresh", ask: fresh),
            Self.session("remote:studio:claude:session:far", label: "studio build", ask: peer),
        ]
        let store = Self.store(asks: [stale, fresh, peer], sessions: sessions)
        try WindowsRenderProofTests.write("stale-ask-panel", size: WindowsRenderProofTests.panelSize(store),
                                          plate: .glass) { WindowsRenderProofTests.panel(store) }
    }

    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func theOverviewInspectorForAStaleAsk() throws {
        let stale = Self.ask(session: "claude:session:old", summary: "Run the migration against the staging database",
                             ageSeconds: 3 * 86_400, stale: true, preview: "make migrate STAGE=staging")
        let session = Self.session("claude:session:old", label: "billing ledger", ask: stale)
        let state = CoreState(now: Self.t, aggregate: CoreAggregate(mode: "needs_you", needsYou: 1, active: 0),
                              sessions: [session], asks: [stale], devices: [WindowsRenderProofTests.devices[2]],
                              usage: WindowsRenderProofTests.usage(heavy: false))
        let core = WindowsRenderProofTests.liveCore(state)
        let store = OverviewStore(core: core)
        store.now = WindowsRenderProofTests.now
        let entry = CoreRosterEntry(session: session, pinned: true)
        store.roster = [entry]
        try WindowsRenderProofTests.write("stale-ask-overview-inspector", size: CGSize(width: 340, height: 520)) {
            OverviewSessionInspector(store: store, entry: entry) { _ in }
        }
    }
}
