import AppKit
@testable import JRBarCore
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
    func integratedLightHomesAsKeyWindows() async throws {
        try U5Proof.pinDefaultAccent()
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF_DIR"] ?? "/tmp/jrbar-u4-proof")
        let programs = try JSONDecoder().decode(Programs.self, from: Data(contentsOf: directory.appendingPathComponent("daemon-programs.json")))
        let core = CoreModel(socketPath: NSTemporaryDirectory() + "jrbar-integration-proof-unused.sock")
        let suite = ScratchDefaults.suiteName("studio-integration-render")
        defer { ScratchDefaults.remove(suite) }
        let store = EffectStudioStore(core: core, defaults: ScratchDefaults.open(suite))
        store.covered = true
        core.handle(.connected)
        core.apply(.state(CoreState(devices: [CoreDevice(id: "proof-strip", kind: "pro", leds: 8, connected: true),
                                             CoreDevice(id: "proof-dot", kind: "dot", leds: 2, connected: true)])))
        var document = SettingsDocument(programs.settings)
        document = document.replacing("devices", with: [["id": "proof-strip", "name": "SidePulse Pro", "blend_mode": "weave"],
                                                        ["id": "proof-dot", "name": "PulseDot", "signal_policy": "asks_only"]])
        document = document.replacing("dot_role", with: "status")
        core.apply(.settings(CoreSettings(generation: 1, document: document.root)))
        store.lightsStudio.settings.syncMirrors()
        store.lightsStudio.requestPlan = { programs.plan }
        store.lightsStudio.requestPreview = { scenario, mode in try #require(programs.previews["\(scenario)|\(mode)"]) }
        await store.lightsStudio.refreshPlan()
        await store.lightsStudio.refreshPreviews()
        for mode in [EffectStudioStore.Mode.colours, .devices] {
            store.mode = mode
            for dark in [false, true] {
                try await render(EffectStudioView(store: store), name: "integration-studio-\(mode.rawValue)",
                                 dark: dark, directory: directory)
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1"))
    func pagesAsKeyWindows() async throws {
        try U5Proof.pinDefaultAccent()
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
            apply(document.root, to: store, fixture: fixture)
            fixture.core.apply(.state(CoreState(devices: [CoreDevice(id: "proof-strip", kind: "pro", leds: 8, connected: true),
                                                         CoreDevice(id: "proof-dot", kind: "dot", leds: 2, connected: true)])))
            let coldStart = CACurrentMediaTime()
            try await render(EffectStudioView(store: store), name: "studio-cold-first-open", dark: false, directory: directory)
            try JSONSerialization.data(withJSONObject: ["first_key_capture_ms": (CACurrentMediaTime() - coldStart) * 1000])
                .write(to: directory.appendingPathComponent("cold-first-open.json"))
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
                apply(fallback.root, to: store, fixture: fixture)
                await store.lightsStudio.refreshPreviews()
                try await render(EffectStudioView(store: store), name: "studio-split-fallback", dark: dark, directory: directory)
                apply(document.root, to: store, fixture: fixture)
                await store.lightsStudio.refreshPreviews()
                try await restoredStates(store, fixture: fixture, document: document, programs: programs, dark: dark, directory: directory)
            }
            store.windowDidClose()
            await fixture.stop()
        } catch { store.windowDidClose(); await fixture.stop(); throw error }
    }

    private func restoredStates(_ store: EffectStudioStore, fixture: CoreCommandReplyFixture,
                                document: SettingsDocument, programs: Programs, dark: Bool, directory: URL) async throws {
        var saved = document.replacing("devices.0.brightness", with: 180)
        saved = saved.replacing("calibration_profiles.Day", with: LightProfiles.snapshot(of: saved))
        saved = saved.replacing("devices.0.brightness", with: 64)
        saved = saved.replacing("calibration_profiles.Night", with: LightProfiles.snapshot(of: saved))
        saved = saved.replacing("focus_profile_rules", with: ["com.apple.focus.work": "Night"])
        saved = saved.replacing("active_scene", with: "calm")
        saved = saved.replacing("active_scene_pack", with: "removed-pack")
        saved = saved.replacing("scene_state", with: ["effective_scene": "focus", "lease_id": "synthetic-lease"])
        apply(saved.root, to: store, fixture: fixture)
        #expect(LightProfiles.savedSlots(in: store.lightsStudio.settings.document) == ["Day", "Night"])
        store.mode = .profiles
        try await render(EffectStudioView(store: store), name: "studio-saved-profiles", dark: dark, directory: directory)
        try await render(VStack {
            CalibrationProfilesSection(store: store.lightsStudio.settings)
            FocusProfileRow(store: store.lightsStudio.settings, focusID: "com.apple.focus.work", name: "Work", saved: ["Day", "Night"])
        }.environment(\.settingGroupsInline, true).padding(), name: "studio-profile-focus-rule", dark: dark, directory: directory)
        store.mode = .scenes
        try await render(EffectStudioView(store: store), name: "studio-scene-lease-missing-pack", dark: dark, directory: directory)
        let comet = try #require(programs.catalog.effect("comet"))
        store.editProviderEffect(comet, parameters: ["duration_seconds": 4.6, "trail_length": 5])
        try await render(EffectStudioView(store: store), name: "studio-comet-authoring", dark: dark, directory: directory)
        store.beginAssigning(comet, scope: .project, target: "synthetic-project")
        try await render(AssignSheet(store: store), name: "studio-comet-project-assignment", dark: dark, directory: directory)
        store.assigning = false
        let rows = [EffectAssignment(effectID: "pack:removed:glow", scope: .project, targetID: "synthetic-project"),
                    EffectAssignment(effectID: "pack:removed:glow", scope: .scene, targetID: "focus"),
                    EffectAssignment(effectID: "none", scope: .global)]
        let reload = try #require(store.reload())
        try await fixture.pending(2)
        for name in ["list_effects", "list_assignments"] {
            let pending = try await fixture.core.send("fixture_pending")
            let requests = try #require(pending.result?["requests"]?.arrayValue)
            let index = try #require(requests.firstIndex { $0["name"]?.stringValue == name })
            let data = name == "list_effects" ? try JSONEncoder().encode(programs.catalog) : try JSONEncoder().encode(EffectAssignmentDocument(assignments: rows))
            let object = try #require(JSONDecoder().decode(JSONValue.self, from: data).objectValue)
            try await fixture.release(index: index, result: object)
        }
        await reload.value
        store.mode = .assignments
        try await render(EffectStudioView(store: store), name: "studio-orphaned-assignments", dark: dark, directory: directory)
        store.mode = .mix
        store.lightsStudio.scenario = .live
        for (state, program) in [("idle", "#334455"), ("classic", "#0088FF 1s pulse\nrepeat"), ("ask", "#FF8800 1s pulse\nrepeat")] {
            store.lightsStudio.requestPlan = {
                StudioLightPlan(mixes: programs.plan.mixes, devices: [
                    StudioLightPlan.Device(device: "virtual:status-bar", ledCount: 8, requestedMix: "classic", played: state,
                                          reason: state == "classic" ? "Working with Status Only." : "Current state: \(state).",
                                          warnings: [], program: program, cueReason: nil)])
            }
            await store.lightsStudio.refreshPlan()
            try await render(EffectStudioView(store: store), name: "studio-live-\(state)", dark: dark, directory: directory)
        }
        store.lightsStudio.requestPlan = { programs.plan }
        await store.lightsStudio.refreshPlan()
        store.lightsStudio.scenario = .three
        apply(document.root, to: store, fixture: fixture)
        await store.lightsStudio.refreshPreviews()
        store.lightsStudio.playOnDevices = false
        let audition = try #require(store.lightsStudio.playPreview())
        let fleetIndex = try await requestIndex("preview_fleet", fixture: fixture)
        try await fixture.release(index: fleetIndex, result: ["program": "#FF8800", "label": "Screen Bar override", "played": "alternate",
                                          "reason": "Screen Bar uses Alternate.", "warnings": [], "led_count": 8])
        let programIndex = try await requestIndex("preview_program", fixture: fixture)
        try await fixture.release(index: programIndex, result: [:])
        await audition.value
        try await render(EffectStudioView(store: store), name: "studio-screen-bar-audition", dark: dark, directory: directory)
        store.lightsStudio.playOnDevices = true
    }

    private func apply(_ document: JSONValue, to store: EffectStudioStore, fixture: CoreCommandReplyFixture) {
        let generation = (fixture.core.settings?.generation ?? 0) + 1
        fixture.core.apply(.settings(CoreSettings(generation: generation, document: document)))
        store.lightsStudio.settings.syncMirrors()
    }

    private func requestIndex(_ name: String, fixture: CoreCommandReplyFixture) async throws -> Int {
        var count = 1
        for _ in 0..<20 {
            try await fixture.pending(count)
            let pending = try await fixture.core.send("fixture_pending")
            let requests = try #require(pending.result?["requests"]?.arrayValue)
            if let index = requests.firstIndex(where: { $0["name"]?.stringValue == name }) { return index }
            count = requests.count + 1
        }
        throw CoreReplyError(code: "fixture_request_missing", message: name)
    }

    private func render<V: View>(_ view: V, name: String, dark: Bool, directory: URL, width: CGFloat = 1160) async throws {
        let appearance = try #require(NSAppearance(named: dark ? .darkAqua : .aqua))
        NSApplication.shared.setActivationPolicy(.regular)
        let content = view.tint(.blue).accentColor(.blue).environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.controlActiveState, .key).environment(\.renderSnapshot, true)
            .jrbarAccessibility(reduceMotion: true).frame(width: width, height: 860)
            .background(JRBarTokens.Ink.window)
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
