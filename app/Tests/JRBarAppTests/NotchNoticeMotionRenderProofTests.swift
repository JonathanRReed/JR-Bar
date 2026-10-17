import AppKit
import Foundation
import SwiftUI
import Testing
import JRBarCore
@testable import JRBarApp

/// Frame-by-frame render proof of a notice dropping out of the resting
/// island and going back: the real `NotchIslandView` on a stage, the
/// frame spring read at fixed times. What to look for is the words: laid
/// out once at their own width and uncovered by the shape, never
/// re-wrapping or truncating differently as it grows. Off by default; set
/// `JRBAR_RENDER_PROOF=1` to write `notch-notice-motion-*.png`.
@Suite("Notch notice motion render proof")
@MainActor
struct NotchNoticeMotionRenderProofTests {
    nonisolated static let enabled = ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1"
    private static let times: [Double] = [0, 0.02, 0.04, 0.06, 0.08, 0.10, 0.13, 0.16, 0.20, 0.26, 0.34, 0.5]

    private func frames(notice: AlcoveNotice, opening: Bool, ask: Bool) throws -> [ProofCell] {
        let (toy, store, _) = NotchSurfaceRenderProofTests.makeToy()
        defer { withExtendedLifetime(store) {} }
        let depth = max(toy.notchDepth, 32)
        let slot = NotchSurfaceRenderProofTests.slotWidth
        let size = ask
            ? NotchIslandLayout.askSize(slotWidth: slot, notchDepth: depth,
                                        summaryLines: toy.askSummaryLines, takeover: false, underHousing: nil)
            : NotchIslandLayout.noticeSize(slotWidth: slot, notchDepth: depth)
        let idle = CGRect(x: 0, y: 0, width: slot, height: depth)
        let target = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        toy.activeCapsule = notice
        toy.desiredFrame = target
        toy.stage.noticeMorph = NotchMorph(rest: depth, open: size.height, restWidth: slot, openWidth: size.width)
        let stageSize = CGSize(width: size.width + 24, height: size.height + 14)
        let canvas = CGSize(width: stageSize.width + 40, height: stageSize.height + 16)
        var spring = NotchFrameSpring(at: opening ? idle : target)
        spring.retarget(opening ? target : idle,
                        motion: NotchMotion.frameMotion(from: spring.frame, to: opening ? target : idle))
        var elapsed = 0.0
        var cells: [ProofCell] = []
        // The notice's content clock, aimed the way the shape goes.
        toy.stage.showNotice(level: opening ? 0 : 1, shown: opening)
        for t in Self.times {
            spring.integrate(dt: t - elapsed)
            toy.stage.tickNotice(dt: t - elapsed, shown: opening)
            elapsed = t
            let shape = spring.frame
            toy.stage.shape = CGRect(x: (stageSize.width - shape.width) / 2, y: 0,
                                     width: shape.width, height: shape.height)
            let scene = ZStack(alignment: .top) {
                ProofDesktop(dark: true)
                Rectangle().fill(Color.black.opacity(0.22)).frame(height: depth)
                UnevenRoundedRectangle(bottomLeadingRadius: 8, bottomTrailingRadius: 8, style: .continuous)
                    .fill(.black).frame(width: slot, height: depth)
                NotchIslandView(toy: toy).frame(width: stageSize.width, height: stageSize.height)
            }
            .frame(width: canvas.width, height: canvas.height, alignment: .top)
            cells.append(ProofCell(
                label: String(format: "t %3d ms   %3.0f x %3.0f", Int((t * 1000).rounded()), shape.width, shape.height),
                bitmap: try ProofRender.render(scene, size: canvas, scale: 1.5, settle: 0.1)))
        }
        toy.stage.shape = nil
        return cells
    }

    @Test(.enabled(if: enabled, "set JRBAR_RENDER_PROOF=1 to write PNGs"))
    func lineNotice() throws {
        let notice = AlcoveNotice(id: "c", kind: .completed, title: "Claude",
                                  subtitle: "rename-the-fish finished", provider: "claude", key: "c")
        try ProofContactSheet.write(try frames(notice: notice, opening: true, ask: false), columns: 4,
                                    title: "NOTICE IN", name: "notch-notice-motion-in")
        try ProofContactSheet.write(try frames(notice: notice, opening: false, ask: false), columns: 4,
                                    title: "NOTICE OUT", name: "notch-notice-motion-out")
    }

    @Test(.enabled(if: enabled, "set JRBAR_RENDER_PROOF=1 to write PNGs"))
    func askNotice() throws {
        let ask = CoreAsk(session: "claude:ask", openedAt: Date().timeIntervalSince1970 - 190,
                          summary: "Run the migration against the staging database?",
                          answerable: true, request: "r1", preview: "make migrate ENV=staging")
        let notice = AlcoveNotice(id: "a", kind: .ask, title: "Claude · rename-the-fish",
                                  subtitle: "needs you", provider: "claude", session: "claude:ask",
                                  key: "ask:claude:ask|r1", ask: ask)
        try ProofContactSheet.write(try frames(notice: notice, opening: true, ask: true), columns: 4,
                                    title: "ASK IN", name: "notch-notice-motion-ask-in")
    }
}
