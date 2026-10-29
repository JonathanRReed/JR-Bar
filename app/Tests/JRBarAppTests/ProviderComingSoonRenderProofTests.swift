import JRBarTestSupport
import AppKit
import JRBarCore
import SwiftUI
import Testing
@testable import JRBarApp

@MainActor
@Suite("Coming soon provider render proof", .renderProofAppearance)
struct ProviderComingSoonRenderProofTests {
    nonisolated static let enabled = ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1"
    private let available: Set<String> = ["codex", "claude", "cursor", "devin", "grok", "gemini",
        "antigravity", "opencode", "factory", "openai-api", "kimi", "kilo", "kiro"]

    @Test(.enabled(if: Self.enabled, "set JRBAR_RENDER_PROOF=1 for provider roadmap PNGs"))
    func states() throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF_DIR"]
            ?? "/tmp/jrbar-provider-roadmap-proof", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for dark in [false, true] {
            try write(ProviderComingSoonView(availableProviderIDs: available),
                      name: "collapsed", height: 90, dark: dark, directory: directory)
            try write(ProviderComingSoonList(availableProviderIDs: available, query: .constant("")),
                      name: "catalog", height: 1450, dark: dark, directory: directory)
            try write(ProviderComingSoonList(availableProviderIDs: available, query: .constant("copilot")),
                      name: "search", height: 210, dark: dark, directory: directory)
            try write(ProviderComingSoonList(availableProviderIDs: available, query: .constant("no-such-provider")),
                      name: "empty", height: 210, dark: dark, directory: directory)
        }
    }

    private func write(_ view: some View, name: String, height: CGFloat, dark: Bool, directory: URL) throws {
        let background = dark ? Color(red: 0.12, green: 0.12, blue: 0.13) : Color.white
        let content = view.padding(20).frame(width: 620, alignment: .topLeading)
            .background(background).preferredColorScheme(dark ? .dark : .light)
        let rep = try ProofRender.render(content, size: CGSize(width: 620, height: height), dark: dark)
        let image = try #require(SettingsRenderProofTests.cropped(rep))
        let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [.compressionFactor: 1]))
        try png.write(to: directory.appendingPathComponent("coming-soon-\(name)-\(dark ? "dark" : "light").png"))
    }
}
