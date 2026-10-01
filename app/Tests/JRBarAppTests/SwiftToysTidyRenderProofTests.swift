import AppKit
import Foundation
import SwiftUI
import Testing
import JRBarCore
@testable import JRBarApp

/// Pictures of what the toys-tidy lane changed on screen. Off by default;
/// set `JRBAR_RENDER_PROOF=1` to write `toys-tidy-*.png` into
/// `JRBAR_RENDER_PROOF_DIR` (default `/tmp/jrbar-audit`).
@Suite("Toys tidy render proof", .serialized)
@MainActor
struct SwiftToysTidyRenderProofTests {
    private typealias Fixture = DecidedAskFixture
    nonisolated static let enabled = ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1"

    /// The state chip under the inspector's title: an open ask keeps the
    /// loud "Waiting on you"; an answered one is calm and says Answered.
    @Test(.enabled(if: enabled, "set JRBAR_RENDER_PROOF=1 to write PNGs"))
    func statePills() throws {
        for dark in [true, false] {
            let canvas = CGSize(width: 360, height: 150)
            let scene = ZStack {
                ProofDesktop(dark: dark)
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 8) {
                        OverviewStatePill(activity: .waiting)
                        Text("Claude · release-cleanup").font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 8) {
                        OverviewStatePill(activity: .waiting, answered: true)
                        Text("Claude · release-cleanup").font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 8) {
                        OverviewStatePill(activity: .working, answered: true)
                        Text("Claude · release-cleanup").font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: canvas.width, height: canvas.height)
            try ProofRender.write(scene, size: canvas, name: "toys-tidy-state-pill-\(dark ? "dark" : "light")",
                                  dark: dark)
        }
    }

    /// Creator Micro keys side by side: one asking, one whose ask JR-Bar
    /// already answered. Same state, same light; the second line differs.
    @Test(.enabled(if: enabled, "set JRBAR_RENDER_PROOF=1 to write PNGs"))
    func keyTiles() throws {
        let core = CoreModel()
        let openAsk = Fixture.openAsk()
        core.apply(.state(CoreState(
            sessions: [
                CoreSession(id: "claude:session:tests", provider: "claude", label: "run the tests",
                            mode: "waiting", ask: CoreAsk(summary: openAsk.summary)),
                CoreSession(id: Fixture.session, provider: "claude", label: "release cleanup",
                            mode: "waiting", ask: CoreAsk(summary: "Run the cleanup")),
            ],
            asks: [
                CoreAsk(session: "claude:session:tests", kind: "permission", openedAt: openAsk.openedAt,
                        summary: openAsk.summary, answerable: true, request: "r-open",
                        decision: openAsk.decision, preview: openAsk.preview),
                Fixture.decidedAsk(),
            ])))
        let store = DeckStore(core: core)
        let tests = DeckSlot(index: 0, identity: "key-0", session: "claude:session:tests",
                             label: "run the tests", provider: "claude", state: .inputRequired,
                             color: DeckLighting.askHex)
        let cleanup = DeckSlot(index: 1, identity: "key-1", session: Fixture.session,
                               label: "release cleanup", provider: "claude", state: .inputRequired,
                               color: DeckLighting.askHex)
        #expect(store.ask(for: tests) != nil && store.ask(for: cleanup)?.isDecided == true)
        for dark in [true, false] {
            let canvas = CGSize(width: 330, height: 170)
            let scene = ZStack {
                ProofDesktop(dark: dark)
                HStack(spacing: 14) {
                    KeyCap(store: store, slot: tests)
                    KeyCap(store: store, slot: cleanup)
                }
            }
            .frame(width: canvas.width, height: canvas.height)
            try ProofRender.write(scene, size: canvas, name: "toys-tidy-key-tiles-\(dark ? "dark" : "light")",
                                  dark: dark)
        }
    }
}
