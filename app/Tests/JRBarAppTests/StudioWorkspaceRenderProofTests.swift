import AppKit
import JRBarCore
import JRBarUI
import QuartzCore
import SwiftUI
import Testing
@testable import JRBarApp

@MainActor
@Suite("Studio workspace render proofs", .serialized, .timeLimit(.minutes(3)))
struct StudioWorkspaceRenderProofTests {
    struct Programs: Decodable {
        let plan: StudioLightPlan
        let previews: [String: StudioFleetPreview]
        let catalog: EffectCatalog
        let providers: [String: String]
        let cues: [LightCueState]
        let settings: JSONValue
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1"))
    func pagesAsKeyWindows() async throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF_DIR"] ?? "/tmp/jrbar-u4-proof")
        let programs = try JSONDecoder().decode(Programs.self, from: Data(contentsOf: directory.appendingPathComponent("daemon-programs.json")))
        let fixture = try CoreCommandReplyFixture()
        let suite = ScratchDefaults.suiteName("studio-render")
        defer { ScratchDefaults.remove(suite) }
        let store = EffectStudioStore(core: fixture.core, defaults: ScratchDefaults.open(suite))
        store.covered = true
        store.scenePackLoader = { [] }
        store.renderer = { id, _, _, _ in programs.catalog.effect(id)?.preview ?? EffectPreview(program: "off") }
        store.lightsStudio.requestPlan = { programs.plan }
        store.lightsStudio.requestPreview = { scenario, mode in try #require(programs.previews["\(scenario)|\(mode)"]) }
        store.lightsStudio.requestProvider = { provider in programs.providers[provider] ?? "off" }
        store.lightsStudio.requestCues = { LightCueList(cues: programs.cues) }
        do {
            try await fixture.start()
            var document = SettingsDocument(programs.settings)
            document = document.replacing("devices", with: [["id": "proof-strip", "name": "SidePulse Pro", "blend_mode": "weave"],
                                                            ["id": "proof-dot", "name": "PulseDot", "signal_policy": "asks_only"]])
            document = document.replacing("dot_role", with: "status")
            fixture.core.apply(.settings(CoreSettings(generation: 2, document: document.root)))
            fixture.core.apply(.state(CoreState(devices: [CoreDevice(id: "proof-strip", kind: "pro", leds: 8, connected: true),
                                                         CoreDevice(id: "proof-dot", kind: "dot", leds: 2, connected: true)])))
            let load = try #require(store.reload())
            try await fixture.pending(2)
            for name in ["list_effects", "list_assignments"] {
                let pending = try await fixture.core.send("fixture_pending")
                let requests = try #require(pending.result?["requests"]?.arrayValue)
                let index = try #require(requests.firstIndex { $0["name"]?.stringValue == name })
                let data = name == "list_effects" ? try JSONEncoder().encode(programs.catalog) : try JSONEncoder().encode(EffectAssignmentDocument())
                let object = try #require(JSONDecoder().decode(JSONValue.self, from: data).objectValue)
                try await fixture.release(index: index, result: object)
            }
            await load.value
            await store.lightsStudio.refreshPlan()
            await store.lightsStudio.refreshPreviews()
            await store.lightsStudio.refreshSupportingPreviews()
            for dark in [false, true] {
                for mode in EffectStudioStore.Mode.allCases {
                    store.mode = mode
                    try await render(EffectStudioView(store: store), name: "studio-\(mode.rawValue)", dark: dark, directory: directory)
                }
                store.mode = .mix
                store.lightsStudio.scenario = .ask
                await store.lightsStudio.refreshPreviews()
                try await render(EffectStudioView(store: store), name: "studio-ask", dark: dark, directory: directory)
                store.lightsStudio.scenario = .live
                store.lightsStudio.inspector = true
                try await render(EffectStudioView(store: store), name: "studio-live-inspector", dark: dark, directory: directory, width: 1400)
                store.lightsStudio.scenario = .three
                store.lightsStudio.inspector = false
                let fallback = document.replacing("colors.blend_mode", with: "spatial_split")
                fixture.core.apply(.settings(CoreSettings(generation: 3, document: fallback.root)))
                await store.lightsStudio.refreshPreviews()
                try await render(EffectStudioView(store: store), name: "studio-split-fallback", dark: dark, directory: directory)
                fixture.core.apply(.settings(CoreSettings(generation: 4, document: document.root)))
                await store.lightsStudio.refreshPreviews()
            }
            store.windowDidClose()
            await fixture.stop()
        } catch { store.windowDidClose(); await fixture.stop(); throw error }
    }

    private func render<V: View>(_ view: V, name: String, dark: Bool, directory: URL, width: CGFloat = 1160) async throws {
        let appearance = try #require(NSAppearance(named: dark ? .darkAqua : .aqua))
        NSApplication.shared.setActivationPolicy(.regular)
        let content = view.environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.controlActiveState, .key).environment(\.renderSnapshot, true)
            .jrbarAccessibility(reduceMotion: true).frame(width: width, height: 860)
        let host = NSHostingView(rootView: content)
        host.appearance = appearance
        let window = StudioProofWindow(contentRect: NSRect(x: -10000, y: -10000, width: width, height: 860),
                                       styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.contentView = host
        defer { window.close() }
        try WindowPresenter.renderProofKey(window)
        if !window.isKeyWindow { runUntilKey(window) }
        host.frame = NSRect(x: 0, y: 0, width: width, height: 860)
        await Task.yield()
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        CATransaction.flush()
        try #require(window.isKeyWindow)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
    }

    private func runUntilKey(_ window: NSWindow) {
        let observer = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: nil) { _ in
            MainActor.assumeIsolated { NSApp.stop(nil) }
        }
        let loop = CFRunLoopGetMain()
        CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue) {
            MainActor.assumeIsolated { try? WindowPresenter.renderProofKey(window) }
        }
        let timeout = DispatchWorkItem { @Sendable in
            let main = CFRunLoopGetMain()
            CFRunLoopPerformBlock(main, CFRunLoopMode.defaultMode.rawValue) {
                MainActor.assumeIsolated {
                    NSApp.stop(nil)
                    if let wake = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
                                                    windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
                        NSApp.postEvent(wake, atStart: true)
                    }
                }
            }
            CFRunLoopWakeUp(main)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2, execute: timeout)
        NSApp.run()
        timeout.cancel()
        NotificationCenter.default.removeObserver(observer)
    }
}

private final class StudioProofWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}
