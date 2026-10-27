import AppKit
@testable import JRBarCore
import JRBarUI
import SwiftUI
import Testing
@testable import JRBarApp

@Suite("Notch caption fit proofs", .serialized)
@MainActor
struct NotchMeterCaptionRenderProofTests {
    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func lightCard() throws { try openCard(dark: false) }

    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func darkCard() throws { try openCard(dark: true) }

    private func openCard(dark: Bool) throws {
        let now = Date()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let at = try #require(calendar.nextDate(after: now.addingTimeInterval(3600),
            matching: DateComponents(hour: 23, minute: 5), matchingPolicy: .nextTime))
        let longest = try #require(ProviderStyle.table.values.max {
            nameWidth($0.name) < nameWidth($1.name)
        })
        let ids = ["claude", "codex", longest.id]
        let providers = ids.map {
            CoreProviderUsage(id: $0, windows: [CoreUsageWindow(name: "5h", usedPct: 70,
                resetsAt: at.timeIntervalSince1970 + 4 * 3600)],
                forecast: CoreUsageForecast(exhaustsAt: at.timeIntervalSince1970, pace: "ahead", ratePctPerHour: 15))
        }
        let core = CoreModel(socketPath: NSTemporaryDirectory() + "jrbar-notch-fit-proof.sock")
        core.handle(.connected)
        core.apply(.state(CoreState(sessions: ids.map {
            CoreSession(id: $0 + ":fixture", provider: $0, label: "Sample task", mode: "working")
        }, usage: CoreUsage(providers: providers))))
        let model = UsageForecastSurfaceTests.notchModel()
        model.focus = ScreenBarFocus(style: ProviderStyle.style(for: "claude"),
            label: "Sample task", word: "Working", clickSession: nil)
        model.rows = NotchIsland.summarize(core.sessions).rows
        model.meters = UsageCenterStore.notchMeters(core: core, now: now)
        #expect(model.meters.count == 3)
        #expect(model.meters.allSatisfy { NotchMeterCaption(meter: $0, now: now).tone == .attention })
        model.pinned = true
        defer { model.pinned = false }
        let card = NotchCardView(model: model, style: .island, width: 320, stillTurn: 1, stillReduced: true)
        let height = ceil(NSHostingView(rootView: card).fittingSize.height)
        let face = ZStack(alignment: .top) {
            NotchSilhouette(notchDepth: 32, restingRadius: 8, notchWidth: 185).fill(.black)
            card.padding(.top, 36)
        }.frame(width: 320, height: height + 36)
        let scene = face.padding(20).background(Color(white: dark ? 0.18 : 0.87))
            .environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.renderSnapshot, true)
        let size = CGSize(width: 360, height: height + 76)
        if !dark { _ = try ProofRender.render(scene, size: size, dark: dark) }
        try ProofRender.write(scene, size: size,
            name: "notch-caption-fit-\(dark ? "dark" : "light")", dark: dark)
    }

    private func nameWidth(_ name: String) -> CGFloat {
        NSHostingView(rootView: Text(name).font(.system(size: 11.5, weight: .medium)).fixedSize()).fittingSize.width
    }
}
