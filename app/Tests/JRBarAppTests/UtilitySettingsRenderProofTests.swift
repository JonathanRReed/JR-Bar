import AppKit
import JRBarCore
import JRBarTestSupport
import JRBarUI
import SwiftUI
import Testing

@testable import JRBarApp

@Suite("Utility settings proofs", .serialized, .temporaryDirectory, .renderProofAppearance)
@MainActor
struct UtilitySettingsRenderProofTests {
    static let cards = ["dock", "keepAwake", "menuBar", "agents", "fold", "aquarium", "notch-buddy", "confetti", "notch"]

    @Test(.enabled(if: SettingsRenderProofTests.enabled))
    func pages() async throws {
        let fixture = try SettingsRenderProofTests.fixture()
        defer { fixture.toys.shutdown() }
        fixture.utilities.menuBar.readAccessibilityTrust = { false }
        fixture.utilities.menuBar.readInventoryEvidence = { (0, false) }
        fixture.utilities.menuBar.probeAccessibility()
        fixture.toys.seasonal.clock = { Date(timeIntervalSince1970: 1_800_000_000) }
        fixture.toys.state.seasonal.enabled = true
        let awake = KeepAwakeUtility.shared
        let previousHolders = awake.proofHolders
        awake.proofHolders = []
        defer { awake.proofHolders = previousHolders }
        let sizes: [(name: String, width: CGFloat, height: CGFloat)] = [
            ("default", 610, 620), ("minimum", 430, 420),
        ]
        let extrasOnly = ProcessInfo.processInfo.environment["JRBAR_UTILITY_PROOF_ONLY"] == "extras"
        for size in sizes {
            for dark in [false, true] {
                for id in Self.cards where !extrasOnly {
                    let toy = try #require(fixture.settings.cardToy(id))
                    fixture.settings.page = id == "notch" ? .notch : .utilities
                    fixture.settings.subpage = id == "notch" ? nil : id
                    let page = SettingsPageContainer(store: fixture.settings, page: fixture.settings.page)
                    try write(page, name: "\(id)-\(size.name)-viewport", size: size, dark: dark)
                    let previousFolds = fixture.settings.openFolds
                    fixture.settings.openFolds.insert(SettingsFeatureOptions.fold(id))
                    if id == "agents" {
                        let providers = fixture.utilities.agents.alertProviders
                        fixture.settings.openFolds.formUnion(providers.map(SettingsFeatureOptions.agentProvider))
                    }
                    let full = VStack(alignment: .leading, spacing: JRBarTokens.Space.lg) {
                        SettingsFeatureDetail(toy: toy, expandDisclosures: true)
                    }.padding(JRBarTokens.Space.xl).environment(fixture.settings)
                    try await U5Proof.render(full, name: "\(id)-\(size.name)-full", width: size.width, dark: dark)
                    fixture.settings.openFolds = previousFolds
                }
                let extras: [(name: String, view: AnyView)] = [
                    ("seasonal", AnyView(SeasonalSettingsSection(toys: fixture.toys))),
                    (
                        "screen-bar",
                        AnyView(
                            ScreenBarSettingsCard(
                                store: fixture.settings,
                                device: fixture.settings.deviceEntries.first { $0.kind == "screen_bar" }))
                    ),
                    ("control-center", AnyView(ShortcutsPage(store: fixture.settings))),
                ]
                for extra in extras {
                    let content = VStack(alignment: .leading, spacing: JRBarTokens.Space.lg) {
                        extra.view
                    }.padding(JRBarTokens.Space.xl).environment(fixture.settings)
                        .cardBodyStyle()
                    let viewport = ScrollView { content }.background(JRBarTokens.Ink.content)
                    try write(viewport, name: "\(extra.name)-\(size.name)-viewport", size: size, dark: dark)
                    let fold = extra.name == "seasonal" ? SettingsFeatureOptions.fold("seasonal")
                        : extra.name == "screen-bar" ? SettingsFold.screenBarAdvanced : SettingsFold.quickToggles
                    fixture.settings.openFolds.insert(fold)
                    try await U5Proof.render(content, name: "\(extra.name)-\(size.name)-full", width: size.width, dark: dark)
                    fixture.settings.openFolds.remove(fold)
                }
            }
        }
    }

    private func write<V: View>(
        _ view: V, name: String,
        size: (name: String, width: CGFloat, height: CGFloat), dark: Bool
    ) throws {
        let staged = view.environment(\.renderSnapshot, true).jrbarAccessibility(reduceMotion: true)
        let image = try SettingsRenderProofTests.snapshot(
            staged,
            size: CGSize(width: size.width, height: size.height), dark: dark)
        let png = try #require(image.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(at: SettingsRenderProofTests.directory, withIntermediateDirectories: true)
        let filename = "\(name)-\(dark ? "dark" : "light").png"
        try png.write(to: SettingsRenderProofTests.directory.appendingPathComponent(filename))
    }
}
