import AppKit
import Darwin
import JRBarUI
@testable import JRBarCore
import QuartzCore
import SwiftUI
@testable import JRBarApp

@main
@MainActor
struct StudioPreviewCost {
    struct Programs: Decodable {
        let plan: StudioLightPlan
        let previews: [String: StudioFleetPreview]
        let settings: JSONValue
    }

    static func main() async throws { try await Self().measure() }

    func measure() async throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let directory = URL(fileURLWithPath: try require(ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF_DIR"]))
        let programs = try JSONDecoder().decode(Programs.self,
            from: Data(contentsOf: directory.appendingPathComponent("daemon-programs.json")))
        let core = CoreModel(socketPath: "/tmp/jrbar-cost-unused.sock")
        core.handle(.connected)
        core.apply(.state(CoreState()))
        core.apply(.settings(CoreSettings(generation: 1, document: programs.settings)))
        let suite = "jrbar-studio-cost-" + UUID().uuidString
        let defaults = try require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = EffectStudioStore(core: core, defaults: defaults)
        store.lightsStudio.requestPlan = { programs.plan }
        store.lightsStudio.requestPreview = { scenario, mix in try self.require(programs.previews["\(scenario)|\(mix)"]) }
        await store.lightsStudio.refreshPlan()
        await store.lightsStudio.refreshPreviews()
        let host = NSHostingView(rootView: VStack { StudioStage(store: store); StudioMixPage(store: store) }
            .jrbarAccessibility(reduceMotion: false).frame(width: 1000, height: 860))
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1000, height: 860),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close(); store.windowDidClose() }
        window.contentView = host
        WindowPresenter.live.order(window)
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        CATransaction.flush()
        let strips = gatherStrips(in: host)
        precondition(strips.count >= 9)
        for strip in strips { _ = await strip.preparedKeyframes() }
        run(for: 0.5)
        precondition(window.occlusionState.contains(.visible))
        var rows: [[String: Any]] = []
        for iteration in 0..<5 {
            for keyframes in iteration.isMultiple(of: 2) ? [false, true] : [true, false] {
                for strip in strips { strip.usesKeyframes = keyframes }
                run(for: 0.2)
                let drawn = strips.map(\.framesDrawn)
                let before = strips.map(presentedColors)
                let wall = CACurrentMediaTime()
                let start = threadSeconds()
                run(for: 2)
                let cpu = threadSeconds() - start
                let elapsed = CACurrentMediaTime() - wall
                let frames = zip(strips, drawn).map { $0.framesDrawn - $1 }
                let active = strips.filter(\.isAnimating).count
                let changed = zip(before, strips.map(presentedColors)).filter { $0 != $1 }.count
                precondition(changed > 0, "The render server must change the visible colours")
                precondition(active >= 9)
                if keyframes { precondition(strips.filter(\.playingKeyframes).count >= 9) }
                else { precondition(frames.reduce(0, +) >= 100) }
                rows.append(["keyframes": keyframes, "main_thread_ms": cpu * 1000,
                             "wall_seconds": elapsed, "cpu_percent_of_one_core": cpu / elapsed * 100,
                             "sampled_frames": frames, "active_strips": active, "changed_previews": changed])
            }
        }
        var profiles: [[String: Any]] = []
        for keyframes in [false, true] {
            for strip in strips { strip.usesKeyframes = keyframes }
            let profiler = Process()
            profiler.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
            profiler.arguments = [String(ProcessInfo.processInfo.processIdentifier), "2", "10", "-file",
                                  directory.appendingPathComponent(keyframes ? "keyframes.sample" : "frame-clock.sample").path]
            let diagnostics = directory.appendingPathComponent(keyframes ? "keyframes-sample.log" : "frame-clock-sample.log")
            FileManager.default.createFile(atPath: diagnostics.path, contents: nil)
            let log = try FileHandle(forWritingTo: diagnostics)
            profiler.standardOutput = log
            profiler.standardError = log
            try profiler.run()
            let deadline = CACurrentMediaTime() + 15
            while profiler.isRunning && CACurrentMediaTime() < deadline { run(for: 0.5) }
            if profiler.isRunning { profiler.terminate(); throw NSError(domain: "StudioCostSampleTimeout", code: 1) }
            profiles.append(["keyframes": keyframes, "exit_status": profiler.terminationStatus])
            try log.close()
        }
        let output = try JSONSerialization.data(withJSONObject: ["strips": strips.count, "runs": rows, "profiles": profiles], options: [.prettyPrinted, .sortedKeys])
        try output.write(to: directory.appendingPathComponent("live-window-cost.json"))
    }

    private func run(for seconds: Double) {
        let stop = DispatchWorkItem { @Sendable in
            CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) {
                MainActor.assumeIsolated {
                    NSApp.stop(nil)
                    if let wake = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
                                                    windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
                        NSApp.postEvent(wake, atStart: true)
                    }
                }
            }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: stop)
        NSApp.run()
        stop.cancel()
    }

    private func presentedColors(_ strip: LEDStripLayerView) -> [CGFloat] {
        (strip.layer?.sublayers ?? []).flatMap { layer in
            let shown = layer.presentation() ?? layer
            if let gradient = shown as? CAGradientLayer {
                return ((gradient.colors as? [CGColor]) ?? []).flatMap { $0.components ?? [] }
            }
            return shown.backgroundColor?.components ?? []
        }
    }

    private func gatherStrips(in view: NSView) -> [LEDStripLayerView] {
        let own = (view as? LEDStripLayerView).map { [$0] } ?? []
        return own + view.subviews.flatMap { gatherStrips(in: $0) }
    }

    private func require<T>(_ value: T?) throws -> T {
        guard let value else { throw NSError(domain: "StudioCost", code: 1) }
        return value
    }

    private func threadSeconds() -> Double {
        var time = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &time)
        return Double(time.tv_sec) + Double(time.tv_nsec) / 1_000_000_000
    }
}
