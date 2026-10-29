import JRBarTestSupport
import AppKit
import Foundation
import JRBarCore
import SwiftUI
import Testing
@testable import JRBarApp

@Suite("Toy motion render proof", .renderProofAppearance)
@MainActor
struct ToyMotionRenderProofTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1",
                   "set JRBAR_RENDER_PROOF=1 to write four PNGs"))
    func previewsAndStillBuddy() throws {
        let tint = ProviderStyle.style(for: "claude").accent
        for reduced in [false, true] {
            let preview = ConfettiPreviewTile(settings: ConfettiSettings(),
                                              shot: ConfettiShot(provider: "claude", tint: tint),
                                              reduceMotionOverride: reduced)
                .frame(width: 330, height: 132)
            try ProofRender.write(preview, size: CGSize(width: 330, height: 132),
                                  name: "toy-motion-confetti-\(reduced ? "reduced" : "normal")", dark: true)

            let buddy = BuddyFigure(character: .dot, mood: .pacing, tint: tint, phase: 2.35,
                                    hopProgress: nil, waveAge: nil, slumpAge: nil,
                                    leans: false, still: reduced, askCount: 0, care: .content,
                                    trick: nil, treatAge: nil, crumbAge: nil)
                .frame(width: 18, height: 18)
                .scaleEffect(3)
                .frame(width: 54, height: 54)
                .frame(width: 100, height: 90)
                .background(Color(white: 0.13))
            try ProofRender.write(buddy, size: CGSize(width: 100, height: 90),
                                  name: "toy-motion-buddy-\(reduced ? "still" : "moving")", dark: true)
        }
    }
}
