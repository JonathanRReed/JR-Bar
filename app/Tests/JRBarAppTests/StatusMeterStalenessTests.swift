import AppKit
import JRBarCore
import JRBarUI
import Testing
@testable import JRBarApp

/// The menu-bar meters only show a figure as live when it is: a provider
/// the daemon marks stale is drawn faint, and a window whose reset has
/// passed is drawn unread.
@MainActor
@Suite("Menu bar meter staleness")
struct StatusMeterStalenessTests {
    static let now: Double = 1_800_000_000

    static func claude(state: String? = "ready", fidelity: String? = "official",
                       used: Double? = 40, resetsIn: Double? = 3600) -> CoreProviderUsage {
        let window = CoreUsageWindow(key: "five-hour", name: "5h", usedPct: used,
                                     resetsAt: resetsIn.map { now + $0 })
        return CoreProviderUsage(id: "claude", windows: [window], fidelity: fidelity, state: state)
    }

    static func reading(_ usage: CoreProviderUsage) -> AppDelegate.MeterReading {
        AppDelegate.meterReading(of: usage, window: usage.windows.first, now: now)
    }

    @Test func aFreshReadingIsLive() {
        let fresh = Self.reading(Self.claude())
        #expect(fresh == AppDelegate.MeterReading(fraction: 0.4, stale: false, current: true))
    }

    @Test func aStaleProviderKeepsItsFigureFlagged() {
        let byState = Self.reading(Self.claude(state: "stale", used: 19))
        #expect(byState == AppDelegate.MeterReading(fraction: 0.19, stale: true, current: false))
        let byFidelity = Self.reading(Self.claude(fidelity: "stale"))
        #expect(byFidelity.stale && byFidelity.fraction == 0.4)
        let shouted = Self.reading(Self.claude(state: "STALE"))
        #expect(shouted.stale)
    }

    @Test func aLapsedWindowHasNoReading() {
        // Ready, but the window the figure belongs to reset a minute ago.
        let lapsed = Self.reading(Self.claude(used: 88, resetsIn: -60))
        #expect(lapsed == AppDelegate.MeterReading(fraction: nil, stale: false, current: false))
        let atTheReset = Self.reading(Self.claude(resetsIn: 0))
        #expect(atTheReset.fraction == nil, "the reset moment itself starts the new window")
    }

    @Test func theLiveCheckCaseIsUnreadAndStale() {
        // What the menu bar showed on 2026-09-24: Claude stale at 19 %,
        // its 5 h window reset 37 minutes earlier, drawn as a live fill.
        let usage = Self.claude(state: "stale", used: 19, resetsIn: -37 * 60)
        let got = Self.reading(usage)
        #expect(got == AppDelegate.MeterReading(fraction: nil, stale: true, current: false))
        var meter = StatusItemController.meter(for: "claude", fraction: got.fraction, approximate: false,
                                               resetsAt: usage.windows.first?.resetsAt)
        meter.stale = got.stale
        #expect(meter.isUnknown)
        #expect(meter.readout == "Claude no reading (stale)")
    }

    @Test func noResetTimeAndNoFigureAreLeftAlone() {
        let noReset = Self.reading(Self.claude(resetsIn: nil))
        #expect(noReset == AppDelegate.MeterReading(fraction: 0.4, stale: false, current: true))
        let unmeasured = Self.reading(Self.claude(used: nil))
        #expect(unmeasured == AppDelegate.MeterReading(fraction: nil, stale: false, current: true))
        let windowless = AppDelegate.meterReading(of: Self.claude(), window: nil, now: Self.now)
        #expect(windowless == AppDelegate.MeterReading(fraction: nil, stale: false, current: true))
    }

    // MARK: Render proof

    /// Off by default; set `JRBAR_RENDER_PROOF=1` to write the strips,
    /// before and after, into `JRBAR_RENDER_PROOF_DIR` (default
    /// /tmp/meters-proof) at 8× on a light and a dark menu bar.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1"))
    func renderProof() throws {
        let path = ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF_DIR"] ?? "/tmp/meters-proof"
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let grok = CoreProviderUsage(
            id: "grok",
            windows: [CoreUsageWindow(key: "credits", name: "Credits", usedPct: 31, resetsAt: Self.now - 3600)],
            state: "stale")
        let claudeStale = Self.claude(state: "stale", used: 19, resetsIn: -37 * 60)
        let claudeOpen = Self.claude(state: "stale", used: 62, resetsIn: 2 * 3600)
        let codex = CoreProviderUsage(
            id: "codex", windows: [CoreUsageWindow(key: "five-hour", name: "5h", usedPct: 41, resetsAt: Self.now + 3600)],
            state: "ready")
        // The owner's accents, so "before" looks the way the live bar did.
        let accents = SettingsDocument(["colors": ["agent_colors": [
            "claude": "#D97757", "grok": "#8E8E93", "codex": "#10A37F",
        ]]])
        let scenes: [(String, [CoreProviderUsage])] = [
            ("live-check", [claudeStale, grok]),
            ("stale-open-window", [claudeOpen, codex]),
            ("fresh", [Self.claude(used: 19), codex]),
        ]
        for (name, providers) in scenes {
            let before = providers.map { usage in
                StatusItemController.meter(for: usage.id, fraction: usage.windows.first?.usedPct.map { $0 / 100 },
                                           approximate: false, document: accents)
            }
            let after = providers.map { usage in
                let got = Self.reading(usage)
                var meter = StatusItemController.meter(for: usage.id, fraction: got.fraction,
                                                       approximate: false, document: accents)
                meter.stale = got.stale
                return meter
            }
            for (stage, meters) in [("before", before), ("after", after)] {
                for style in [StatusIconStyle.meters, .metersPercent] {
                    let spec = StatusIconSpec(style: style, meters: meters)
                    for dark in [false, true] {
                        let file = "\(name)-\(style.rawValue)-\(stage)-\(dark ? "dark" : "light").png"
                        try Self.png(spec, dark: dark).write(to: directory.appendingPathComponent(file))
                    }
                }
            }
        }
    }

    /// The strip at 8× on a menu-bar coloured plate. A template image is
    /// drawn in the bar's own ink, the way the menu bar draws it.
    static func png(_ spec: StatusIconSpec, dark: Bool) throws -> Data {
        let image = StatusIconRenderer().image(for: spec)
        let scale: CGFloat = 8
        let pixelSize = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let rect = NSRect(origin: .zero, size: pixelSize)
        let strip = try #require(Self.bitmap(pixelSize))
        let plate = try #require(Self.bitmap(pixelSize))
        let appearance = try #require(NSAppearance(named: dark ? .darkAqua : .aqua))
        appearance.performAsCurrentDrawingAppearance {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: strip)
            image.draw(in: rect)
            if image.isTemplate {
                (dark ? NSColor.white : NSColor.black).setFill()
                rect.fill(using: .sourceAtop)
            }
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: plate)
            NSColor(calibratedWhite: dark ? 0.13 : 0.93, alpha: 1).setFill()
            rect.fill()
            // A rep's plain draw(in:) copies, which would wipe the plate.
            strip.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1,
                       respectFlipped: false, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
        }
        return try #require(plate.representation(using: .png, properties: [:]))
    }

    static func bitmap(_ size: NSSize) -> NSBitmapImageRep? {
        NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    }
}
