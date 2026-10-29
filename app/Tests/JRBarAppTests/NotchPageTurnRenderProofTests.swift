import JRBarTestSupport
import AppKit
import Foundation
import SwiftUI
import Testing
import JRBarCore
@testable import JRBarApp

/// The page turn as the card draws it, read at fixed times off the real
/// spring: before (the shelf is simply there on the first frame) and
/// after (it arrives from the right, in focus), the same under Reduce
/// Motion, and the edge nudge. Off by default; set `JRBAR_RENDER_PROOF=1`
/// to write `notch-pageturn-*.png` into `JRBAR_RENDER_PROOF_DIR`.
@Suite("Notch page turn render proof", .renderProofAppearance)
@MainActor
struct NotchPageTurnRenderProofTests {
    nonisolated static let enabled = ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1"

    static let times: [Double] = [0, 0.016, 0.033, 0.050, 0.066, 0.100, 0.150, 0.250]

    private func cells(label: (Double, CGFloat) -> String,
                       level: (Double) -> CGFloat?, offset: (Double) -> CGFloat = { _ in 0 },
                       times: [Double] = NotchPageTurnRenderProofTests.times,
                       reduced: Bool = false) throws -> [ProofCell] {
        let (toy, store, monitor) = NotchSurfaceRenderProofTests.makeToy()
        defer { withExtendedLifetime(store) {} }
        let model = toy.cardModel
        NotchSurfaceRenderProofTests.fill(model, monitor: monitor)
        defer { NotchSurfaceRenderProofTests.clearTray(model) }
        let depth = max(toy.notchDepth, 32)
        let slot = NotchSurfaceRenderProofTests.slotWidth
        let width = NotchIslandLayout.expandedWidth(slotWidth: slot)
        model.show(.shelf)   // arrives from the right
        let probe = NSHostingView(rootView: NotchCardView(model: model, style: .island, width: width))
        probe.layoutSubtreeIfNeeded()
        let height = toy.cardTopPad + ceil(probe.fittingSize.height)
        let canvas = CGSize(width: width + 60, height: height + 30)
        var result: [ProofCell] = []
        for t in times {
            let value = level(t)
            let card = NotchCardView(model: model, style: .island, width: width,
                                     stillTurn: value, stillReduced: reduced)
            let island = ZStack(alignment: .top) {
                NotchSilhouette(notchDepth: depth, restingRadius: 8).fill(.black)
                card.padding(.top, toy.cardTopPad).offset(x: offset(t))
            }
            let scene = NotchSurfaceRenderProofTests.scene(
                island, size: CGSize(width: width, height: height), depth: depth, canvas: canvas)
            let bitmap = try ProofRender.render(scene, size: canvas, scale: 1.25, settle: 0.1)
            result.append(ProofCell(label: label(t, value ?? 1), bitmap: bitmap))
        }
        return result
    }

    private func ms(_ t: Double) -> Int { Int((t * 1000).rounded()) }

    @Test(.enabled(if: enabled, "set JRBAR_RENDER_PROOF=1 to write PNGs"))
    func before() throws {
        // The rows swapped in one frame: the shelf is whole from the first.
        let sheet = try cells(label: { t, _ in "t \(self.ms(t)) ms   whole" }, level: { _ in 1 })
        try ProofContactSheet.write(sheet, columns: 4,
                                    title: "BEFORE  Now to Shelf: the rows swap in one frame",
                                    name: "notch-pageturn-before")
    }

    @Test(.enabled(if: enabled, "set JRBAR_RENDER_PROOF=1 to write PNGs"))
    func after() throws {
        let spring = NotchMotion.pageTurn
        let sheet = try cells(
            label: { t, level in String(format: "t %3d ms   level %.2f   dx %+.1f", self.ms(t), level,
                                        NotchPageTurn.offset(level: level, direction: .fromRight)) },
            level: { spring.step(at: $0) })
        try ProofContactSheet.write(sheet, columns: 4,
                                    title: "AFTER  Now to Shelf: arrives from the right, spring 0.24 / 0.92",
                                    name: "notch-pageturn-after")
    }

    @Test(.enabled(if: enabled, "set JRBAR_RENDER_PROOF=1 to write PNGs"))
    func afterReduced() throws {
        let spring = NotchMotion.pageTurn
        let sheet = try cells(
            label: { t, level in String(format: "t %3d ms   fade %.2f", self.ms(t), level) },
            level: { spring.step(at: $0) }, reduced: true)
        try ProofContactSheet.write(sheet, columns: 4,
                                    title: "AFTER, Reduce Motion: the same arrival as a fade, no slide, no blur",
                                    name: "notch-pageturn-reduced")
    }

    @Test(.enabled(if: enabled, "set JRBAR_RENDER_PROOF=1 to write PNGs"))
    func edgeNudge() throws {
        // A swipe left past the last page: out to the peak, back slowly.
        let times: [Double] = [0, 0.016, 0.033, 0.070, 0.100, 0.150, 0.220, 0.310]
        let pushes: [Double: CGFloat] = [0: 0, 0.016: -2, 0.033: -4, 0.070: -NotchPageTurn.edgePeak,
                                         0.100: -5, 0.150: -3, 0.220: -1, 0.310: 0]
        let sheet = try cells(
            label: { t, _ in String(format: "t %3d ms   push %+.0f pt", self.ms(t), pushes[t] ?? 0) },
            level: { _ in nil }, offset: { pushes[$0] ?? 0 }, times: times)
        try ProofContactSheet.write(sheet, columns: 4,
                                    title: "EDGE  swipe left on the Shelf: the card follows the fingers 6 pt and returns",
                                    name: "notch-pageturn-edge")
    }
}
