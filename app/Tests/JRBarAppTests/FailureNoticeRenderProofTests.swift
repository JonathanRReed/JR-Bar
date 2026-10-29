import JRBarTestSupport
import AppKit
import SwiftUI
import Testing
import JRBarCore
@testable import JRBarApp

@Suite("Failure notice render proof", .renderProofAppearance)
@MainActor
struct FailureNoticeRenderProofTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1"))
    func namedFailure() async throws {
        let now = Date().timeIntervalSince1970
        let session = CoreSession(id: "codex:session:root", provider: "codex", cwd: "/repo/synthetic",
                                  mode: "blocked_error", lifecycle: "failed", updatedAt: now, failureSignalUntil: now + 5)
        let event = CoreEvent(id: "failure-proof", kind: "failed", session: session.id, at: now, notify: true, provider: "codex")
        let notice = try #require(AlcoveEventPolicy.notice(for: event, session: session, kinds: .init(), now: now))
        let (toy, store, _) = NotchSurfaceRenderProofTests.makeToy(state: CoreState(sessions: [session]))
        defer { withExtendedLifetime(store) {} }
        toy.activeCapsule = notice
        let depth = max(toy.notchDepth, 32)
        let slot = NotchSurfaceRenderProofTests.slotWidth
        let fitted = NotchIslandLayout.noticeSize(slotWidth: slot, notchDepth: depth,
                                                  copyWidth: NotchToy.copyWidth(of: notice))
        toy.stage.noticeMorph = NotchMorph(rest: depth, open: fitted.height,
                                           restWidth: slot, openWidth: fitted.width)
        let canvas = CGSize(width: 520, height: 110)
        let view = NotchSurfaceRenderProofTests.scene(NotchIslandView(toy: toy), size: fitted,
                                                      depth: depth, canvas: canvas)
        for dark in [true, false] {
            try ProofRender.write(view, size: canvas, name: "failure-named-notice-\(dark ? "dark" : "light")",
                                  dark: dark, settle: 0)
        }
    }
}
