import AppKit
import JRBarCore
import JRBarUI
import SwiftUI
import Testing
@testable import JRBarApp

@MainActor
@Suite("Design fix B render proofs", .serialized)
struct DesignFixBRenderProofTests {
    init() throws {
        if ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1" { try U5Proof.pinDefaultAccent() }
    }

    @Test(.enabled(if: SettingsRenderProofTests.enabled))
    func sidebarSelection() async throws {
        let settings = SettingsStore(core: CoreModel())
        settings.page = .devices
        for dark in [false, true] {
            try await SettingsRenderProofTests.keySnapshot(SettingsRootView(store: settings), name: "b-sidebar",
                                                           height: 620, dark: dark)
            let selection = Label("Mix", systemImage: "slider.horizontal.3").jrbarSidebarSelection(true)
            let bitmap = try await DesignFixBProof.snapshot(selection, title: "Sidebar selection",
                                                            size: CGSize(width: 220, height: 80), dark: dark)
            var blue: [(Int, Int)] = []
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
                for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
                    let color = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                    if color.blueComponent > 0.7 && color.blueComponent > color.redComponent + 0.3 {
                        blue.append((x, y))
                    }
                }
            }
            try #require(blue.count > 1000, "The shared selection uses the proof's blue tint")
            let left = try #require(blue.map(\.0).min()) + 20
            let right = try #require(blue.map(\.0).max()) - 20
            let top = try #require(blue.map(\.1).min()) + 10
            let bottom = try #require(blue.map(\.1).max()) - 10
            var white = 0
            for y in stride(from: top, to: bottom, by: 2) {
                for x in stride(from: left, to: right, by: 2) {
                    let color = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                    if min(color.redComponent, color.greenComponent, color.blueComponent) > 0.9 { white += 1 }
                }
            }
            #expect(white > 10, "Selected text and icons stay white on blue")
            try await DesignFixBProof.write(selection, name: "b-shared-selection", title: "Sidebar selection",
                                            size: CGSize(width: 220, height: 80), dark: dark)
        }
    }

    @Test(.enabled(if: SettingsRenderProofTests.enabled))
    func welcomeWindows() async throws {
        var model = SetupModel()
        model.monitorLive = { true }
        model.agents = { [SetupAgent(id: "claude", name: "Claude", detected: true, hookStatus: "ok")] }
        model.usageOffers = { [SetupUsageOffer(id: "claude", name: "Claude", question: "Show usage?",
            summary: "Reads account quota after consent.", isOn: false)] }
        let store = SetupStore(model: model, load: { SetupState() }, persist: { _ in })
        await store.refreshUsageOffers()
        for _ in SetupStore.Step.allCases.dropLast() { store.goNext() }
        defer { store.stopPermissionUpdates() }
        #expect(store.summaryRows.contains { $0.text == "Usage" && $0.detail.contains(SettingsStore.Page.agents.title) })
        #expect(store.usageOffers.allSatisfy { !$0.isOn })
        for dark in [false, true] {
            try await DesignFixBProof.write(SetupView(store: store), name: "b-setup-done", title: "Welcome to JR-Bar",
                                            size: SetupWindowController.contentSize, dark: dark)
            try await DesignFixBProof.write(WhatsNewView(entries: WhatsNewCatalog.entries, tryIt: { _ in nil }, onDone: {}),
                name: "b-whats-new", title: "What's New in JR-Bar", size: CGSize(width: WhatsNewView.width, height: 660), dark: dark)
        }
    }

    @Test(.enabled(if: SettingsRenderProofTests.enabled && DesignFixBProof.hasDaemonPrograms))
    func calmScreenBarUsesTheSameSteadyProgram() throws {
        let directory = DesignFixBProof.directory
        let programs = try JSONDecoder().decode(StudioWorkspaceRenderProofTests.Programs.self,
            from: Data(contentsOf: directory.appendingPathComponent("daemon-programs.json")))
        for mix in ["classic", "color_blend"] {
            for scenario in ["one_working", "pair", "fleet"] {
                let preview = try #require(programs.previews["\(scenario)|\(mix)"])
                let sampler = try #require(LEDPreviewSamplers.sampler(for: preview.program, ledCount: preview.ledCount))
                #expect(sampler.isStatic)
                #expect(preview.motionNotice == nil)
            }
            let ask = try #require(programs.previews["one_needs_you|\(mix)"])
            #expect(ask.played == "ask")
            let sampler = try #require(LEDPreviewSamplers.sampler(for: ask.program, ledCount: ask.ledCount))
            #expect(!sampler.isStatic)
        }
    }
}
