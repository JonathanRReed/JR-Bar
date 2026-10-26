import AppKit
import Foundation
import SwiftUI
import Testing
@testable import JRBarApp
@testable import JRBarCore

@MainActor
@Suite("Provider credential render proof")
struct ProviderCredentialRenderProofTests {
    nonisolated static let enabled = ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1"

    @Test(.enabled(if: Self.enabled, "set JRBAR_RENDER_PROOF=1 to write Factory credential PNGs"))
    func editorAndSavedKeyRow() throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF_DIR"]
            ?? "/tmp/jrbar-factory-credential-proof", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let model = ProviderCredentialEditorModel(provider: "factory", instance: "work", account: "api-key",
            available: false, save: { _ in }, remove: {})
        let row = try JSONDecoder().decode(ProviderRow.self, from: Data(#"""
        {"id":"factory","instance":"default","label":"Factory","enabled":true,
         "credentials":[{"account":"api-key","available":true}],
         "usage_consent":{"granted":false,"version":1,"question":"Show Factory usage?",
          "summary":"Asks Factory for usage with your saved API key.",
          "detail":"Asks Factory for billing and subscription usage. Off until you turn it on."}}
        """#.utf8))
        let core = CoreModel()
        let switches = ProviderUsageSwitchesModel()
        for dark in [false, true] {
            try write(ProviderCredentialEditor(model: model, dismiss: {}),
                name: "factory-key-editor-\(dark ? "dark" : "light")", size: CGSize(width: 470, height: 330), dark: dark, directory: directory)
            try write(ProviderUsageSwitchRow(row: row, model: switches, core: core).padding(20),
                name: "factory-saved-key-offline-row-\(dark ? "dark" : "light")", size: CGSize(width: 580, height: 210), dark: dark, directory: directory)
        }
    }

    @Test(.enabled(if: Self.enabled, "set JRBAR_RENDER_PROOF=1 for Kimi and Kilo key controls"))
    func kimiAndKiloCredentials() throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF_DIR"]
            ?? "/tmp/jrbar-provider-credential-proof", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let core = CoreModel()
        core.handle(.connected)
        core.apply(.state(CoreState()))
        for provider in ["kimi", "kilo"] {
            let name = ProviderStyle.style(for: provider).name
            let model = ProviderCredentialEditorModel(provider: provider, instance: "work", account: "api-key",
                available: false, save: { _ in }, remove: {})
            let document: [String: Any] = ["id": provider, "instance": "default", "label": name, "enabled": true,
                "credentials": [["account": "api-key", "available": true]],
                "usage_consent": ["granted": false, "version": 1, "question": "Show \(name) usage?",
                    "summary": "Reads quota with your connected credential.",
                    "detail": "Usage stays off until you turn it on."]]
            let data = try JSONSerialization.data(withJSONObject: document)
            let row = try JSONDecoder().decode(ProviderRow.self, from: data)
            for dark in [false, true] {
                try write(ProviderCredentialEditor(model: model, dismiss: {}),
                    name: "\(provider)-key-editor-\(dark ? "dark" : "light")",
                    size: CGSize(width: 470, height: 350), dark: dark, directory: directory)
                try write(ProviderUsageSwitchRow(row: row, model: ProviderUsageSwitchesModel(), core: core).padding(20),
                    name: "\(provider)-saved-key-row-\(dark ? "dark" : "light")",
                    size: CGSize(width: 620, height: 550), dark: dark, directory: directory)
            }
        }
    }

    @Test(.enabled(if: Self.enabled, "set JRBAR_RENDER_PROOF=1 for manual Kimi web tokens"))
    func kimiWebTokenEditor() throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF_DIR"]
            ?? "/tmp/jrbar-provider-credential-proof", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let model = ProviderCredentialEditorModel(provider: "kimi", instance: "work", account: "web-session",
            available: false, save: { _ in }, remove: {})
        for dark in [false, true] {
            try write(ProviderCredentialEditor(model: model, dismiss: {}),
                name: "kimi-web-token-editor-\(dark ? "dark" : "light")",
                size: CGSize(width: 470, height: 350), dark: dark, directory: directory)
        }
    }

    @Test(.enabled(if: Self.enabled, "set JRBAR_RENDER_PROOF=1 for named Kimi source controls"))
    func namedKimiSourceControls() throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF_DIR"]
            ?? "/tmp/jrbar-provider-credential-proof", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let row = try JSONDecoder().decode(ProviderRow.self, from: Data(#"{"id":"kimi","instance":"work","options":{"region":"international","source":"web"}}"#.utf8))
        let core = CoreModel()
        core.handle(.connected)
        core.apply(.state(CoreState()))
        for dark in [false, true] {
            try write(ProviderCredentialControls(row: row, core: core, onChanged: {}).padding(20),
                name: "kimi-named-international-source-\(dark ? "dark" : "light")",
                size: CGSize(width: 620, height: 480), dark: dark, directory: directory)
        }
    }

    @Test(.enabled(if: Self.enabled, "set JRBAR_RENDER_PROOF=1 for quota reset controls"))
    func quotaResetControls() throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF_DIR"]
            ?? "/tmp/jrbar-provider-credential-proof", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let core = CoreModel()
        let store = ToysStore(core: core, settings: SettingsStore(core: core), state: ToysState(),
                              cardModel: makeTestCardModel(), notchRuntimeEnabled: false, nativeSourcesEnabled: false)
        defer { store.confetti.shutdown() }
        for dark in [false, true] {
            try write(ConfettiControlsView(toy: store.confetti).padding(20),
                name: "confetti-quota-reset-controls-\(dark ? "dark" : "light")",
                size: CGSize(width: 680, height: 1900), dark: dark, directory: directory)
        }
    }

    @Test(.enabled(if: Self.enabled, "set JRBAR_RENDER_PROOF=1 for the Factory usage card"))
    func factoryUsageCard() throws {
        let path = try #require(ProcessInfo.processInfo.environment["JRBAR_FACTORY_PROOF_FIXTURE"])
        let usage = try JSONDecoder().decode(CoreUsage.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let provider = try #require(usage.providers.first)
        #expect(provider.id == "factory")
        #expect(provider.windows.count == 6)
        #expect(provider.windows.filter(\.detail).count == 3)
        #expect(provider.headlineWindow?.id == "standard-30d")
        let core = CoreModel()
        core.handle(.connected)
        core.apply(.state(CoreState(usage: usage)))
        let store = UsageCenterStore(core: core)
        store.now = Date(timeIntervalSince1970: 1_800_000_000)
        let connectedRow = try JSONDecoder().decode(ProviderRow.self, from: Data(#"""
        {"id":"factory","instance":"default","label":"Factory","enabled":true,
         "credentials":[{"account":"api-key","available":true}],
         "usage_consent":{"granted":true,"version":1,"question":"Show Factory usage?",
          "summary":"Asks Factory for usage with your saved API key.",
          "detail":"Asks api.factory.ai for Standard and Core usage windows with your saved API key."}}
        """#.utf8))
        #expect(core.isLive)
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF_DIR"]
            ?? "/tmp/jrbar-factory-credential-proof", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for dark in [false, true] {
            try write(ProviderUsageSwitchRow(row: connectedRow, model: ProviderUsageSwitchesModel(), core: core).padding(20),
                name: "factory-connected-row-\(dark ? "dark" : "light")",
                size: CGSize(width: 580, height: 210), dark: dark, directory: directory)
            try write(UsageProviderDetail(provider: provider, store: store, showCost: true).padding(20),
                name: "factory-usage-card-\(dark ? "dark" : "light")",
                size: CGSize(width: 820, height: 880), dark: dark, directory: directory)
            let disabled = CoreProviderUsage(id: "factory", state: "disabled")
            try write(UsageProviderDetail(provider: disabled, store: store, showCost: true).padding(20),
                name: "factory-usage-off-card-\(dark ? "dark" : "light")",
                size: CGSize(width: 820, height: 460), dark: dark, directory: directory)
            let missing = CoreProviderUsage(id: "factory", state: "needs_sign_in", action: "Add Factory API key",
                                             reason: "authentication_required")
            try write(UsageProviderDetail(provider: missing, store: store, showCost: true).padding(20),
                name: "factory-key-needed-card-\(dark ? "dark" : "light")",
                size: CGSize(width: 820, height: 460), dark: dark, directory: directory)
        }
    }

    private func write(_ view: some View, name: String, size: CGSize, dark: Bool, directory: URL) throws {
        let background = dark ? Color(red: 0.12, green: 0.12, blue: 0.13) : Color.white
        let framed = view
            .frame(width: size.width, alignment: .topLeading)
            .background(background)
            .preferredColorScheme(dark ? .dark : .light)
        let rep = try ProofRender.render(framed, size: size, dark: dark)
        let image = try #require(SettingsRenderProofTests.cropped(rep))
        let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent("\(name).png"))
    }
}
