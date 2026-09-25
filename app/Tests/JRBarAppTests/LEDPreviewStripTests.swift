import AppKit
import Foundation
import JRBarLEDS
import SwiftUI
import Testing
@testable import JRBarApp

/// The LED previews draw with Core Animation layers the strip recolours
/// itself (`LEDStripLayerView`): SwiftUI lays the strip out once and
/// never hears about a frame. These pin when the strip's own link runs,
/// that a frame reaches the layers without a SwiftUI update, and — with
/// `JRBAR_RENDER_PROOF=1` — that the layers look like the SwiftUI still
/// they replaced, dots and band, light and dark.
@Suite("LED preview strip")
@MainActor
struct LEDPreviewStripTests {
    /// A left-to-right sweep that never stops moving.
    static let sweep = LEDDirectionRow.sweep(reversed: false, ledCount: 8)

    static func config(_ program: String = sweep, style: LEDStripPreview.Style = .dots,
                       paused: Bool = false) -> LEDStripLayerView.Config {
        LEDStripLayerView.Config(program: program, ledCount: 8, style: style, dotSize: 14, spacing: 8,
                                 loops: true, paused: paused, phase: 0)
    }

    // MARK: When the link runs

    @Test("the link runs only in a visible window on a screen, moving, and not held")
    func linkRule() {
        func runs(inWindow: Bool = true, onScreen: Bool = true, visible: Bool = true, held: Bool = false,
                  reduceMotion: Bool = false, paused: Bool = false, moving: Bool = true) -> Bool {
            LEDStripLayerView.animates(inWindow: inWindow, onScreen: onScreen, windowVisible: visible, held: held,
                                       reduceMotion: reduceMotion, paused: paused, moving: moving)
        }
        #expect(runs())
        #expect(!runs(inWindow: false), "no window: nothing to draw into")
        #expect(!runs(onScreen: false), "an offscreen window has no display to pace it")
        #expect(!runs(visible: false), "a covered, minimised or hidden window")
        #expect(!runs(held: true), "ledPreviewsHeld")
        #expect(!runs(reduceMotion: true), "Reduce Motion shows the brightest moment, still")
        #expect(!runs(paused: true), "a paused preview (a library row not selected)")
        #expect(!runs(moving: false), "a static program")
    }

    @Test("a strip with no window, or in an offscreen one, runs no link")
    func noWindowNoLink() {
        let strip = LEDStripLayerView(config: Self.config(), held: false, reduceMotion: false, now: 0)
        #expect(!strip.isAnimating)
        let window = Self.offscreenWindow(size: CGSize(width: 300, height: 60))
        window.contentView?.addSubview(strip)
        strip.refreshAnimating()
        #expect(!strip.isAnimating, "no screen under the window")
        strip.removeFromSuperview()
        window.close()
    }

    // MARK: Frames

    @Test("a frame recolours the layers and nothing in SwiftUI updates")
    func framesSkipSwiftUI() throws {
        LEDStripProbe.bodies = 0
        let window = Self.offscreenWindow(size: CGSize(width: 320, height: 80))
        let hosting = NSHostingView(rootView: LEDStripProbe(program: Self.sweep))
        hosting.frame = CGRect(x: 0, y: 0, width: 320, height: 80)
        window.contentView = hosting
        Self.pump(window)
        let strip = try #require(Self.strips(in: hosting).first)
        let bodies = LEDStripProbe.bodies
        let start = CACurrentMediaTime()
        strip.renderFrame(at: start + 0.05)
        let first = strip.shownColors
        strip.renderFrame(at: start + 0.55)
        let second = strip.shownColors
        Self.pump(window)
        #expect(first.count == 8)
        #expect(first != second, "the sweep moved on")
        #expect(LEDStripProbe.bodies == bodies, "no body ran for either frame")
        window.contentView = nil
        window.close()
    }

    @Test("a held strip keeps the frame it shows through SwiftUI's updates")
    func heldKeepsItsFrame() {
        let strip = LEDStripLayerView(config: Self.config(), held: true, reduceMotion: false, now: 0)
        strip.renderFrame(at: 0.3)
        let shown = strip.shownColors
        strip.update(config: Self.config(), held: true, reduceMotion: false, now: 0.9)
        #expect(strip.shownColors == shown)
        // A new program starts over, held or not.
        let other = Self.config(LightingPreviewPrograms.state("error", colorHex: "#FF3B30"))
        strip.update(config: other, held: true, reduceMotion: false, now: 0.9)
        #expect(strip.shownColors != shown)
    }

    @Test("Reduce Motion and a paused strip show the brightest moment, whatever the time")
    func stillShowsTheBrightest() {
        let breathe = LightingPreviewPrograms.state("idle", colorHex: "#00E5FF")
        for (paused, reduceMotion) in [(true, false), (false, true)] {
            let strip = LEDStripLayerView(config: Self.config(breathe, paused: paused), held: false,
                                          reduceMotion: reduceMotion, now: 0)
            let early = strip.shownColors
            strip.renderFrame(at: 1.7)
            #expect(strip.shownColors == early)
            #expect((early.first?.maxChannel ?? 0) > 0.5, "the swell's top, not its floor")
        }
    }

    @Test("the strip draws the colours the sampler gives, as the SwiftUI still does")
    func coloursMatchTheSampler() throws {
        let sampler = try #require(LEDPreviewSamplers.sampler(for: Self.sweep, ledCount: 8))
        let strip = LEDStripLayerView(config: Self.config(), held: false, reduceMotion: false, now: 10)
        strip.renderFrame(at: 10.4)
        let expected = LEDStripFrames.colors(sampler: sampler, ledCount: 8, elapsed: 0.4, still: false, loops: true)
        #expect(strip.shownColors == expected)
    }

    @Test("an LED count the strip has no layout for draws eight, as the sampler does")
    func unsupportedCount() {
        var config = Self.config("#FF0000")
        config.ledCount = 3
        let strip = LEDStripLayerView(config: config, held: false, reduceMotion: false, now: 0)
        #expect(strip.shownColors.count == 8)
        #expect(strip.drawnCount == 8)
        var band = Self.config("#FF0000", style: .band)
        band.ledCount = 3
        let bandStrip = LEDStripLayerView(config: band, held: false, reduceMotion: false, now: 0)
        #expect(bandStrip.shownColors.count == 8)
    }

    @Test("the dots take their natural row")
    func sizes() {
        #expect(LEDStripLayerView.Config.dotsSize(count: 8, dotSize: 14, spacing: 8) == CGSize(width: 8 * 14 + 7 * 8, height: 14))
        #expect(LEDStripLayerView.Config.dotsSize(count: 0, dotSize: 14, spacing: 8).width == 0)
        let refused = LEDStripLayerView(config: Self.config("not a program"), held: false, reduceMotion: false, now: 0)
        #expect(refused.drawnCount == 8, "a refused program is a row of dull red, one per LED")
    }

    @Test("the layers add no accessibility element of their own: the strip's label is SwiftUI's")
    func accessibility() throws {
        let window = Self.offscreenWindow(size: CGSize(width: 320, height: 80))
        let hosting = NSHostingView(rootView: LEDStripPreview(program: Self.sweep))
        hosting.frame = CGRect(x: 0, y: 0, width: 320, height: 80)
        window.contentView = hosting
        Self.pump(window)
        let strip = try #require(Self.strips(in: hosting).first)
        #expect(!strip.isAccessibilityElement())
        window.contentView = nil
        window.close()
    }

    // MARK: Render proof

    @Test(.enabled(if: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1",
                   "set JRBAR_RENDER_PROOF=1 to write the LED strip PNGs"))
    func layersMatchTheStill() throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF_DIR"]
            ?? "/tmp/led-strip-proof", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let programs: [(String, String)] = [
            ("sweep", Self.sweep),
            ("working", LightingPreviewPrograms.working(colorHex: "#FF7A1A", blendMode: "relay", cycleSeconds: 1.6)),
            ("fleet", LightingPreviewPrograms.fleet(blendMode: "smooth", working: ("#FF7A1A", "#4C8DFF"),
                                                     doneHex: "#00FF66", cycleSeconds: 2)),
            ("error", LightingPreviewPrograms.state("error", colorHex: "#FF3B30")),
            ("refused", "this is not a program"),
        ]
        for dark in [true, false] {
            let sheet = LEDStripProofSheet(programs: programs)
            let size = CGSize(width: 760, height: 90 + CGFloat(programs.count) * 150)
            let rep = try Self.hosted(sheet, size: size, dark: dark)
            let png = try #require(rep.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("led-strip-layers-vs-still-\(dark ? "dark" : "light").png"))
        }
    }

    // MARK: Helpers

    static func offscreenWindow(size: CGSize) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: -20000, y: -20000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    static func pump(_ window: NSWindow, passes: Int = 3) {
        for _ in 0..<passes {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            CATransaction.flush()
        }
    }

    static func strips(in view: NSView) -> [LEDStripLayerView] {
        var found: [LEDStripLayerView] = []
        if let strip = view as? LEDStripLayerView { found.append(strip) }
        for sub in view.subviews { found += strips(in: sub) }
        return found
    }

    /// Through a real window and `cacheDisplay`, as the Settings proofs
    /// draw: the layers draw themselves into it.
    static func hosted<V: View>(_ view: V, size: CGSize, dark: Bool) throws -> NSBitmapImageRep {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let hosting = NSHostingView(rootView: view
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Color(white: dark ? 0.12 : 0.95))
            .environment(\.colorScheme, dark ? .dark : .light))
        let window = offscreenWindow(size: size)
        window.appearance = appearance
        window.contentView = hosting
        hosting.frame = NSRect(origin: .zero, size: size)
        pump(window, passes: 4)
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
}

/// Counts its body evaluations around one strip.
private struct LEDStripProbe: View {
    @MainActor static var bodies = 0
    let program: String

    var body: some View {
        let _ = { Self.bodies += 1 }()
        LEDStripPreview(program: program)
    }
}

/// Each program as the layers draw it (left) beside the SwiftUI still it
/// replaced (right), at the same moment: paused, both show the brightest
/// instant.
private struct LEDStripProofSheet: View {
    let programs: [(String, String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 20) {
                Text("Layers (live)").frame(width: 340, alignment: .leading)
                Text("SwiftUI still (as before)").frame(width: 340, alignment: .leading)
            }
            .font(.headline)
            ForEach(programs, id: \.0) { name, program in
                VStack(alignment: .leading, spacing: 6) {
                    Text(name).font(.caption.monospaced()).foregroundStyle(.secondary)
                    HStack(alignment: .top, spacing: 20) {
                        column(program).frame(width: 340)
                        column(program).environment(\.renderSnapshot, true).frame(width: 340)
                    }
                }
            }
        }
        .padding(20)
    }

    private func column(_ program: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            LEDStripPreview(program: program, style: .dots, dotSize: 14, spacing: 8, paused: true)
            HStack(spacing: 12) {
                LEDStripPreview(program: program, style: .dots, dotSize: 9, spacing: 6, paused: true,
                                showsBackground: false)
                LEDStripPreview(program: program, ledCount: 2, style: .dots, dotSize: 11, spacing: 6,
                                paused: true, cornerRadius: 7)
            }
            LEDStripPreview(program: program, style: .band, dotSize: 6, paused: true, cornerRadius: 6)
            LEDStripPreview(program: program, style: .band, dotSize: 5, paused: true, showsBackground: false)
        }
    }
}
