import AppKit
import Foundation
import ServiceManagement
import SwiftUI
import Testing
@testable import JRBarApp
@testable import JRBarCore

/// Settings-lag perf harness (scratch, not for the repo). Hosts the real
/// Settings views in an NSHostingController inside an offscreen,
/// never-ordered window, forces layout and display, and times it on the
/// main thread's CPU clock and the wall clock. Off unless JRBAR_PERF=1.
///
/// JRBAR_PERF_ITER   iterations per measurement (default 7)
/// JRBAR_PERF_OUT    CSV path to append rows to (default $TMPDIR/settings-perf.csv)
/// JRBAR_PERF_SOAK   page name: loop state pushes on that page for 8 s (for `sample`)
/// JRBAR_PERF_SOAK_KIND  state | lights | settings | edit (default state)
@Suite("Settings perf harness", .serialized)
@MainActor
struct SettingsPerfHarness {
    nonisolated static let enabled = ProcessInfo.processInfo.environment["JRBAR_PERF"] == "1"
    static let iterations = Int(ProcessInfo.processInfo.environment["JRBAR_PERF_ITER"] ?? "") ?? 7
    static let outPath = ProcessInfo.processInfo.environment["JRBAR_PERF_OUT"]
        ?? (NSTemporaryDirectory() + "settings-perf.csv")

    // MARK: Clocks

    struct Sample { var cpuMs: Double; var wallMs: Double }

    static func threadCPUns() -> UInt64 { clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) }
    static func processCPUns() -> UInt64 { clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID) }

    static func measure(_ body: () -> Void) -> Sample {
        let c0 = threadCPUns()
        let w0 = ContinuousClock.now
        body()
        let w = ContinuousClock.now - w0
        let c = threadCPUns() - c0
        let wallMs = Double(w.components.seconds) * 1000 + Double(w.components.attoseconds) / 1e15
        return Sample(cpuMs: Double(c) / 1e6, wallMs: wallMs)
    }

    static func median(_ xs: [Double]) -> Double {
        let s = xs.sorted(); guard !s.isEmpty else { return .nan }
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    static func p90(_ xs: [Double]) -> Double {
        let s = xs.sorted(); guard !s.isEmpty else { return .nan }
        return s[min(s.count - 1, Int((Double(s.count) * 0.9).rounded(.down)))]
    }

    static func record(_ name: String, _ samples: [Sample], note: String = "") {
        let cpu = samples.map(\.cpuMs), wall = samples.map(\.wallMs)
        let line = String(format: "%@,%d,%.2f,%.2f,%.2f,%.2f,%@\n", name, samples.count,
                          median(cpu), p90(cpu), median(wall), p90(wall), note)
        print("PERF " + line, terminator: "")
        let url = URL(fileURLWithPath: outPath)
        if !FileManager.default.fileExists(atPath: outPath) {
            try? "name,n,cpu_med_ms,cpu_p90_ms,wall_med_ms,wall_p90_ms,note\n".write(to: url, atomically: true, encoding: .utf8)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            try? handle.close()
        }
    }

    // MARK: Fixture

    struct Fixture {
        let core: CoreModel
        let settings: SettingsStore
        let toys: ToysStore
        let utilities: UtilitiesStore
    }

    static var fixturesDir: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "JRBarCoreTests/Fixtures")
    }

    /// The mock monitor's settings document (`mock-core.py`), the same
    /// source the render proof uses.
    static func document() throws -> JSONValue {
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "scripts/mock-core.py")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-c", """
            import importlib.util, json, sys
            spec = importlib.util.spec_from_file_location("mock_core", sys.argv[1])
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            print(json.dumps(module.default_settings_document()))
            """, script.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// `real_state.json` (a committed, synthetic fixture) as a state
    /// frame with the given generation and clock.
    static func stateFrame(_ generation: Int, base: [String: Any]) throws -> CoreMessage {
        var doc = base
        doc["t"] = "state"; doc["v"] = 1
        doc["generation"] = generation
        doc["now"] = 1_790_000_000.0 + Double(generation)
        // The fixture's device ids, renamed to the mock document's, so the
        // Devices page finds each device's state as it does live.
        let rename = ["sidepulse:pro:serial:d92e7f73b2794c5dec91cf90": "sidepulse:pro:B293A1",
                      "sidepulse:dot:serial:9744730147adfb147499e00f": "sidepulse:dot:7F02C4"]
        if var devices = doc["devices"] as? [[String: Any]] {
            for i in devices.indices {
                if let id = devices[i]["id"] as? String, let to = rename[id] { devices[i]["id"] = to }
                // One write moves each frame, as a live refresh would.
                if devices[i]["last_write"] != nil { devices[i]["last_write"] = 1_790_000_000.0 + Double(generation) }
            }
            doc["devices"] = devices
        }
        let data = try JSONSerialization.data(withJSONObject: doc)
        return try CoreCodec.decode(line: String(decoding: data, as: UTF8.self))
    }

    static func jsonObject(_ name: String) throws -> [String: Any] {
        let data = try Data(contentsOf: fixturesDir.appending(path: name))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    static func lightsFrame(_ n: Int, base: [String: Any]) throws -> CoreMessage {
        var doc = base
        doc["t"] = "lights"; doc["v"] = 1
        // A changing field so the frame is a real change.
        doc["linked_skew_ms"] = Double(n % 7)
        let data = try JSONSerialization.data(withJSONObject: doc)
        return try CoreCodec.decode(line: String(decoding: data, as: UTF8.self))
    }

    static func fixture() throws -> Fixture {
        let core = CoreModel(socketPath: NSTemporaryDirectory() + "jrbar-perf.sock")
        // Connected, as the live app is: `isLive` then reads `state`, so
        // views that ask it are tracked on every state push.
        if ProcessInfo.processInfo.environment["JRBAR_PERF_OFFLINE"] == nil { core.handle(.connected) }
        core.apply(.settings(CoreSettings(generation: 1, schema: CoreProtocol.knownSettingsSchema,
                                          document: try document())))
        let settings = SettingsStore(core: core)
        if ProcessInfo.processInfo.environment["JRBAR_PERF_COVERED"] == "1" { settings.windowCovered = true }
        let toys = ToysStore(core: core, settings: settings, state: ToysState(),
                             cardModel: makeTestCardModel(), notchRuntimeEnabled: false)
        settings.toys = toys
        let utilities = UtilitiesStore(core: core, settings: settings, state: UtilitiesState())
        settings.utilities = utilities
        return Fixture(core: core, settings: settings, toys: toys, utilities: utilities)
    }

    // MARK: Hosting

    final class Host {
        let window: NSWindow
        let controller: NSViewController
        init(window: NSWindow, controller: NSViewController) {
            self.window = window; self.controller = controller
        }
    }

    static func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: -20000, y: -20000), size: SettingsWindowController.defaultSize),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        let toolbar = NSToolbar(identifier: "perf-toolbar")
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        return window
    }

    /// Layout, display and a short run-loop turn, `passes` times: enough
    /// for SwiftUI to settle a change (the render proof uses the same
    /// shape). The run-loop turns are waits, not work; the CPU column
    /// excludes them.
    static func pump(_ window: NSWindow, passes: Int = 4) {
        for _ in 0..<passes {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            CATransaction.flush()
            RunLoop.main.run(until: Date().addingTimeInterval(0.002))
        }
    }

    /// Attach the Settings root the way `SettingsWindowController` does.
    static func attach(_ store: SettingsStore, to window: NSWindow) -> NSViewController {
        WindowContentLifecycle.attach(to: window, title: "JR-Bar Settings", subtitle: store.page.title) {
            // JRBAR_PERF_HOLD_PREVIEWS=1: every LEDStripPreview shows a
            // still frame (the existing `ledPreviewsHeld` key Effect
            // Studio sets while covered) — the "previews held" what-if.
            let env = ProcessInfo.processInfo.environment
            // JRBAR_PERF_ROOT=page: the page alone (no NavigationSplitView,
            // no sidebar), to see what the split view multiplies.
            var root = env["JRBAR_PERF_ROOT"] == "page"
                ? AnyView(SettingsPageContainer(store: store, page: store.page))
                : AnyView(SettingsRootView(store: store))
            if env["JRBAR_PERF_HOLD_PREVIEWS"] == "1" {
                root = AnyView(root.environment(\.ledPreviewsHeld, true))
            }
            // A tick counter on the same scheduler the previews use, so
            // the idle test can say how often a 30 fps timeline fires in
            // this window and what one tick costs.
            if env["JRBAR_PERF_PROBE"] == "1" {
                root = AnyView(root.overlay(alignment: .topLeading) { TickProbe() })
            }
            return WindowContentLifecycle.hosting(root)
        }
    }

    // MARK: Tests

    /// (1) Opening the window on each page: a fresh SwiftUI graph each
    /// time, as `WindowContentLifecycle` detaches on close. The very
    /// first open in the process is recorded on its own ("cold").
    @Test(.enabled(if: Self.enabled))
    func open() throws {
        let fx = try Self.fixture()
        let window = Self.makeWindow()
        // Cold: the first SwiftUI graph in the process.
        fx.settings.page = .general
        let cold = Self.measure {
            _ = Self.attach(fx.settings, to: window)
            Self.pump(window)
        }
        Self.record("open.cold.general", [cold])
        WindowContentLifecycle.detach(from: window)
        Self.pump(window, passes: 1)
        for page in SettingsStore.Page.allCases {
            var samples: [Sample] = []
            for _ in 0..<Self.iterations {
                fx.settings.page = page
                samples.append(Self.measure {
                    _ = Self.attach(fx.settings, to: window)
                    Self.pump(window)
                })
                WindowContentLifecycle.detach(from: window)
                Self.pump(window, passes: 1)
            }
            Self.record("open.\(page.rawValue)", samples)
        }
        // The open path's own synchronous call: SMAppService status.
        var sm: [Sample] = []
        for _ in 0..<Self.iterations { sm.append(Self.measure { fx.settings.refreshLaunchAtLogin() }) }
        Self.record("open.SMAppService.status", sm, note: "SettingsWindowController.show -> refreshLaunchAtLogin")
        withExtendedLifetime(fx) {}
        window.close()
    }

    /// (2) Switching pages with the window open: from General to each
    /// page and back.
    @Test(.enabled(if: Self.enabled))
    func pageSwitch() throws {
        let fx = try Self.fixture()
        let window = Self.makeWindow()
        fx.settings.page = .general
        _ = Self.attach(fx.settings, to: window)
        Self.pump(window, passes: 6)
        for page in SettingsStore.Page.allCases where page != .general {
            var to: [Sample] = [], back: [Sample] = []
            for _ in 0..<Self.iterations {
                to.append(Self.measure { fx.settings.page = page; Self.pump(window) })
                back.append(Self.measure { fx.settings.page = .general; Self.pump(window) })
            }
            Self.record("switch.general->\(page.rawValue)", to)
            Self.record("switch.\(page.rawValue)->general", back)
        }
        // Baseline: a pump with nothing changed.
        var idle: [Sample] = []
        for _ in 0..<Self.iterations { idle.append(Self.measure { Self.pump(window) }) }
        Self.record("pump.noop", idle, note: "baseline pump with no change")
        withExtendedLifetime(fx) {}
        window.close()
    }

    /// (3) A daemon push while a page is open: `state` (every refresh and
    /// hook event), `lights` (up to 30/s), `settings`, and one local edit
    /// (a slider tick — `SettingsStore.set` bumps the overlay).
    @Test(.enabled(if: Self.enabled))
    func pushes() throws {
        let fx = try Self.fixture()
        let stateBase = try Self.jsonObject("real_state.json")
        let lightsBase = try Self.jsonObject("real_lights.json")
        let docBase = fx.core.settings!.document
        var generation = 10
        var frames: [CoreMessage] = []
        for g in 0..<(Self.iterations * 4 * 14 + 8) { frames.append(try Self.stateFrame(1000 + g, base: stateBase)) }
        var lights: [CoreMessage] = []
        for n in 0..<(Self.iterations * 14 + 8) { lights.append(try Self.lightsFrame(n, base: lightsBase)) }
        var nextFrame = 0, nextLight = 0
        fx.core.apply(frames[0]); nextFrame = 1
        let window = Self.makeWindow()
        for page in SettingsStore.Page.allCases {
            fx.settings.page = page
            if window.contentViewController == nil { _ = Self.attach(fx.settings, to: window) }
            Self.pump(window, passes: 6)
            var noop: [Sample] = [], state: [Sample] = [], light: [Sample] = [], settings: [Sample] = [], edit: [Sample] = []
            for i in 0..<Self.iterations {
                noop.append(Self.measure { Self.pump(window) })
                let f = frames[nextFrame]; nextFrame += 1
                state.append(Self.measure { fx.core.apply(f); Self.pump(window) })
                let l = lights[nextLight]; nextLight += 1
                light.append(Self.measure { fx.core.apply(l); Self.pump(window) })
                generation += 1
                let g = generation
                settings.append(Self.measure {
                    fx.core.apply(.settings(CoreSettings(generation: g, schema: CoreProtocol.knownSettingsSchema, document: docBase)))
                    Self.pump(window)
                })
                let value = 0.5 + Double(i % 5) * 0.1
                edit.append(Self.measure {
                    fx.settings.set("global_brightness_scale", .number(value), throttled: true)
                    Self.pump(window)
                })
            }
            Self.record("push.noop.\(page.rawValue)", noop)
            Self.record("push.state.\(page.rawValue)", state)
            Self.record("push.lights.\(page.rawValue)", light)
            Self.record("push.settings.\(page.rawValue)", settings)
            Self.record("push.edit.\(page.rawValue)", edit, note: "one slider tick via SettingsStore.set(throttled:)")
        }
        withExtendedLifetime(fx) {}
        window.close()
    }

    /// (4) Toys and Utilities cards: expanding each card, a state push
    /// with it open, and idle CPU with it open (live previews).
    @Test(.enabled(if: Self.enabled))
    func cards() throws {
        let fx = try Self.fixture()
        let stateBase = try Self.jsonObject("real_state.json")
        var gen = 5000
        fx.core.apply(try Self.stateFrame(gen, base: stateBase))
        let window = Self.makeWindow()
        var ids: [(String, SettingsStore.Page)] = [
            (fx.utilities.menuBar.id, .utilities), (fx.utilities.dock.id, .utilities),
            (KeepAwakeUtility.shared.id, .utilities),
            (fx.utilities.agents.id, .utilities), (fx.utilities.dataHoarder.id, .utilities),
        ]
        if let notch = fx.toys.notch { ids.append((notch.id, .utilities)) }
        ids += fx.toys.toys.map { ($0.id, .toys) }
        for (id, page) in ids {
            fx.settings.expandedCards = []
            fx.settings.page = page
            if window.contentViewController == nil { _ = Self.attach(fx.settings, to: window) }
            Self.pump(window, passes: 6)
            var expand: [Sample] = [], collapse: [Sample] = [], push: [Sample] = []
            for _ in 0..<Self.iterations {
                expand.append(Self.measure { fx.settings.setCard(id, expanded: true); Self.pump(window) })
                gen += 1
                let frame = try Self.stateFrame(gen, base: stateBase)
                push.append(Self.measure { fx.core.apply(frame); Self.pump(window) })
                collapse.append(Self.measure { fx.settings.setCard(id, expanded: false); Self.pump(window) })
            }
            Self.record("card.expand.\(id)", expand)
            Self.record("card.push.state.\(id)", push, note: "state push with the card open")
            Self.record("card.collapse.\(id)", collapse)
            // Idle with the card open: process CPU over 2 s of run loop.
            fx.settings.setCard(id, expanded: true)
            Self.pump(window, passes: 6)
            _ = TickProbe.take()
            let p0 = Self.processCPUns(), t0 = Self.threadCPUns(), w0 = ContinuousClock.now
            RunLoop.main.run(until: Date().addingTimeInterval(2))
            let wall = ContinuousClock.now - w0
            let wallMs = Double(wall.components.seconds) * 1000 + Double(wall.components.attoseconds) / 1e15
            let pcpu = Double(Self.processCPUns() - p0) / 1e6, tcpu = Double(Self.threadCPUns() - t0) / 1e6
            Self.record("card.idle.\(id)", [Sample(cpuMs: tcpu, wallMs: wallMs)],
                        note: String(format: "process_cpu_ms=%.1f main_cpu_pct=%.1f probe_ticks_per_s=%.1f", pcpu, tcpu / wallMs * 100,
                                     Double(TickProbe.take()) / (wallMs / 1000)))
            fx.settings.setCard(id, expanded: false)
        }
        withExtendedLifetime(fx) {}
        window.close()
    }

    /// (5) Idle CPU per page (live previews ticking while nothing changes).
    @Test(.enabled(if: Self.enabled))
    func idle() throws {
        let fx = try Self.fixture()
        let window = Self.makeWindow()
        for page in SettingsStore.Page.allCases {
            fx.settings.page = page
            if window.contentViewController == nil { _ = Self.attach(fx.settings, to: window) }
            Self.pump(window, passes: 6)
            _ = TickProbe.take()
            let p0 = Self.processCPUns(), t0 = Self.threadCPUns(), w0 = ContinuousClock.now
            RunLoop.main.run(until: Date().addingTimeInterval(2))
            let wall = ContinuousClock.now - w0
            let wallMs = Double(wall.components.seconds) * 1000 + Double(wall.components.attoseconds) / 1e15
            let pcpu = Double(Self.processCPUns() - p0) / 1e6, tcpu = Double(Self.threadCPUns() - t0) / 1e6
            Self.record("idle.\(page.rawValue)", [Sample(cpuMs: tcpu, wallMs: wallMs)],
                        note: String(format: "process_cpu_ms=%.1f main_cpu_pct=%.1f probe_ticks_per_s=%.1f", pcpu, tcpu / wallMs * 100,
                                     Double(TickProbe.take()) / (wallMs / 1000)))
        }
        withExtendedLifetime(fx) {}
        window.close()
    }

    /// (6) Synchronous calls on the view paths, one by one.
    @Test(.enabled(if: Self.enabled))
    func calls() throws {
        let fx = try Self.fixture()
        fx.core.apply(try Self.stateFrame(7, base: try Self.jsonObject("real_state.json")))
        let n = max(Self.iterations, 20)
        func run(_ name: String, note: String = "", _ body: () -> Void) {
            var s: [Sample] = []
            for _ in 0..<n { s.append(Self.measure(body)) }
            Self.record("call.\(name)", s, note: note)
        }
        run("SMAppService.mainApp.status", note: "sync XPC to smd") { _ = SMAppService.mainApp.status }
        run("NSWorkspace.urlForApplication(alcove)", note: "NotchToy.alcoveURL") {
            _ = NSWorkspace.shared.urlForApplication(withBundleIdentifier: AlcoveGeometry.bundleIdentifier)
        }
        run("NSWorkspace.runningApplications.scan", note: "NotchToy.isAlcoveRunning") {
            _ = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == AlcoveGeometry.bundleIdentifier }
        }
        if let notch = fx.toys.notch {
            run("NotchToy.status") { _ = notch.status }
        }
        for toy in fx.toys.toys { run("toy.status.\(toy.id)") { _ = toy.status } }
        run("utility.status.dock") { _ = fx.utilities.dock.status }
        run("utility.status.menuBar") { _ = fx.utilities.menuBar.status }
        run("utility.status.agents") { _ = fx.utilities.agents.status }
        run("utility.status.keepAwake") { _ = KeepAwakeUtility.shared.status }
        run("NSScreen.localizedNames", note: "AquariumToy.status when off") { _ = NSScreen.screens.map(\.localizedName) }
        run("SoundPlayer.availableSounds", note: "SoundsPage.body") { _ = SoundPlayer.availableSounds() }
        run("SettingsStore.searchEntries") { _ = fx.settings.searchEntries }
        run("SettingsStore.searchResults(lyrics)") { fx.settings.searchQuery = "lyrics"; _ = fx.settings.searchResults }
        run("SettingsStore.searchResults(d)") { fx.settings.searchQuery = "d"; _ = fx.settings.searchResults }
        fx.settings.searchQuery = ""
        run("SettingsStore.document(no overlay)") { _ = fx.settings.document.bool("idle_dim_enabled") }
        fx.settings.set("colors.cycle_speed_seconds", .number(2.5), throttled: true)
        fx.settings.set("global_brightness_scale", .number(0.7), throttled: true)
        run("SettingsStore.document(2 pending)") { _ = fx.settings.document.bool("idle_dim_enabled") }
        run("SettingsStore.isProvided") { _ = fx.settings.isProvided("idle_dim_enabled") }
        run("SettingsStore.deviceEntries") { _ = fx.settings.deviceEntries }
        run("HotkeyChordDefaults.actionShortcut") { _ = fx.settings.actionShortcut("panel") }
        withExtendedLifetime(fx) {}
    }

}


/// A 30 fps TimelineView that only counts its ticks (JRBAR_PERF_PROBE).
@MainActor
struct TickProbe: View {
    static var ticks = 0
    static func take() -> Int { defer { ticks = 0 }; return ticks }
    /// JRBAR_PERF_PROBE_KIND: animation30 (default, the LED previews'
    /// schedule), animation4 (the same schedule at 4 Hz), periodic4.
    static let kind = ProcessInfo.processInfo.environment["JRBAR_PERF_PROBE_KIND"] ?? "animation30"
    var body: some View {
        switch Self.kind {
        case "periodic4":
            TimelineView(.periodic(from: .now, by: 0.25)) { context in leaf(context.date) }
        case "animation4":
            TimelineView(.animation(minimumInterval: 0.25)) { context in leaf(context.date) }
        default:
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in leaf(context.date) }
        }
    }
    private func leaf(_ date: Date) -> some View {
        let _ = { TickProbe.ticks += 1 }()
        return Color.clear.frame(width: 1, height: 1).opacity(date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2) > 1 ? 0.99 : 1)
            .allowsHitTesting(false)
    }
}
