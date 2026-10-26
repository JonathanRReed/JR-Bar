import AppKit
@testable import JRBarCore
import JRBarUI
import SwiftUI
import Testing
@testable import JRBarApp

@Suite("Panel, notch and Usage Center design fixes", .serialized)
@MainActor
struct DesignFixARenderProofTests {
    private let stamp = PanelCompositionTests.time
    init() throws { try U5Proof.pinDefaultAccent() }

    @Test(.enabled(if: U5RenderProofTests.enabled))
    func staleNotchAndSharedAgentRows() async throws {
        let root = PanelCompositionTests.session("claude:root", group: "group", workers: 1)
        let worker = PanelCompositionTests.session("codex:worker", provider: "codex", group: "group", worker: true)
        let ordinary = PanelCompositionTests.session("factory:ordinary", provider: "factory")
        let unlinked = PanelCompositionTests.session("codex:unlinked", provider: "codex", worker: true, unlinked: true)
        var stale = PanelCompositionTests.usage(elapsed: true)
        stale.state = "stale"
        stale.readAt = stamp - 18_600
        stale.statusText = "Quota service did not answer"
        let state = CoreState(sessions: [root, worker, ordinary, unlinked], usage: CoreUsage(providers: [stale]),
                              agentGroups: [PanelCompositionTests.group([root.id, worker.id])])
        for dark in [false, true] {
            let (toy, owner, _) = NotchSurfaceRenderProofTests.makeToy(state: state)
            defer { withExtendedLifetime(owner) {} }
            toy.cardModel.rows = toy.islandSummary.rows
            toy.cardModel.meters = NotchIsland.meters(state.usage)
            let card = NotchCardView(model: toy.cardModel, style: .island, width: 400,
                pinnedLayout: true, stillTurn: 1, stillReduced: true, proofNow: Date(timeIntervalSince1970: stamp))
                .proofExpandedGroups([root.id])
                .padding(.top, 32)
                .background(.black, in: NotchSilhouette(notchDepth: 32, restingRadius: 8))
                .padding(JRBarTokens.Space.xl)
            let meter = try #require(toy.cardModel.meters.first?.usage)
            let reading = UsageGaugeReading(window: meter.windows[0], provider: meter, now: stamp)
            #expect(reading.elapsed && reading.percentUsed == nil)
            #expect(UsageGaugeReading.age(provider: meter, now: stamp, snapshotReceivedAt: stamp) == "Read 5h 10m ago")
            try await U5Proof.render(card, name: "fix-a-notch-stale-groups", width: 448, dark: dark)
        }
    }

    @Test(.enabled(if: U5RenderProofTests.enabled))
    func titledUsageSelectionAndRetainedOverview() async throws {
        let saved = UserDefaults.standard.object(forKey: "usageCenter.provider")
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: "usageCenter.provider") }
            else { UserDefaults.standard.removeObject(forKey: "usageCenter.provider") }
        }
        var provider = PanelCompositionTests.usage(elapsed: true)
        provider.readAt = stamp - 18_600
        provider.state = "stale"
        provider.statusText = "Quota service did not answer"
        let panel = PanelCompositionTests.store(usage: [provider, PanelCompositionTests.usage("codex")])
        let store = UsageCenterStore(core: panel.core)
        store.now = Date(timeIntervalSince1970: stamp)
        for dark in [false, true] {
            for selection in ["overview", provider.identity] {
                UserDefaults.standard.set(selection, forKey: "usageCenter.provider")
                try await U5Proof.render(UsageCenterView(store: store).frame(height: 720),
                    name: "fix-a-usage-selected-" + (selection == "overview" ? "overview" : "provider"),
                    width: 1050, dark: dark, title: "Usage Center")
            }
        }
        panel.core.handle(.disconnected(reason: "Fixture monitor stopped"))
        for dark in [false, true] {
            UserDefaults.standard.set("overview", forKey: "usageCenter.provider")
            try await U5Proof.render(UsageCenterView(store: store).frame(height: 720),
                name: "fix-a-usage-retained", width: 1050, dark: dark, title: "Usage Center")
        }
    }

    @Test(.enabled(if: U5RenderProofTests.enabled))
    func compactFooterAndDeviceControls() async throws {
        let root = PanelCompositionTests.session("claude:root", group: "group", workers: 1)
        let worker = PanelCompositionTests.session("codex:worker", provider: "codex", group: "group", worker: true)
        let unlinked = PanelCompositionTests.session("factory:unlinked", provider: "factory", worker: true, unlinked: true)
        let store = PanelCompositionTests.store([root, worker, unlinked],
            groups: [PanelCompositionTests.group([root.id, worker.id])], usage: [PanelCompositionTests.usage()])
        store.expandedAgentGroups.insert(root.id)
        for dark in [false, true] {
            for width: CGFloat in [320, PanelComposition.width] {
                try await U5Proof.render(PanelView(store: store, panelWidth: width),
                    name: "fix-a-panel-\(Int(width))", width: width, dark: dark)
            }
            try await U5Proof.render(PanelDevicesRow(store: store).frame(width: 348).padding(.vertical, JRBarTokens.Space.sm),
                name: "fix-a-panel-devices", width: 348, dark: dark)
        }
    }
}
