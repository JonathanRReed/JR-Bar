import AppKit
import Foundation
import SwiftUI
import Testing
@testable import JRBarApp
@testable import JRBarCore

/// Render proof for the "room left elsewhere" line on a nearly spent usage card, and
/// for Settings › Alerts & Sounds › Phone alert. Off by default; set `JRBAR_RENDER_PROOF=1` to
/// write `room-elsewhere-*.png` into `JRBAR_RENDER_PROOF_DIR`.
@Suite("Room elsewhere and phone alert render proof", .serialized)
@MainActor
struct RoomElsewhereRenderProofTests {
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
            try png.write(to: directory.appendingPathComponent("room-elsewhere-\(name)-\(dark ? "dark" : "light").png"))
        }
    }

    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func nearlySpentCardNamesTheRoomElsewhere() async throws {
        let (core, process) = try await WindowsRenderProofTests.mock(startAt: 6)
        defer { process.terminate(); core.stop() }
        let now = Date().timeIntervalSince1970
        let claude = CoreProviderUsage(
            id: "claude",
            windows: [CoreUsageWindow(key: "five-hour", name: "5h", usedPct: 96, resetsAt: now + 1800)],
            fidelity: "official", state: "ready", observedAt: now, readAt: now)
        let codex = CoreProviderUsage(
            id: "codex",
            windows: [CoreUsageWindow(key: "five-hour", name: "5h", usedPct: 18, resetsAt: now + 9000)],
            fidelity: "stale", state: "stale", observedAt: now, readAt: now - 7500)
        core.apply(.state(CoreState(generation: 1000, usage: CoreUsage(refreshedAt: now, providers: [claude, codex]))))
        let store = UsageCenterStore(core: core)
        let view = VStack(spacing: 16) {
            ProviderUsageCard(provider: claude, store: store)
        }
        .padding(20)
        .frame(width: 720, alignment: .leading)
        try Self.write("usage-card", size: CGSize(width: 720, height: 420), view)
        withExtendedLifetime(store) {}
    }

    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func phoneAlertGroupInSettings() async throws {
        let (core, process) = try await WindowsRenderProofTests.mock(startAt: 6)
        defer { process.terminate(); core.stop() }
        let store = SettingsStore(core: core)
        try await WindowsRenderProofTests.settle { store.values.bool("ntfy_enabled") != nil }
        try Self.write("settings-off", size: CGSize(width: 640, height: 1100), RemotePage(store: store).padding(20))
        _ = try await core.send("set_setting", args: ["path": .string("ntfy_topic"), "value": .string("mac-agents-7k2q9x")])
        _ = try await core.send("set_setting", args: ["path": .string("ntfy_enabled"), "value": .bool(true)])
        try await WindowsRenderProofTests.settle { store.values.bool("ntfy_enabled") == true }
        try Self.write("settings-on", size: CGSize(width: 640, height: 1100), RemotePage(store: store).padding(20))
        withExtendedLifetime(store) {}
    }
}
