import JRBarTestSupport
import AppKit
import JRBarCore
import JRBarLEDS
import SwiftUI
import Testing
@testable import JRBarApp

@Suite("Studio repair render proof", .renderProofAppearance)
@MainActor
struct StudioRepairRenderProofTests {
    @Test("swing width only renames Pendulum's glow control")
    func swingWidthKeepsPackLabels() {
        let parameter = EffectParameter(name: "glow", type: .number, defaultValue: .number(1.6))
        #expect(EffectParameterRow(parameter: parameter, value: .number(1.6), effectID: "pendulum", onChange: { _ in }).title == "Swing width")
        #expect(EffectParameterRow(parameter: parameter, value: .number(1.6), effectID: "pack:night", onChange: { _ in }).title == "Glow")
    }

    @Test("a sweep seed clears inherited light in the Screen Bar sampler")
    func sweepSeedClearsInheritedLight() throws {
        let source = "#000000 0ms; 0:#0088FF 0ms\n0:#000000 400ms cosine; 1:#0088FF 400ms 200ms\n1:#000000 400ms cosine; 0:#0088FF 400ms 200ms\nrepeat"
        let compiled = LEDSPresentationCompiler.compile(source, ledCount: 2)
        #expect(compiled.accepted)
        #expect(!compiled.transformed)
        let parsed = try LEDSProgram.parse(compiled.program, ledCount: 2)
        let sampler = LEDSSampler(program: parsed, ledCount: 2,
                                  initialCodes: Array(repeating: RGB8(r: 204, g: 0, b: 0), count: 2))
        for time in stride(from: 16, through: 6000, by: 16) {
            let codes = sampler.codes(atMilliseconds: time)
            #expect(codes.allSatisfy { $0.r == 0 })
            #expect(codes.contains { $0.b > 0 })
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1"))
    func currentOutputAndFactoryConsent() throws {
        let path = ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF_DIR"] ?? "/tmp/jrbar-studio-repair"
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lights = CoreLights(surfaces: ["screen_bar": CoreLightSurface(program: "#168CFF", ledCount: 8)])
        let profile = FactorySessionProfile(browser: "zen", profile: "synthetic.default", label: "Test browser")
        let connection = FactoryBrowserConnectionModel(available: false, load: { [profile] },
            importSession: { _ in "unused" }, disconnect: { "unused" })
        connection.profiles = [profile]
        connection.selected = profile
        for dark in [false, true] {
            let output = EffectLiveOutput(lights: lights, connected: true).padding(16)
                .frame(width: 330, height: 160).background(Color(nsColor: .windowBackgroundColor))
            let bitmap = try SettingsRenderProofTests.snapshot(output, size: CGSize(width: 330, height: 160), dark: dark)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("studio-output-\(dark).png"))
            let sheet = FactoryBrowserConnectionSheet(model: connection, instance: "default", dismiss: {})
                .frame(width: 560, height: 620).background(Color(nsColor: .windowBackgroundColor))
            let consent = try SettingsRenderProofTests.snapshot(sheet, size: CGSize(width: 560, height: 620), dark: dark)
            let consentPNG = try #require(consent.representation(using: .png, properties: [:]))
            try consentPNG.write(to: directory.appendingPathComponent("factory-consent-\(dark).png"))
        }
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1"))
    func sweepBackgroundControl() throws {
        let path = ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF_DIR"] ?? "/tmp/jrbar-sweep-background"
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let background = EffectParameter(name: "background_glow", type: .number, defaultValue: .number(0),
                                         description: "Brightness behind the moving head.", minimum: 0, maximum: 100, unit: "%")
        let width = EffectParameter(name: "beam_width", type: .integer, defaultValue: .number(3), minimum: 2, maximum: 6)
        for dark in [false, true] {
            let view = VStack(alignment: .leading, spacing: 12) {
                Text("Knight Rider").font(.title2.weight(.semibold))
                EffectParameterRow(parameter: background, value: .number(0), onChange: { _ in })
                EffectParameterRow(parameter: width, value: .number(3), onChange: { _ in })
            }
            .padding(20).frame(width: 560, height: 190)
            .background(Color(nsColor: .windowBackgroundColor))
            let image = try SettingsRenderProofTests.snapshot(view, size: CGSize(width: 560, height: 190), dark: dark)
            let png = try #require(image.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("sweep-controls-\(dark).png"))
        }
    }

}
