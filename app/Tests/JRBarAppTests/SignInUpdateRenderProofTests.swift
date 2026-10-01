import AppKit
import Foundation
import SwiftUI
import Testing
@testable import JRBarApp
@testable import JRBarCore

/// Render proof for Fix sign-in and Update: the Usage Center's fix controls for a
/// stale Claude card, a signed-out Grok card and a card that is stale for another
/// reason; the signed-out card in the real Usage Center over the mock daemon; and
/// Settings › Agents' rows with their version, "available" note, Update button and
/// the daemon's one-line result. Off by default; set `JRBAR_RENDER_PROOF=1` to write
/// `signin-update-*.png` into `JRBAR_RENDER_PROOF_DIR`.
@Suite("Fix sign-in and Update render proof", .serialized)
@MainActor
struct SignInUpdateRenderProofTests {
    private static func snapshot<V: View>(_ view: V, size: CGSize, dark: Bool) throws -> NSBitmapImageRep {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let hosting = NSHostingView(rootView: view
            .environment(\.colorScheme, dark ? .dark : .light)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: -20000, y: -20000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        hosting.frame = NSRect(origin: .zero, size: size)
        for _ in 0..<6 {
            hosting.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        let scale: CGFloat = 2
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = size
        let context = try #require(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        appearance?.performAsCurrentDrawingAppearance {
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
        }
        NSGraphicsContext.restoreGraphicsState()
        window.contentView = nil
        window.close()
        return rep
    }

    private static func write<V: View>(_ name: String, size: CGSize, _ view: V) throws {
        let directory = WindowsRenderProofTests.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for dark in [false, true] {
            let rep = try snapshot(view, size: size, dark: dark)
            let png = try #require(rep.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("signin-update-\(name)-\(dark ? "dark" : "light").png"))
        }
    }

    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func fixSignInControls() async throws {
        let (core, process) = try await WindowsRenderProofTests.mock(startAt: 6)
        defer { process.terminate(); core.stop() }
        let store = UsageCenterStore(core: core)
        let claude = CoreProviderUsage(id: "claude", state: "stale", action: "Reconnect Claude", reason: "authentication_required")
        let grok = CoreProviderUsage(id: "grok", state: "needs_sign_in", action: "Run grok login", reason: "authentication_required")
        let codex = CoreProviderUsage(id: "codex", state: "stale", action: "Retry", reason: "local_reading_stale")
        let devin = CoreProviderUsage(id: "devin", state: "needs_sign_in", action: "Reconnect Devin", reason: "authentication_required")
        let staged = ProviderSignInResult(
            provider: "devin", outcome: .staged,
            message: "The stored Devin session was rejected and has been cleared. Copy a fresh API key (page opened), then click 'Import Devin browser session'.",
            signInURL: "https://app.devin.ai/settings/api-keys")
        let renewed = ProviderSignInResult(provider: "claude", outcome: .renewed,
                                           message: "Claude Code renewed its sign-in, so Claude usage is refreshing now.")
        let opened = ProviderSignInResult(
            provider: "grok", outcome: .openedTerminal,
            message: "Opened Ghostty on `grok login`: finish signing in there, JR-Bar notices on its own.",
            command: "grok login")
        let view = VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Claude · stale, sign-in expired").font(.headline)
                HStack(spacing: 10) { ProviderFixControls(provider: claude, store: store); Spacer() }
                SignInNoteLine(note: UsageCenterStore.signInNote(for: renewed))
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Grok · signed out").font(.headline)
                HStack(spacing: 10) { ProviderFixControls(provider: grok, store: store); Spacer() }
                SignInNoteLine(note: UsageCenterStore.signInNote(for: opened))
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Devin · token rejected (the card's own staged action)").font(.headline)
                HStack(spacing: 10) { ProviderFixControls(provider: devin, store: store); Spacer() }
                SignInNoteLine(note: UsageCenterStore.signInNote(for: staged))
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Codex · stale for another reason (no Fix sign-in)").font(.headline)
                HStack(spacing: 10) { ProviderFixControls(provider: codex, store: store); Spacer() }
            }
        }
        .padding(20)
        .frame(width: 560, alignment: .leading)
        try Self.write("fix-controls", size: CGSize(width: 560, height: 400), view)
    }

    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func signedOutCardInTheUsageCenter() async throws {
        let (core, process) = try await WindowsRenderProofTests.mock(startAt: 6)
        defer { process.terminate(); core.stop() }
        let store = UsageCenterStore(core: core)
        store.windowDidOpen()
        try await WindowsRenderProofTests.settle { !store.providers.isEmpty }
        let cursor = try #require(store.providers.first { $0.id == "cursor" })
        #expect(cursor.offersSignInFix)
        try Self.write("usage-center", size: CGSize(width: 780, height: 1340), UsageCenterView(store: store))
        store.windowDidClose()
    }

    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func agentsRows() async throws {
        let (core, process) = try await WindowsRenderProofTests.mock(startAt: 6)
        defer { process.terminate(); core.stop() }
        let updates: [String: ProviderUpdateStatus] = [
            "claude": ProviderUpdateStatus(phase: .idle, latestVersion: "2.1.290"),
            "codex": ProviderUpdateStatus(phase: .updated, fromVersion: "0.159.1", toVersion: "0.159.2",
                                          message: "Updated 0.159.1 to 0.159.2",
                                          finishedAt: Date().timeIntervalSince1970 - 30),
            "grok": ProviderUpdateStatus(phase: .running, message: "Updating Grok…"),
            "devin": ProviderUpdateStatus(phase: .failed, fromVersion: "3000.3.27",
                                          message: "Devin's updater failed (exit 1): network unreachable"),
            "opencode": ProviderUpdateStatus(phase: .needsTerminal,
                                             message: "OpenCode's updater needs a terminal: opened Ghostty on `opencode upgrade`. Finish the update there."),
            "gemini": ProviderUpdateStatus(phase: .idle, latestVersion: "0.62.0"),
        ]
        core.apply(.state(CoreState(generation: 999, health: .object([
            "hooks": .object(["claude": .string("ok"), "codex": .string("ok"), "grok": .string("ok"),
                              "devin": .string("ok"), "opencode": .string("ok"), "gemini": .string("ok")]),
            "detected": .object(["claude": .bool(true), "codex": .bool(true), "grok": .bool(true),
                                 "devin": .bool(true), "opencode": .bool(true), "gemini": .bool(true)]),
        ]), providerUpdates: updates)))
        let store = SettingsStore(core: core)
        func entry(_ provider: String, _ version: String) -> HooksDoctorEntry {
            var entry = HooksDoctorEntry(provider: provider, installed: true, hookEvents: 12)
            entry.version = version
            return entry
        }
        let versions = ["claude": "2.1.285", "codex": "0.159.1", "grok": "1.0.44", "devin": "3000.3.27",
                        "opencode": "1.18.33", "gemini": "0.46.0"]
        let view = VStack(alignment: .leading, spacing: 14) {
            ForEach(["claude", "codex", "grok", "devin", "opencode", "gemini"], id: \.self) { provider in
                AgentRow(store: store, provider: provider, doctor: entry(provider, versions[provider] ?? ""))
            }
            Divider()
            SettingToggle(store, "Check for agent updates", subtitle: ProviderUpdateChecksCopy.subtitle,
                          path: "provider_update_checks_enabled")
        }
        .padding(20)
        .frame(width: 560, alignment: .leading)
        try Self.write("agents-rows", size: CGSize(width: 560, height: 640), view)
        withExtendedLifetime(store) {}
    }
}
