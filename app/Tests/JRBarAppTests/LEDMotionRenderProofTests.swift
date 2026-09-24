import AppKit
import Foundation
import JRBarLEDS
import SwiftUI
import Testing
@testable import JRBarApp
@testable import JRBarCore

/// The daemon's motions, drawn by the app. `scripts/export_motion_fixtures.py`
/// writes every motion (and the Iris lid looks and the Land and Ripple
/// finishes) exactly as `render_effect` sends it, with the firmware's own
/// colours at reference times, into `JRBarLEDSTests/Fixtures/programs/motions`.
///
/// Always: the Swift sampler must agree with the firmware on every one of
/// them, so what Effect Studio and Settings draw is what the strip plays.
/// With `JRBAR_RENDER_PROOF=1`: a timeline for each (rows are time, columns
/// are LEDs, so a sweep is a diagonal) beside the strip at a quarter, half
/// and three quarters of its cycle, on a dark and a light stage, and the
/// Moments room's Lid and Finish sections and the device rows, into
/// `JRBAR_RENDER_PROOF_DIR` (default `/tmp/led-motion-proof`).
@Suite("LED motion render proof")
@MainActor
struct LEDMotionRenderProofTests {
    struct MotionFixture: Decodable {
        struct Sample: Decodable {
            let t_ms: Int
            let colors: [[Int]]
        }
        let name: String
        let motion: String
        let variant: String
        let led_count: Int
        let program: String
        let samples: [Sample]
    }

    nonisolated static let enabled = ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1"

    nonisolated static var fixtureDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "JRBarLEDSTests/Fixtures/programs/motions")
    }

    nonisolated static func fixtures() throws -> [MotionFixture] {
        let files = try FileManager.default.contentsOfDirectory(at: fixtureDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return try files.map { try JSONDecoder().decode(MotionFixture.self, from: Data(contentsOf: $0)) }
    }

    private static var directory: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF_DIR"] ?? "/tmp/led-motion-proof",
            isDirectory: true)
    }

    // MARK: Always

    @Test func everyMotionIsExportedForTheProAndTheDot() throws {
        let fixtures = try Self.fixtures()
        let motions = Set(fixtures.map(\.motion))
        #expect(motions.isSuperset(of: ["comet", "scanner", "heartbeat", "ripple", "pendulum", "lid_iris_open", "finish_land"]))
        for motion in motions where !motion.hasPrefix("lid_") && !motion.hasPrefix("finish_") {
            for variant in ["default", "min", "max"] {
                for leds in [8, 2] {
                    #expect(fixtures.contains { $0.motion == motion && $0.variant == variant && $0.led_count == leds },
                            "\(motion) \(variant) at \(leds) LEDs")
                }
            }
        }
    }

    @Test func theSamplerDrawsEveryMotionAsTheFirmwareDoes() throws {
        for fixture in try Self.fixtures() {
            let program = try LEDSProgram.parse(fixture.program, ledCount: fixture.led_count)
            let sampler = LEDSSampler(program: program, ledCount: fixture.led_count)
            var worst = 0
            for sample in fixture.samples {
                let codes = sampler.codes(atMilliseconds: sample.t_ms)
                for (index, expected) in sample.colors.enumerated() where index < codes.count {
                    let got = codes[index]
                    let diff = max(abs(Int(got.r) - expected[0]), abs(Int(got.g) - expected[1]), abs(Int(got.b) - expected[2]))
                    worst = max(worst, diff)
                }
            }
            #expect(worst <= 1, "\(fixture.name): worst per-channel error \(worst)")
        }
    }

    // MARK: Pictures

    @Test(.enabled(if: LEDMotionRenderProofTests.enabled))
    func motionTimelines() throws {
        let directory = Self.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixtures = try Self.fixtures()
        for fixture in fixtures {
            let modes = fixture.variant == "default" ? [true, false] : [true]
            for dark in modes {
                let rep = try Self.snapshot(MotionSheet(fixture: fixture), dark: dark)
                try Self.write(rep, named: "motion-\(fixture.name)-\(dark ? "dark" : "light").png")
            }
        }
        for leds in [8, 2] {
            let defaults = fixtures.filter { $0.variant == "default" && $0.led_count == leds }
            let rep = try Self.snapshot(MotionOverview(fixtures: defaults, ledCount: leds), dark: true)
            try Self.write(rep, named: "motions-overview-\(leds)led.png")
        }
    }

    @Test(.enabled(if: LEDMotionRenderProofTests.enabled))
    func momentsAndDeviceRows() throws {
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let fixtures = try Self.fixtures()
        func program(_ name: String) -> String { fixtures.first { $0.name == name }?.program ?? "off" }
        let core = CoreModel(socketPath: NSTemporaryDirectory() + "jrbar-led-motion-proof.sock")
        let store = EffectStudioStore(core: core)

        let hello = "#12E3B0 300ms pulse\n#0FA07C 300ms cosine\n#12E3B0 800ms pulse\noff 300ms ease-out"
        let coolDown = "#00E5FF 350ms pulse\n#0044AA 450ms cosine\noff 600ms cosine"
        func look(_ name: String, _ program: String, _ dot: String? = nil, shape: String? = nil) -> LidLook {
            LidLook(name: name, durationSeconds: 1.4, shape: shape, program: program, dotProgram: dot ?? program,
                    setting: .object([:]))
        }
        let transitions = [
            LidTransition(kind: "open", label: "Lid opens", path: "lid_open_animation", current: "Hello", shipped: false,
                          presets: [look("Hello", hello),
                                    look("Iris", program("lid_iris_open_8led"), program("lid_iris_open_2led"), shape: "iris_open")]),
            LidTransition(kind: "closed", label: "Lid closes", path: "lid_closed_animation", current: "Cool Down", shipped: false,
                          presets: [look("Cool Down", coolDown),
                                    look("Iris", program("lid_iris_close_8led"), program("lid_iris_close_2led"), shape: "iris_close")]),
            LidTransition(kind: "closed_active", label: "Lid closes while agents run", path: "lid_closed_active_animation",
                          current: "Iris (active)", shipped: false,
                          presets: [look("Iris (active)", program("lid_iris_close_active_8led"),
                                         program("lid_iris_close_active_2led"), shape: "iris_close_active")]),
        ]
        let finish = FinishLookList(current: "land", enabled: true, looks: [
            .init(style: "bloom", label: "Bloom", program: LightingPreviewPrograms.celebration(), dotProgram: "off"),
            .init(style: "land", label: "Land", program: program("finish_land_8led"), dotProgram: program("finish_land_2led")),
            .init(style: "ripple", label: "Ripple", program: program("finish_ripple_8led"), dotProgram: program("finish_ripple_2led")),
        ])
        let moments = VStack(alignment: .leading, spacing: 14) {
            LidMomentsSection(store: store, seed: transitions)
            FinishMomentsSection(store: store, seed: finish)
        }
        .padding(20)
        .frame(width: 780)

        core.apply(.settings(CoreSettings(generation: 1, schema: CoreProtocol.knownSettingsSchema,
                                          document: Self.deviceDocument())))
        let settings = SettingsStore(core: core)
        let entries = settings.deviceEntries
        let rows = VStack(alignment: .leading, spacing: 0) {
            ForEach(entries) { device in
                Text(device.name).font(.headline).padding(.top, 10)
                LEDDirectionRow(store: settings, device: device)
                DotTravelStyleRow(store: settings, device: device)
            }
        }
        .padding(20)
        .frame(width: 560)

        for dark in [true, false] {
            let suffix = dark ? "dark" : "light"
            try Self.write(try Self.hosted(moments, size: CGSize(width: 780, height: 900), dark: dark),
                           named: "moments-lid-finish-\(suffix).png")
            try Self.write(try Self.hosted(rows, size: CGSize(width: 560, height: 420), dark: dark),
                           named: "device-direction-travel-\(suffix).png")
        }
    }

    /// Controls drawn by AppKit (buttons, pickers) through a real window,
    /// as the Settings render proof does; the LED previews get a few
    /// frames to move off their black start.
    static func hosted<V: View>(_ view: V, size: CGSize, dark: Bool) throws -> NSBitmapImageRep {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let hosting = NSHostingView(rootView: view
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Color(white: dark ? 0.12 : 0.95))
            .environment(\.colorScheme, dark ? .dark : .light))
        let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: -20000, y: -20000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        hosting.frame = NSRect(origin: .zero, size: size)
        for _ in 0..<8 {
            hosting.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.06))
        }
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
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

    /// A Pro mounted the right way round and a Dot, reversed and wiping,
    /// with every key the rows read.
    static func deviceDocument() -> JSONValue {
        func device(_ id: String, _ name: String, direction: String) -> JSONValue {
            .object(["id": .string(id), "name": .string(name), "path": .string("/Volumes/\(name)"),
                     "led_display": .string("agent"), "brightness": .number(255),
                     "led_direction": .string(direction), "dot_travel_style": .string("wipe")])
        }
        return .object(["devices": .array([
            device("sidepulse:pro:1", "SidePulse", direction: "forward"),
            device("sidepulse:dot:1", "PulseDot", direction: "reversed"),
        ])])
    }

    // MARK: Drawing

    static func snapshot<V: View>(_ view: V, dark: Bool) throws -> NSBitmapImageRep {
        let backed = view
            .background(Color(white: dark ? 0.12 : 0.95))
            .environment(\.colorScheme, dark ? .dark : .light)
        let renderer = ImageRenderer(content: backed)
        renderer.scale = 2
        return NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
    }

    static func write(_ rep: NSBitmapImageRep, named name: String) throws {
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent(name))
    }
}

/// One motion: its timeline and the strip at four moments of its cycle.
private struct MotionSheet: View {
    let fixture: LEDMotionRenderProofTests.MotionFixture

    var body: some View {
        let sampler = (try? LEDSProgram.parse(fixture.program, ledCount: fixture.led_count))
            .map { LEDSSampler(program: $0, ledCount: fixture.led_count) }
        let span = MotionTimeline.span(sampler)
        HStack(alignment: .top, spacing: 18) {
            MotionTimeline(sampler: sampler, ledCount: fixture.led_count, span: span)
            VStack(alignment: .leading, spacing: 10) {
                Text(fixture.name).font(.headline.monospaced())
                Text(String(format: "%.2f s shown · %d bytes", span, fixture.program.utf8.count))
                    .font(.caption).foregroundStyle(.secondary)
                ForEach([0.0, 0.25, 0.5, 0.75], id: \.self) { fraction in
                    HStack(spacing: 8) {
                        Text("\(Int(fraction * 100))%").font(.caption.monospaced()).frame(width: 34, alignment: .trailing)
                        LEDStripPreview(program: fixture.program, ledCount: fixture.led_count, style: .dots,
                                        dotSize: 12, spacing: 7, phase: span * fraction)
                            .frame(width: fixture.led_count == 2 ? 80 : 190)
                    }
                }
            }
        }
        .padding(18)
    }
}

/// Every default motion's timeline side by side, labelled.
private struct MotionOverview: View {
    let fixtures: [LEDMotionRenderProofTests.MotionFixture]
    let ledCount: Int

    var body: some View {
        let columns = [GridItem(.adaptive(minimum: ledCount == 2 ? 70 : 120), spacing: 14, alignment: .top)]
        LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
            ForEach(fixtures, id: \.name) { fixture in
                let sampler = (try? LEDSProgram.parse(fixture.program, ledCount: fixture.led_count))
                    .map { LEDSSampler(program: $0, ledCount: fixture.led_count) }
                VStack(alignment: .leading, spacing: 4) {
                    Text(fixture.motion).font(.caption.monospaced())
                    MotionTimeline(sampler: sampler, ledCount: fixture.led_count, span: 3.0, cell: 12, rowHeight: 1)
                }
            }
        }
        .padding(18)
        .frame(width: ledCount == 2 ? 760 : 1180)
    }
}

/// Rows are 60 Hz frames, columns are LEDs: the firmware's own picture of
/// a motion, drawn from the Swift sampler.
private struct MotionTimeline: View {
    let sampler: LEDSSampler?
    let ledCount: Int
    let span: TimeInterval
    var cell: CGFloat = 22
    var rowHeight: CGFloat = 2

    static func span(_ sampler: LEDSSampler?) -> TimeInterval {
        guard let sampler else { return 1 }
        if let cycle = sampler.cycleDuration { return min(6, max(1, cycle)) }
        return min(6, (sampler.motionEndsAt ?? 1) + 0.3)
    }

    var body: some View {
        let frames = max(1, Int(span * 60))
        Canvas { context, _ in
            guard let sampler else { return }
            for frame in 0..<frames {
                let codes = sampler.codes(atMilliseconds: Int(Double(frame) * 1000 / 60))
                for (index, code) in codes.enumerated() {
                    let rect = CGRect(x: CGFloat(index) * (cell + 1), y: CGFloat(frame) * rowHeight,
                                      width: cell, height: rowHeight)
                    let color = Color(red: Double(code.r) / 255, green: Double(code.g) / 255, blue: Double(code.b) / 255)
                    context.fill(Path(rect), with: .color(color))
                }
            }
        }
        .frame(width: CGFloat(ledCount) * (cell + 1), height: CGFloat(frames) * rowHeight)
        .background(Color(white: 0.09))
    }
}
