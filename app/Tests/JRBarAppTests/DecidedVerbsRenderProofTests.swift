import AppKit
import Foundation
import SwiftUI
import Testing
import JRBarCore
@testable import JRBarApp

/// A picture of the notch's ask face, the Dock's ask rows and the Rail's
/// ask pill with an answered ask beside an open one: the open one keeps
/// its verbs, the answered one draws none and says the agent is being
/// waited for. Off by default; set `JRBAR_RENDER_PROOF=1` to write
/// `decided-*.png` into `JRBAR_RENDER_PROOF_DIR` (default
/// `/tmp/jrbar-audit`).
@Suite("Decided asks render proof", .serialized)
@MainActor
struct DecidedVerbsRenderProofTests {
    private typealias Fixture = DecidedAskFixture
    nonisolated static let enabled = ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1"

    /// The ask as it would read a moment after it opened: a wait of a
    /// minute or so, and a hold the way the daemon keeps it (45 s). The
    /// fixtures' fixed stamps would read as days.
    private static func justOpened(_ ask: CoreAsk) -> CoreAsk {
        var fresh = ask
        let now = Date().timeIntervalSince1970
        fresh.openedAt = now - 75
        fresh.decision?.holdUntil = now + 30
        return fresh
    }

    /// The ask capsule on the island over a desktop, hung from the notch.
    private func notchFace(_ ask: CoreAsk, name: String, takeover: Bool) throws {
        let shown = Self.justOpened(ask)
        let (toy, store, _, _) = Fixture.makeToy(state: Fixture.state(holding: shown))
        defer { withExtendedLifetime(store) {} }
        toy.capsuleTimer = { _, _ in }
        var notice = Fixture.capsule(shown)
        notice.takeover = takeover
        toy.activeCapsule = notice
        let depth = max(toy.notchDepth, 32)
        let slot = NotchSurfaceRenderProofTests.slotWidth
        let size = NotchIslandLayout.askSize(slotWidth: slot, notchDepth: depth,
                                             summaryLines: toy.askSummaryLines, takeover: takeover,
                                             underHousing: nil)
        let canvas = CGSize(width: 520, height: size.height + 30)
        let scene = NotchSurfaceRenderProofTests.scene(NotchIslandView(toy: toy), size: size, depth: depth,
                                                       canvas: canvas)
        try ProofRender.write(scene, size: canvas, name: name)
    }

    @Test(.enabled(if: enabled, "set JRBAR_RENDER_PROOF=1 to write PNGs"))
    func notchAskFaces() throws {
        try notchFace(Fixture.openAsk(), name: "decided-notch-open", takeover: false)
        try notchFace(Fixture.decidedAsk(), name: "decided-notch-answered", takeover: false)
        try notchFace(Fixture.olderDaemonDecidedAsk(), name: "decided-notch-answered-older-daemon",
                      takeover: false)
        try notchFace(Fixture.decidedAsk(), name: "decided-notch-answered-takeover", takeover: true)
    }

    /// The Dock's panel with an answered agent above an open one.
    @Test(.enabled(if: enabled, "set JRBAR_RENDER_PROOF=1 to write PNGs"))
    func dockAskRows() throws {
        let previous = AskAnswerDesk.shared
        AskAnswerDesk.shared = AskAnswerDesk(send: { _, _, _ in throw CoreClientError.notConnected })
        defer { AskAnswerDesk.shared = previous }
        let answered = DockPreviewSamples.mark("claude:answered", provider: "claude", name: "Claude",
                                               label: "clear the build folder", activity: .waiting,
                                               ask: Self.justOpened(Fixture.decidedAsk()))
        let older = DockPreviewSamples.mark("claude:older", provider: "claude", name: "Claude",
                                            label: "same, from an older daemon", activity: .waiting,
                                            ask: Self.justOpened(Fixture.olderDaemonDecidedAsk()))
        let content = DockPreviewSamples.terminal()
        content.metrics = DockPreviewMetrics.scaled(DockEnhanceSettings.defaultSpacing)
        content.agents = [1: DockPreviewSamples.waiting, 2: DockPreviewSamples.working]
        content.appAgents = [answered, older, DockPreviewSamples.waiting, DockPreviewSamples.working]
        for dark in [true, false] {
            let panel = DockPreviewView(content: content, actions: DockPreviewActions(content: content))
                .fixedSize()
                .background(ProofGlass(cornerRadius: content.metrics.panelRadius))
            let canvas = CGSize(width: 900, height: 560)
            let scene = ZStack {
                ProofDesktop(dark: dark)
                panel
            }
            .frame(width: canvas.width, height: canvas.height)
            try ProofRender.write(scene, size: canvas, name: "decided-dock-\(dark ? "dark" : "light")",
                                  dark: dark)
        }
    }

    /// The Rail's pill beside a hovered key: an open ask keeps its verbs,
    /// an answered one says it is waiting for the agent.
    @Test(.enabled(if: enabled, "set JRBAR_RENDER_PROOF=1 to write PNGs"))
    func railPills() throws {
        let desk = Fixture.desk(logging: Fixture.SentLog())
        func pill(_ ask: CoreAsk, key: String) -> some View {
            RailLabelView(title: "release cleanup", subtitle: "Needs you", provider: "claude", number: key,
                          detail: ask.summary, ask: ask, desk: desk)
                .background(ProofGlass(cornerRadius: 9))
        }
        for dark in [true, false] {
            let canvas = CGSize(width: 420, height: 340)
            let scene = ZStack {
                ProofDesktop(dark: dark)
                VStack(alignment: .leading, spacing: 18) {
                    pill(Self.justOpened(Fixture.openAsk()), key: "1")
                    pill(Self.justOpened(Fixture.decidedAsk()), key: "2")
                    pill(Self.justOpened(Fixture.olderDaemonDecidedAsk()), key: "3")
                }
            }
            .frame(width: canvas.width, height: canvas.height)
            try ProofRender.write(scene, size: canvas, name: "decided-rail-\(dark ? "dark" : "light")",
                                  dark: dark)
        }
    }
}
