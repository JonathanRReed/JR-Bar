import JRBarTestSupport
import JRBarUI
import AppKit
@testable import JRBarCore
import SwiftUI
import Testing
@testable import JRBarApp

@Suite("Settings duplicate controls proofs", .serialized, .renderProofAppearance)
@MainActor
struct SettingsDuplicatesRenderProofTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1"))
    func changedPages() async throws {
        let fixture = try SettingsRenderProofTests.fixture()
        defer { fixture.toys.shutdown() }
        fixture.core.handle(.connected)
        fixture.core.apply(.state(CoreState()))
        fixture.settings.openFolds.insert(SettingsFold.streamDeck)
        let suite = ScratchDefaults.suiteName("settings-duplicates-proof")
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = SystemTogglesStore.State(dockDriver: nil, defaults: defaults)
        state.takeAssertion = { _ in Issue.record("Proofs must not take power assertions"); return nil }
        let utility = KeepAwakeUtility(toggles: SystemTogglesStore(state: state))
        utility.proofHolders = []
        fixture.toys.state.notch.provider = .alcove
        for dark in [false, true] {
            try await U5Proof.render(VStack(alignment: .leading, spacing: 16) {
                Text("Keep Awake").font(.title2)
                SettingsFeatureDetail(toy: utility)
            }.padding(24).environment(fixture.settings), name: "s-keep-awake", width: 620, dark: dark)
            try await U5Proof.render(VStack(alignment: .leading, spacing: 16) {
                Text("Devices").font(.title2)
                DevicesPage(store: fixture.settings)
            }.padding(24), name: "s-devices", width: 620, dark: dark)
            try await U5Proof.render(VStack(alignment: .leading, spacing: 16) {
                Text("Remote").font(.title2)
                RemotePage(store: fixture.settings)
            }.padding(24), name: "s-remote", width: 620, dark: dark)
            try await U5Proof.render(VStack(alignment: .leading, spacing: 16) {
                Text("Utilities & Toys").font(.title2)
                UtilitiesPage(store: fixture.settings)
                ToysPage(store: fixture.settings)
            }.padding(24), name: "s-utilities", width: 620, dark: dark)
            try await U5Proof.render(VStack(alignment: .leading, spacing: 16) {
                Text("Notch").font(.title2)
                SettingsFeatureDetail(toy: fixture.toys.notch)
            }.padding(24), name: "s-notch-alcove", width: 620, dark: dark)
            try await U5Proof.render(VStack(alignment: .leading, spacing: 16) {
                Text("Shortcuts").font(.title2)
                ShortcutsPage(store: fixture.settings)
            }.padding(24), name: "s-shortcuts", width: 620, dark: dark)
            for mode in ["schedule", "display", "ambient"] {
                let root = try #require(fixture.core.settings?.document)
                let document = SettingsDocument(root).replacing("auto_dim.mode", with: .string(mode))
                let generation = (fixture.core.settings?.generation ?? 0) + 1
                fixture.core.apply(.settings(CoreSettings(generation: generation, schema: CoreProtocol.knownSettingsSchema,
                                                          document: document.root)))
                try await U5Proof.render(VStack(alignment: .leading, spacing: 16) {
                    Text("Studio / Colours").font(.title2)
                    StudioStateColours(settings: fixture.settings)
                }.padding(24), name: "s-auto-dim-\(mode)", width: 620, dark: dark)
            }
        }
    }
}
