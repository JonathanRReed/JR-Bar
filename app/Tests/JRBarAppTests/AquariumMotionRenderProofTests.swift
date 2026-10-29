import JRBarTestSupport
import AppKit
import Foundation
import SwiftUI
import Testing
import JRBarCore
@testable import JRBarApp

@Suite("Aquarium motion render proof", .renderProofAppearance)
@MainActor
struct AquariumMotionRenderProofTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1",
                   "set JRBAR_RENDER_PROOF=1 for three focused motion PNGs"))
    func snapshots() throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF_DIR"]
                            ?? "/tmp/jrbar-aquarium-motion", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let now = Date()
        let roster = [
            Fish(id: "working", label: "Review patch", providerID: "claude", state: .swimming,
                 lane: 0.4, speed: 0.1, direction: 1, stateSince: now, enteredAt: .distantPast),
            Fish(id: "waiting", label: "Needs a decision", providerID: "codex", state: .surfacing,
                 lane: 0.5, speed: 0.1, direction: -1, stateSince: now, enteredAt: .distantPast),
            Fish(id: "failed", label: "Failed run", providerID: "gemini", state: .sinking,
                 lane: 0.6, speed: 0.1, direction: 1, stateSince: now, enteredAt: .distantPast),
        ]
        var still = AquariumSettings()
        still.motion = .still
        let fixture = AquariumView.Fixture(fish: roster, night: 0, settings: still,
                                           visualTime: 1_800_000_000)
        try write(AquariumView(fixture: fixture), size: CGSize(width: 900, height: 520),
                  name: "aquarium-still-status", into: directory)

        let core = CoreModel()
        let store = ToysStore(core: core, settings: SettingsStore(core: core), state: ToysState(),
                              cardModel: makeTestCardModel(), notchRuntimeEnabled: false)
        let file = AquariumToy.scratchSave()
        let toy = AquariumToy(core: core, store: store, saveFile: file)
        defer {
            toy.flushSave()
            try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent())
        }
        for mode in AquariumSettings.Motion.allCases {
            store.state.aquarium.motion = mode
            try write(AquariumControlsView(toy: toy).padding(16),
                      size: CGSize(width: 620, height: 760),
                      name: "aquarium-motion-card-\(mode.rawValue)", into: directory)
        }
        withExtendedLifetime(store) {}
    }

    private func write(_ content: some View, size: CGSize, name: String, into directory: URL) throws {
        let appearance = NSAppearance(named: .aqua)
        let host = NSHostingView(rootView: content
            .environment(\.colorScheme, .light)
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: -20000, y: -20000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        defer {
            window.contentView = nil
            window.close()
        }
        for _ in 0..<6 {
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = size
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        appearance?.performAsCurrentDrawingAppearance {
            host.cacheDisplay(in: host.bounds, to: bitmap)
        }
        NSGraphicsContext.restoreGraphicsState()
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent("\(name).png"))
    }
}
