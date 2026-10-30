import AppKit
import JRBarCore
import JRBarTestSupport
import JRBarUI
import SwiftUI
import Testing

@testable import JRBarApp

@Suite("Dock settings proofs", .serialized, .temporaryDirectory, .renderProofAppearance)
@MainActor
struct DockSettingsRenderProofTests {
    @Test(.enabled(if: SettingsRenderProofTests.enabled))
    func page() async throws {
        let fixture = try SettingsRenderProofTests.fixture()
        defer { fixture.toys.shutdown() }
        let sizes: [(name: String, width: CGFloat, height: CGFloat)] = [
            ("default", 610, 620), ("minimum", 430, 420),
        ]
        fixture.settings.page = .utilities
        fixture.settings.subpage = "dock"
        for size in sizes {
            for dark in [false, true] {
                let page = SettingsPageContainer(store: fixture.settings, page: .utilities)
                    .environment(\.renderSnapshot, true).jrbarAccessibility(reduceMotion: true)
                let bitmap = try SettingsRenderProofTests.snapshot(
                    page, size: CGSize(width: size.width, height: size.height), dark: dark)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                let directory = SettingsRenderProofTests.directory
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let name = "dock-\(size.name)-viewport-\(dark ? "dark" : "light").png"
                try png.write(to: directory.appendingPathComponent(name))
                fixture.settings.openFolds.insert(SettingsFeatureOptions.fold("dock"))
                let full = VStack(alignment: .leading, spacing: JRBarTokens.Space.lg) {
                    SettingsFeatureDetail(toy: fixture.utilities.dock, expandDisclosures: true)
                }.padding(JRBarTokens.Space.xl).environment(fixture.settings)
                try await U5Proof.render(full, name: "dock-\(size.name)-full", width: size.width, dark: dark)
                fixture.settings.openFolds.remove(SettingsFeatureOptions.fold("dock"))
            }
        }
    }
}
