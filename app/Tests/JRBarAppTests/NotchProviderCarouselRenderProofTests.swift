import AppKit
import Foundation
@testable import JRBarCore
import SwiftUI
import Testing
@testable import JRBarApp

@Suite("Notch provider carousel render proof", .serialized)
@MainActor
struct NotchProviderCarouselRenderProofTests {
    nonisolated static let enabled = ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1"

    @Test(.enabled(if: enabled, "set JRBAR_RENDER_PROOF=1 to write provider cycle PNGs"))
    func twoProvidersAndFiveT3Providers() throws {
        let origin = try JSONDecoder().decode(CoreOrigin.self, from:
            Data(#"{"kind":"app","label":"T3 Code","bundle_id":"com.t3tools.t3code"}"#.utf8))
        for providers in [["claude", "codex"], ["claude", "codex", "gemini", "grok", "opencode"]] {
            let core = CoreModel(socketPath: NSTemporaryDirectory() + "jrbar-carousel-render-fixture.sock")
            core.handle(.connected)
            var clock = 0.0
            let store = PanelStore(core: core, screenBarShown: false)
            store.providerClock = { clock }
            let roster = providers.map { provider in
                CoreSession(id: "\(provider):fixture", provider: provider, label: "Fixture work", mode: "working", origin: origin)
            }
            var frames: [Frame] = []
            let count = providers.count == 2 ? 3 : 5
            for turn in 0..<count {
                clock = Double(turn * 3)
                core.apply(.state(CoreState(generation: turn, sessions: Array(roster.reversed()))))
                let slot = try #require(store.screenBarWings.left)
                let model = ScreenBarWingsModel()
                model.viewHeight = 50
                model.left = (slot: slot, rect: CGRect(x: 12, y: 12, width: 56, height: 26))
                frames.append(Frame(id: turn, model: model, provider: slot.provider ?? "", seconds: turn * 3))
            }
            let scene = HStack(spacing: 12) {
                ForEach(frames) { frame in
                    VStack(spacing: 8) {
                        ScreenBarWingsView(model: frame.model)
                            .frame(width: 80, height: 50)
                            .background(.black, in: RoundedRectangle(cornerRadius: 12))
                        Text(ProviderStyle.style(for: frame.provider).name)
                            .font(.system(size: 11, weight: .medium))
                        Text("\(frame.seconds) s")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    .frame(width: 108)
                }
            }
            .padding(16)
            .background(Color(nsColor: .windowBackgroundColor))
            let width = CGFloat(frames.count * 120 + 20)
            try ProofRender.write(scene, size: CGSize(width: width, height: 138),
                                  name: providers.count == 2 ? "notch-provider-cycle-two" : "notch-provider-cycle-five-t3")
        }
    }

    private struct Frame: Identifiable {
        let id: Int
        let model: ScreenBarWingsModel
        let provider: String
        let seconds: Int
    }
}
