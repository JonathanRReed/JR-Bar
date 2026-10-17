import AppKit
import Foundation
@testable import JRBarCore
import SwiftUI
import Testing
@testable import JRBarApp

@MainActor
@Suite("Factory browser connection render proof")
struct FactoryBrowserConnectionRenderProofTests {
    nonisolated static let enabled = ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1"

    @Test(.enabled(if: Self.enabled, "set JRBAR_RENDER_PROOF=1 for Factory browser connection PNGs"))
    func connectionSheet() async throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF_DIR"]
            ?? "/tmp/jrbar-factory-browser-proof", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let profile = FactorySessionProfile(browser: "zen", profile: "synthetic.default", label: "Zen · synthetic.default")
        for dark in [false, true] {
            let model = FactoryBrowserConnectionModel(available: false, load: { [profile] },
                importSession: { _ in "Imported." }, disconnect: { "Removed." })
            await model.load()
            for width: CGFloat in [380, 480] {
                let height: CGFloat = width == 380 ? 560 : 540
                let size = CGSize(width: width, height: height)
                let view = FactoryBrowserConnectionSheet(model: model, instance: "work", dismiss: {})
                    .frame(width: width, height: height)
                    .background(dark ? Color(red: 0.12, green: 0.12, blue: 0.13) : Color.white)
                    .preferredColorScheme(dark ? .dark : .light)
                let bitmap = try ProofRender.render(view, size: size, dark: dark)
                let renderedImage = try #require(SettingsRenderProofTests.cropped(bitmap))
                let png = try #require(NSBitmapImageRep(cgImage: renderedImage).representation(using: .png, properties: [:]))
                try png.write(to: directory.appendingPathComponent("factory-browser-\(Int(width))-\(dark ? "dark" : "light").png"))
            }
        }
    }

    @Test(.enabled(if: Self.enabled, "set JRBAR_RENDER_PROOF=1 for Factory browser control PNGs"))
    func connectionControls() throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF_DIR"]
            ?? "/tmp/jrbar-factory-browser-proof", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let core = CoreModel()
        core.handle(.connected)
        for saved in [false, true] {
            let row = try JSONDecoder().decode(ProviderRow.self, from: Data("""
            {"id":"factory","instance":"work","label":"Factory","enabled":true,
             "credentials":[{"account":"web-session","available":\(saved)}]}
            """.utf8))
            for dark in [false, true] {
                let size = CGSize(width: 380, height: 200)
                let view = ProviderCredentialControls(row: row, core: core, onChanged: {})
                    .padding(20)
                    .frame(width: size.width, height: size.height, alignment: .topLeading)
                    .background(dark ? Color(red: 0.12, green: 0.12, blue: 0.13) : Color.white)
                    .preferredColorScheme(dark ? .dark : .light)
                let bitmap = try ProofRender.render(view, size: size, dark: dark)
                let renderedImage = try #require(SettingsRenderProofTests.cropped(bitmap))
                let png = try #require(NSBitmapImageRep(cgImage: renderedImage).representation(using: .png, properties: [:]))
                try png.write(to: directory.appendingPathComponent("factory-browser-controls-\(saved ? "saved" : "empty")-\(dark ? "dark" : "light").png"))
            }
        }
    }
}
