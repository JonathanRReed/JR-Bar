import JRBarTestSupport
import AppKit
@testable import JRBarCore
import SwiftUI
import Testing
@testable import JRBarApp

/// ImageRenderer produces bitmaps without creating or ordering a window.
@MainActor
@Suite("Reliability render proof", .renderProofAppearance)
struct ReliabilityRenderProofTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1"))
    func streamDeckConsentAndResetSaveFailure() async throws {
        let core = CoreModel()
        core.handle(.connected)
        core.apply(.state(CoreState(usage: CoreUsage(providers: [CoreProviderUsage(id: "claude", state: "ready")]))))
        core.apply(.settings(CoreSettings(generation: 1, schema: CoreProtocol.knownSettingsSchema,
            document: .object(["serve_enabled": .bool(false), "serve_answer_enabled": .bool(false)]))))
        let settings = SettingsStore(core: core)
        settings.openFolds.insert(SettingsFold.streamDeck)
        let usage = UsageCenterStore(core: core)
        usage.readResetStatus = { _ in CoreReply(id: "fixture", ok: true, result: .object([
            "persistence": .object(["dirty": .bool(true), "error": .string("refused_full")])])) }
        await usage.loadResetStatus().value
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF_DIR"] ?? "/tmp/jrbar-l7-proof")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for dark in [false, true] {
            let content = VStack(spacing: 20) {
                StreamDeckCard(store: settings)
                if usage.resetSaveFailure != nil { ResetSaveNotice {} }
            }
            .padding(24)
            .frame(width: 760)
            .background(dark ? Color(white: 0.12) : Color(white: 0.97))
            .environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.renderSnapshot, true)
            .environment(settings)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            let image = try #require(renderer.nsImage)
            let tiff = try #require(image.tiffRepresentation)
            let bitmap = try #require(NSBitmapImageRep(data: tiff))
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("consent-and-reset-save-\(dark ? "dark" : "light").png"))
        }
    }
}
