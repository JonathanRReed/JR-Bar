import JRBarTestSupport
import AppKit
@testable import JRBarCore
import JRBarUI
import SwiftUI
import Testing
@testable import JRBarApp

@Suite("Usage density proofs", .serialized, .renderProofAppearance)
@MainActor
struct UsageDensityRenderProofTests {
    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func notchCountdownAndForecastKeepTheSameCard() throws {
        let now = Date()
        let stamp = now.timeIntervalSince1970
        let providers = ["claude", "codex"].map {
            CoreProviderUsage(id: $0, windows: [CoreUsageWindow(name: "5h", usedPct: 70, resetsAt: stamp + 4 * 3600)],
                forecast: CoreUsageForecast(exhaustsAt: stamp + 2 * 3600, pace: "ahead", ratePctPerHour: 15))
        }
        let core = CoreModel(socketPath: NSTemporaryDirectory() + "jrbar-notch-caption-proof.sock")
        core.handle(.connected)
        core.apply(.state(CoreState(sessions: providers.map {
            CoreSession(id: $0.id + ":fixture", provider: $0.id, label: "Sample task", mode: "working")
        }, usage: CoreUsage(providers: providers))))
        let baseline = UsageForecastSurfaceTests.notchModel()
        let forecast = UsageForecastSurfaceTests.notchModel()
        for model in [baseline, forecast] {
            model.focus = ScreenBarFocus(style: ProviderStyle.style(for: "claude"), label: "Sample task", word: "Working", clickSession: nil)
            model.rows = NotchIsland.summarize(core.sessions).rows
            model.pinned = true
        }
        defer { baseline.pinned = false; forecast.pinned = false }
        baseline.meters = NotchIsland.meters(core.state?.usage)
        forecast.meters = UsageCenterStore.notchMeters(core: core, now: now)
        let before = NotchCardView(model: baseline, style: .island, width: 320, stillTurn: 1, stillReduced: true)
        let after = NotchCardView(model: forecast, style: .island, width: 320, stillTurn: 1, stillReduced: true)
        let beforeSize = NSHostingView(rootView: before).fittingSize
        let afterSize = NSHostingView(rootView: after).fittingSize
        #expect(beforeSize == afterSize)
        #expect(afterSize.width == 320)
        for dark in [false, true] {
            let look = dark ? "dark" : "light"
            let comparison = HStack(alignment: .top, spacing: 24) {
                notchFace(before, height: beforeSize.height)
                notchFace(after, height: afterSize.height)
            }.padding(20).background(Color(white: dark ? 0.18 : 0.87))
            try ProofRender.write(comparison, size: CGSize(width: 704, height: beforeSize.height + 76),
                name: "notch-countdown-forecast-parity-\(look)", dark: dark, settle: 0)
        }
    }

    private func notchFace<V: View>(_ card: V, height: CGFloat) -> some View {
        ZStack(alignment: .top) {
            NotchSilhouette(notchDepth: 32, restingRadius: 8, notchWidth: 185).fill(.black)
            card.padding(.top, 36)
        }.frame(width: 320, height: 36 + height)
    }

    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func panelStates() throws {
        let (panel, _, runningOut) = UsageForecastSurfaceTests.fixture("runs out")
        let (_, _, usedUp) = UsageForecastSurfaceTests.fixture("used up", providerID: "codex")
        let (_, _, comfortable) = UsageForecastSurfaceTests.fixture("comfortable", providerID: "gemini")
        let stamp = UsageForecastSurfaceTests.stamp
        let weekly = CoreProviderUsage(id: "devin", windows: [CoreUsageWindow(name: "7d", usedPct: 23, resetsAt: stamp + 86400)])
        let empty = CoreProviderUsage(id: "grok", windows: [])
        let providers = [runningOut, usedUp, comfortable, weekly, empty]
        let sessions = ["claude", "codex", "gemini"].map {
            CoreSession(id: $0 + ":fixture", provider: $0, label: "Sample task", mode: "working")
        }
        let extra = ["cursor", "factory", "kiro"].map { CoreProviderUsage(id: $0, windows: []) }
        panel.core.apply(.state(CoreState(sessions: sessions, usage: CoreUsage(refreshedAt: stamp, providers: providers + extra))))
        let section = PanelProviderSection(store: panel, composition: PanelComposition(store: panel))
        for dark in [false, true] {
            let background = Color(white: dark ? 0.13 : 0.93)
            let allStates = VStack(spacing: 0) {
                Text("Usage").font(JRBarTokens.TypeStyle.section.font)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, JRBarTokens.Space.md).frame(height: PanelComposition.sectionHeight)
                UsageGaugeHeader(windowNames: ["5h", "7d"]).frame(height: 20)
                ForEach(providers, id: \.identity) { provider in
                    section.gauge(provider).frame(height: PanelComposition.usageHeight(provider))
                }
            }.background(background)
            let look = dark ? "dark" : "light"
            try ProofRender.write(allStates, size: CGSize(width: 372, height: 1),
                name: "density-five-states-\(look)", dark: dark, settle: 0)
            try ProofRender.write(section.background(background), size: CGSize(width: 372, height: 1),
                name: "density-panel-section-\(look)", dark: dark, settle: 0)
            if let directory = ProcessInfo.processInfo.environment["JRBAR_DENSITY_BEFORE_DIR"] {
                try compare(allStates, baseline: "density-five-states-\(look)", directory: directory, dark: dark)
                try compare(section.background(background), baseline: "density-panel-section-\(look)", directory: directory, dark: dark)
            }
        }
    }

    private func compare<V: View>(_ after: V, baseline: String, directory: String, dark: Bool) throws {
        let url = URL(fileURLWithPath: directory).appendingPathComponent(baseline + ".png")
        let image = try #require(NSImage(contentsOf: url))
        let height = image.size.height
        let comparison = HStack(alignment: .top, spacing: 24) {
            Image(nsImage: image).resizable().frame(width: 372, height: height)
            after.frame(width: 372)
        }.padding(20).background(Color(white: dark ? 0.13 : 0.93))
        try ProofRender.write(comparison, size: CGSize(width: 808, height: height + 40),
            name: baseline + "-before-after", dark: dark, settle: 0)
    }
}
